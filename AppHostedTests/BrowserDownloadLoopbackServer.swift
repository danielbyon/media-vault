//
//  BrowserDownloadLoopbackServer.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Network
import ObjectiveC
import UniformTypeIdentifiers

/// A scoped HTTP/1.1 origin for native WebKit tests. It listens only on IPv4 loopback with an
/// ephemeral port. Every listener/connection callback is delivered on DispatchQueue.main; checked
/// MainActor bridges keep request buffers, route state and teardown in that same execution domain.
@MainActor
final class BrowserDownloadLoopbackServer {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    enum Failure: Error {
        case listenerUnavailable
        case invalidRequest
    }

    let namespace = UUID().uuidString.lowercased()
    /// Shared fixture bytes so qualification hosts and the test bundle agree on one PDF.
    static let fixturePDF = makePDFPayload()
    let payload = fixturePDF
    private(set) var requests: [Request] = []
    private(set) var slowPrefixSent = false
    private(set) var acceptedCount = 0
    private(set) var ready = false
    private(set) var stopped = false
    /// Bounded transport milestones contain identifiers and counters, never request bytes or URLs.
    private(set) var connectionEvidence: [[String: String]] = []

    private func recordConnection(_ id: UUID, fields: [String: String]) {
        var evidence = fields
        evidence["connectionID"] = id.uuidString
        evidence["observedUptime"] = String(ProcessInfo.processInfo.systemUptime)
        if let index = connectionEvidence.firstIndex(where: { $0["connectionID"] == id.uuidString }) {
            connectionEvidence[index] = evidence
        } else if connectionEvidence.count < 64 {
            connectionEvidence.append(evidence)
        }
    }

    var connectionCount: Int {
        connections.count
    }

    private var failed = false
    private let listener: NWListener
    private var connections: [UUID: Connection] = [:]

    var cookieName: String {
        "downloadfixture_" + namespace.replacing("-", with: "")
    }

    var cookieValue: String {
        namespace
    }

    var cookiePath: String {
        "/\(namespace)/"
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else {
                    return
                }

                switch state {
                case .ready:
                    self.ready = true
                case .failed:
                    self.failed = true
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { _ = self?.accept(connection) }
        }
        listener.start(queue: .main)
    }

    func start() async throws {
        let deadline = Date().addingTimeInterval(10)
        while !ready, !failed, !stopped, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard ready, !stopped, listener.port != nil else {
            throw Failure.listenerUnavailable
        }
    }

    func url(_ route: String) throws -> URL {
        guard let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(namespace)/\(route)") else {
            throw Failure.listenerUnavailable
        }

