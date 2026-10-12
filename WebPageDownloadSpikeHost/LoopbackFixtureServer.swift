import Foundation
import Network

struct ServerEvidence: Sendable {
    let kind: String
    let fixture: String
    let path: String
    let method: String?
    let cookie: String?
    let status: Int?
    let contentType: String?
    let contentDisposition: String?
    let location: String?
    let transferOutcome: String?
    let detail: String?
}

/// Serves deterministic HTTP fixtures from a dynamically assigned loopback port.
final class LoopbackFixtureServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WebPageDownloadSpike.loopback-server")
    private let onEvidence: @Sendable (ServerEvidence) -> Void
    private var listener: NWListener?

    init(onEvidence: @escaping @Sendable (ServerEvidence) -> Void) {
        self.onEvidence = onEvidence
    }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ListenerStartGate(continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue,
                          let url = URL(string: "http://127.0.0.1:\(port)/")
                    else {
                        gate.fail(FixtureServerError.missingPort)
                        return
                    }
                    gate.succeed(url)
                case let .failed(error):
                    gate.fail(error)
                case .setup, .waiting, .cancelled:
                    break
                @unknown default:
                    gate.fail(FixtureServerError.unknownListenerState)
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            var requestBytes = accumulated
            if let data {
                requestBytes.append(data)
            }

            let delimiter = Data([13, 10, 13, 10])
            if let range = requestBytes.range(of: delimiter) {
                self?.respond(to: connection, requestHeaders: Data(requestBytes[..<range.lowerBound]))
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.receiveRequest(on: connection, accumulated: requestBytes)
            }
        }
    }

    private func respond(to connection: NWConnection, requestHeaders: Data) {
        let request = parse(requestHeaders)
        let response = makeResponse(for: request)
        let evidence = ServerEvidence(
            kind: "server-request",
            fixture: response.fixture,
            path: request.path,
            method: request.method,
            cookie: request.headers["cookie"],
            status: response.status,
            contentType: response.headers["Content-Type"],
            contentDisposition: response.headers["Content-Disposition"],
            location: response.headers["Location"],
            transferOutcome: nil,
            detail: "request-target=\(request.target)"
        )
        onEvidence(evidence)

        let headerBlock = (["HTTP/1.1 \(response.status) \(response.reason)"] + response.headers.map { "\($0.key): \($0.value)" })
            .joined(separator: "\r\n") + "\r\n\r\n"
        let headerData = Data(headerBlock.utf8)

        if response.delayBodySeconds > 0 {
            connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                guard let self else {
                    connection.cancel()
                    return
                }
                if let error {
                    self.recordTransfer(response, request: request, outcome: "headers-send-failed: \(error)")
                    connection.cancel()
                    return
                }
                self.queue.asyncAfter(deadline: .now() + response.delayBodySeconds) {
                    connection.send(content: response.body, completion: .contentProcessed { [weak self] error in
                        if let error {
                            self?.recordTransfer(response, request: request, outcome: "body-send-failed: \(error)")
                        } else {
                            self?.recordTransfer(response, request: request, outcome: "delayed-body-sent")
                        }
                        connection.cancel()
                    })
                }
            })
            return
        }

        var fullResponse = headerData
        fullResponse.append(response.body)
        connection.send(content: fullResponse, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.recordTransfer(response, request: request, outcome: "send-failed: \(error)")
            } else {
                self?.recordTransfer(
                    response,
                    request: request,
                    outcome: response.truncated ? "truncated-response-sent" : "response-body-sent"
                )
            }
            connection.cancel()
        })
    }

    private func recordTransfer(_ response: FixtureResponse, request: ParsedRequest, outcome: String) {
        onEvidence(
            ServerEvidence(
                kind: "server-transfer",
                fixture: response.fixture,
                path: request.path,
                method: request.method,
                cookie: request.headers["cookie"],
                status: response.status,
                contentType: response.headers["Content-Type"],
                contentDisposition: response.headers["Content-Disposition"],
                location: response.headers["Location"],
                transferOutcome: outcome,
                detail: "declared-length=\(response.declaredLength);body-length=\(response.body.count)"
            )
        )
    }

    private func parse(_ requestBytes: Data) -> ParsedRequest {
        let text = String(decoding: requestBytes, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let requestParts = (lines.first ?? "").split(separator: " ", maxSplits: 2).map(String.init)
        let method = requestParts.first ?? "GET"
        let target = requestParts.dropFirst().first ?? "/"
        var headers: [String: String] = [:]

        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let components = URLComponents(string: "http://127.0.0.1\(target)")
        return ParsedRequest(
            method: method,
            target: target,
            path: components?.path ?? target,
            query: components?.percentEncodedQuery,
            headers: headers
        )
    }

    private func makeResponse(for request: ParsedRequest) -> FixtureResponse {
        switch request.path {
        case "/":
            return htmlResponse(
                fixture: "fixture-menu",
                body: Self.fixtureMenu,
                extraHeaders: ["Set-Cookie": "spike-auth=runtime-27; Path=/; SameSite=Lax"]
            )
        case "/normal":
            return htmlResponse(
                fixture: "normal-html-navigation",
                body: "<html><body><main><h1>Normal HTML destination loaded</h1><a href=\"/\">Back to fixture menu</a></main></body></html>"
            )
        case "/download-attribute":
            return dataResponse(
                fixture: "download-attribute",
                body: Data("download attribute payload\n".utf8),
                contentType: "text/plain; charset=utf-8"
            )
        case "/attachment":
            let fixture = request.query?.contains("source=redirect") == true
                ? "redirect-to-attachment"
                : "content-disposition-attachment"
            return dataResponse(
                fixture: fixture,
                body: Data("content disposition payload\n".utf8),
                contentType: "text/plain; charset=utf-8",
                contentDisposition: "attachment; filename=fixture.txt"
            )
        case "/non-displayable":
            return dataResponse(
                fixture: "non-displayable-mime",
                body: Data([0, 1, 2, 3, 4, 5, 255]),
                contentType: "application/x-spike-binary"
            )
        case "/redirect":
            return FixtureResponse(
                fixture: "redirect-to-attachment",
                status: 302,
                reason: "Found",
                headers: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "Content-Length": "0",
                    "Location": "/attachment?source=redirect",
                    "Connection": "close",
                ],
                body: Data(),
                declaredLength: 0,
                delayBodySeconds: 0,
                truncated: false
            )
        case "/cookie-attachment":
            guard request.headers["cookie"]?.contains("spike-auth=runtime-27") == true else {
                return dataResponse(
                    fixture: "cookie-authenticated-attachment",
                    status: 401,
                    reason: "Unauthorized",
                    body: Data("missing fixture cookie\n".utf8),
                    contentType: "text/plain; charset=utf-8"
                )
            }
            return dataResponse(
                fixture: "cookie-authenticated-attachment",
                body: Data("cookie-authenticated payload\n".utf8),
                contentType: "text/plain; charset=utf-8",
                contentDisposition: "attachment; filename=authenticated.txt"
            )
        case "/truncated-attachment":
            let body = Data(repeating: 0x5A, count: 64)
            return FixtureResponse(
                fixture: "truncated-attachment-failure",
                status: 200,
                reason: "OK",
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Disposition": "attachment; filename=truncated.bin",
                    "Content-Length": "2048",
                    "Connection": "close",
                ],
                body: body,
                declaredLength: 2048,
                delayBodySeconds: 0,
                truncated: true
            )
        case "/slow-attachment":
            let body = Data(repeating: 0x53, count: 1024)
            return FixtureResponse(
                fixture: "slow-attachment-cancellation",
                status: 200,
                reason: "OK",
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Disposition": "attachment; filename=slow.bin",
                    "Content-Length": "1024",
                    "Connection": "close",
                ],
                body: body,
                declaredLength: 1024,
                delayBodySeconds: 12,
                truncated: false
            )
        default:
            return dataResponse(
                fixture: "unknown",
                status: 404,
                reason: "Not Found",
                body: Data("fixture not found\n".utf8),
                contentType: "text/plain; charset=utf-8"
            )
        }
    }

    private func htmlResponse(fixture: String, body: String, extraHeaders: [String: String] = [:]) -> FixtureResponse {
        dataResponse(
            fixture: fixture,
            body: Data(body.utf8),
            contentType: "text/html; charset=utf-8",
            extraHeaders: extraHeaders
        )
    }

    private func dataResponse(
        fixture: String,
        status: Int = 200,
        reason: String = "OK",
        body: Data,
        contentType: String,
        contentDisposition: String? = nil,
        extraHeaders: [String: String] = [:]
    ) -> FixtureResponse {
        var headers = extraHeaders
        headers["Content-Type"] = contentType
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        if let contentDisposition {
            headers["Content-Disposition"] = contentDisposition
        }
        return FixtureResponse(
            fixture: fixture,
            status: status,
            reason: reason,
            headers: headers,
            body: body,
            declaredLength: body.count,
            delayBodySeconds: 0,
            truncated: false
        )
    }

    private static let fixtureMenu = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="icon" href="data:,">
      <meta charset="utf-8">
      <title>WebPage download fixture menu</title>
      <style>
        body { font: 18px -apple-system, sans-serif; margin: 24px; }
        a, button { display: block; margin: 14px 0; padding: 12px; font: inherit; }
      </style>
    </head>
    <body>
      <main>
        <h1>Fixture menu ready</h1>
        <p id="page-status" aria-live="polite">Waiting for a fixture interaction.</p>
        <a href="/normal">Normal HTML navigation</a>
        <a href="/download-attribute" download="attribute.txt">Download attribute</a>
        <a href="/attachment">Content-Disposition attachment</a>
        <a href="/non-displayable">Non-displayable MIME response</a>
        <a href="/redirect">Redirect to attachment</a>
        <a href="/cookie-attachment">Cookie-authenticated attachment</a>
        <button id="blob-download" type="button" onclick="createBlobDownload()">Create blob download</button>
        <a href="/truncated-attachment">Truncated attachment failure probe</a>
        <a href="/slow-attachment" download="slow.bin">Slow attachment cancellation probe</a>
      </main>
      <script>
        function createBlobDownload() {
          const blob = new Blob(["generated in the rendered page\\n"], { type: "text/plain" });
          const blobURL = URL.createObjectURL(blob);
          const link = document.createElement("a");
          link.href = blobURL;
          link.download = "page-generated.txt";
          document.getElementById("page-status").textContent = "Blob trigger executed from rendered page";
          link.click();
          window.setTimeout(() => URL.revokeObjectURL(blobURL), 1000);
        }
      </script>
    </body>
    </html>
    """
}

private struct ParsedRequest {
    let method: String
    let target: String
    let path: String
    let query: String?
    let headers: [String: String]
}

private struct FixtureResponse: Sendable {
    let fixture: String
    let status: Int
    let reason: String
    let headers: [String: String]
    let body: Data
    let declaredLength: Int
    let delayBodySeconds: TimeInterval
    let truncated: Bool
}

private enum FixtureServerError: Error {
    case missingPort
    case unknownListenerState
}

private final class ListenerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func succeed(_ url: URL) {
        guard let continuation = takeContinuation() else { return }
        continuation.resume(returning: url)
    }

    func fail(_ error: Error) {
        guard let continuation = takeContinuation() else { return }
        continuation.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}