        return url
    }

    func stop() {
        guard !stopped else {
            return
        }

        // Publish shutdown before cancellation can deliver already queued listener callbacks.
        stopped = true
        ready = false
        listener.cancel()
        for connection in Array(connections.values) {
            connection.close(reason: "serverStopped")
        }
        connections.removeAll()
    }

    /// Returns the retained delivery so teardown tests can replay a callback already queued by
    /// Network. This test-only server never manufactures WebKit navigation or download callbacks.
    @discardableResult
    func accept(_ native: NWConnection) -> Connection? {
        guard !stopped, connections.count < 8, requests.count < 64 else {
            native.cancel()
            return nil
        }

        acceptedCount += 1
        let connection = Connection(native: native, server: self)
        connections[connection.id] = connection
        connection.start()
        return connection
    }

    private func respond(to request: Request, on connection: Connection) {
        guard !stopped, !connection.closed else {
            return
        }

        requests.append(request)
        guard requests.count <= 64, request.path.hasPrefix(cookiePath) else {
            connection.close()
            return
        }

        // Query tokens distinguish real navigation commits without changing the fixture route.
        let route = request.path
            .dropFirst(cookiePath.count)
            .split(separator: "?", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        switch route {
        case "first",
             "committed":
            connection.send(page(route), type: "text/html; charset=utf-8", headers: [
                "Set-Cookie": "\(cookieName)=\(cookieValue); Path=\(cookiePath); HttpOnly; SameSite=Lax",
            ])
        case "redirect":
            connection.send(Data(), type: "text/plain", status: "302 Found", headers: [
                "Location": cookiePath + "attachment",
            ])
        case "image":
            respondImage(request, on: connection)
        case "protected":
            respondProtected(request, on: connection)
        case "post":
            respondPost(request, on: connection)
        case "attachment",
             "inline",
             "attribute",
             "blob-bytes":
            sendPDF(request, route: route, on: connection)
        case "octet":
            connection.send(payload, type: "application/octet-stream")
        case "slow-known",
             "slow-unknown":
            connection.sendSlow(payload, knownLength: route == "slow-known")
        default:
            connection.send(Data(), type: "text/plain", status: "404 Not Found")
        }
    }

    /// Valid still image served with an attachment disposition for image-download cases.
    let imageBytes = fixturePNG
    /// Shared one-pixel PNG used by image-download cases.
    static let fixturePNG = makePNG()

    /// Serves the image fixture route.
    private func respondImage(_ request: Request, on connection: Connection) {
        guard request.method == "GET" || request.method == "HEAD" else {
            connection.send(Data(), type: "text/plain", status: "405 Method Not Allowed")
            return
        }

        connection.send(
            imageBytes,
            type: "image/png",
            headers: ["Content-Disposition": "attachment; filename=valid-image.png"],
            headOnly: request.method == "HEAD",
        )
    }

    /// Builds the shared fixture PDF without writing a file to disk.
    private static func makePDFPayload() -> Data {
        let padding = Data(repeating: 0x41, count: 16 * 1_024 * 1_024)
        var stream = Data("BT /F1 14 Tf 20 100 Td (Browser download transfer probe) Tj\n%".utf8)
        stream.append(padding)
        stream.append(Data("\nET\n".utf8))

        let objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>"
                    .utf8,
            ),
            Data("<< /Length \(stream.count) >>\nstream\n".utf8) + stream + Data("endstream".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
        ]
        var pdf = Data("%PDF-1.4\n".utf8)
        var objectOffsets = [0]
        for (index, object) in objects.enumerated() {
            objectOffsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let crossReferenceOffset = pdf.count
        pdf.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
        for offset in objectOffsets.dropFirst() {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(crossReferenceOffset)\n%%EOF\n".utf8))
        return pdf
    }

    /// Renders one opaque pixel as PNG bytes using the system image encoder.
    private static func makePNG() -> Data {
        let pixel = Data([0x30, 0x80, 0xd0, 0xff])
        guard let provider = CGDataProvider(data: pixel as CFData),
              let image = CGImage(
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent,
              ) else {
            return Data()
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil,
        ) else {
            return Data()
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return Data()
        }

        return output as Data
    }

    private func respondProtected(_ request: Request, on connection: Connection) {
        let cookies = (request.headers["cookie"] ?? "")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cookies.contains("\(cookieName)=\(cookieValue)") else {
            connection.send(Data(), type: "text/plain", status: "403 Forbidden")
            return
        }

        connection.send(
            payload,
            type: "application/pdf",
            headers: ["Content-Disposition": "attachment; filename=fixture.pdf"],
        )
    }

    private func respondPost(_ request: Request, on connection: Connection) {
        guard request.method == "POST", request.body == Data("fixture=\(namespace)".utf8) else {
            connection.send(Data(), type: "text/plain", status: "400 Bad Request")
            return
        }

        connection.send(
            payload,
            type: "application/pdf",
            headers: ["Content-Disposition": "attachment; filename=fixture.pdf"],
        )
    }

    /// PDF navigation may issue HEAD and single-range requests. Both dispositions serve precisely
    /// the same bytes; classification must come from native navigation policy, not altered content.
    private func sendPDF(_ request: Request, route: String, on connection: Connection) {
        let disposition = route == "attachment" ? "attachment" : "inline"
        var headers = ["Content-Disposition": "\(disposition); filename=fixture.pdf", "Accept-Ranges": "bytes"]
        if let range = byteRange(request.headers["range"]) {
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(payload.count)"
            connection.send(
                payload.subdata(in: range),
                type: "application/pdf",
                status: "206 Partial Content",
                headers: headers,
                headOnly: request.method == "HEAD",
            )
        } else {
            connection.send(payload, type: "application/pdf", headers: headers, headOnly: request.method == "HEAD")
        }
    }

    private func byteRange(_ header: String?) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else {
            return nil
        }

        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start >= 0, start < payload.count else {
            return nil
        }

        let end = parts[1].isEmpty ? payload.count - 1 : (Int(parts[1]) ?? -1)
        guard end >= start else {
            return nil
        }

        return start ..< (min(end, payload.count - 1) + 1)
    }

    private func page(_ route: String) -> Data {
        Data("""
        <!doctype html><html><head><title>Browser download \(route)</title></head><body>
        <h1 id="ready">Browser download \(route)</h1>
        <a id="attribute" download="fixture.pdf" href="\(cookiePath)attribute">Download</a>
        <form id="post" method="POST" action="\(cookiePath)post">
        <input name="fixture" value="\(namespace)"></form>
        <script>
        async function startBlob() {
          const response = await fetch('\(cookiePath)blob-bytes');
          const bytes = await response.arrayBuffer();
          const link = document.createElement('a');
          link.download = 'fixture.pdf';
          link.href = URL.createObjectURL(new Blob([bytes], {type:'application/pdf'}));
          document.body.appendChild(link); link.click();
        }
        </script></body></html>
        """.utf8)
    }

    /// Each connection accepts one bounded request, then closes. Slow responses deliberately keep
    /// the remainder behind a barrier: tests must observe native owner progress before cancelling.
    @MainActor
    final class Connection {
        let id = UUID()
        private let native: NWConnection
        private weak var server: BrowserDownloadLoopbackServer?
        private var buffer = Data()
        private var deadline: Task<Void, Never>?
        private var responded = false
        private(set) var closed = false
        private var receiveCallbacks = 0
        private var receivedBytes = 0
        private var headerBoundaryObserved = false
        private var parserRejected = false
        private var receiveComplete = false
        private var networkError = "none"
        private var transportState = "created"
        private var closeReason = "none"

        private func recordEvidence() {
            server?.recordConnection(id, fields: [
                "receiveCallbacks": String(receiveCallbacks),
                "receivedBytes": String(receivedBytes),
                "headerBoundaryObserved": String(headerBoundaryObserved),
                "parserRejected": String(parserRejected),
                "requestParsed": String(responded),
                "receiveComplete": String(receiveComplete),
                "networkErrorDomainCode": networkError,
                "transportState": transportState,
                "closed": String(closed),
                "closeReason": closeReason,
            ])
        }

        init(native: NWConnection, server: BrowserDownloadLoopbackServer) {
            self.native = native
            self.server = server
        }

        func start() {
            guard !closed, server?.stopped == false else {
                close()
                return
            }

            native.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, !self.closed, self.server?.stopped == false else {
                        return
                    }

                    switch state {
                    case .setup:
                        self.transportState = "setup"
                    case .preparing:
                        self.transportState = "preparing"
                    case .ready:
                        self.transportState = "ready"
                    case let .waiting(error):
                        self.transportState = "waiting"
                        self.recordNetworkError(error)
                    case let .failed(error):
                        self.transportState = "failed"
                        self.recordNetworkError(error)
                    case .cancelled:
                        self.transportState = "cancelled"
                    @unknown default:
                        self.transportState = "unknown"
                    }
                    self.recordEvidence()
                }
            }
            recordEvidence()
            native.start(queue: .main)
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.close(reason: "existingDeadline")
            }
            receive()
        }

        func close(reason: String = "callerClosed") {
            guard !closed else {
                return
            }

            closed = true
            closeReason = reason
            recordEvidence()
            deadline?.cancel()
            deadline = nil
            native.cancel()
            server?.connections.removeValue(forKey: id)
        }

        private func receive() {
            guard !closed, server?.stopped == false else {
                close()
                return
            }

            native.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                MainActor.assumeIsolated {
                    self?.didReceive(data, complete: complete, failed: error != nil, error: error)
                }
            }
        }

        /// The actual Network receive callback and deterministic late-delivery regression use
        /// this same guarded path. Closed connections cannot buffer or route any further bytes.
        func didReceive(_ data: Data?, complete: Bool, failed: Bool, error: NWError? = nil) {
            guard !closed, server?.stopped == false else {
                close()
                return
            }

            receiveCallbacks += 1
            receivedBytes += data?.count ?? 0
            receiveComplete = complete
            if let error {
                recordNetworkError(error)
            }
            if let data {
                buffer.append(data)
            }
            headerBoundaryObserved = buffer.contains(Data("\r\n\r\n".utf8))
            recordEvidence()
            do {
                if let request = try parseRequest() {
                    responded = true
                    recordEvidence()
                    server?.respond(to: request, on: self)
                } else if complete || failed {
                    close(reason: failed ? "receiveFailed" : "incompleteRequestEOF")
                } else {
                    receive()
                }
            } catch {
                parserRejected = true
                recordEvidence()
                close(reason: "parserRejected")
            }
        }

        /// Only typed error domain/code are retained; localized descriptions can contain endpoints.
        private func recordNetworkError(_ error: NWError) {
            let failure = error as NSError
            networkError = failure.domain + ":" + String(failure.code)
        }

        private func parseRequest() throws -> Request? {
            guard !responded, buffer.count <= 81_920 else {
                throw Failure.invalidRequest
            }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16_384 {
                    throw Failure.invalidRequest
                }
                return nil
            }
            guard boundary.lowerBound <= 16_384,
                  let text = String(data: buffer[..<boundary.lowerBound], encoding: .utf8)
            else {
                throw Failure.invalidRequest
            }

            let lines = text.components(separatedBy: "\r\n")
            let start = (lines.first ?? "").split(separator: " ")
            guard start.count == 3 else {
                throw Failure.invalidRequest
            }

            let headers = try parseHeaders(Array(lines.dropFirst()))
            let length = try bodyLength(headers)
            guard buffer.count >= boundary.upperBound + length else {
                return nil
            }

            return Request(
                method: String(start[0]),
                path: String(start[1]),
                headers: headers,
                body: buffer.subdata(in: boundary.upperBound ..< boundary.upperBound + length),
            )
        }

        private func parseHeaders(_ lines: [String]) throws -> [String: String] {
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else {
                    throw Failure.invalidRequest
                }

                let key = line[..<colon].lowercased()
                guard headers[key] == nil else {
                    throw Failure.invalidRequest
                }

                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return headers
        }

        private func bodyLength(_ headers: [String: String]) throws -> Int {
            guard headers["transfer-encoding"] == nil else {
                throw Failure.invalidRequest
            }
            guard let value = headers["content-length"] else {
                return 0
            }
            guard let length = Int(value), (0 ... 65_536).contains(length) else {
                throw Failure.invalidRequest
            }

            return length
        }

        func send(
            _ body: Data,
            type: String,
            status: String = "200 OK",
            headers: [String: String] = [:],
            headOnly: Bool = false,
        ) {
            var data = responseHead(
                type: type,
                status: status,
                headers: headers.merging(["Content-Length": "\(body.count)"]) { _, rhs in rhs },
            )
            if !headOnly {
                data.append(body)
            }
            native.send(
                content: data,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                },
            )
        }

        func sendSlow(_ body: Data, knownLength: Bool) {
            let headers = knownLength ? ["Content-Length": "\(body.count)"] : ["Transfer-Encoding": "chunked"]
            var data = responseHead(type: "application/octet-stream", status: "200 OK", headers: headers)
            let prefix = body.prefix(262_144)
            if !knownLength {
                data.append(Data("\(String(prefix.count, radix: 16))\r\n".utf8))
            }
            data.append(prefix)
            if !knownLength {
                data.append(Data("\r\n".utf8))
            }
            native.send(content: data, completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    self?.didSendSlowPrefix(failed: error != nil)
                }
            })
        }

        /// Ignore queued transport completions after either connection or server teardown.
        func didSendSlowPrefix(failed: Bool) {
            guard !closed, server?.stopped == false else {
                return
            }

            if failed {
                close()
            } else {
                server?.slowPrefixSent = true
            }
        }

        private func responseHead(type: String, status: String, headers: [String: String]) -> Data {
            let fields = headers.merging(["Content-Type": type, "Connection": "close"]) { _, rhs in rhs }
            let lines = fields.keys.sorted().map { "\($0): \(fields[$0] ?? "")" }.joined(separator: "\r\n")
            return Data("HTTP/1.1 \(status)\r\n\(lines)\r\n\r\n".utf8)
        }
    }
}
