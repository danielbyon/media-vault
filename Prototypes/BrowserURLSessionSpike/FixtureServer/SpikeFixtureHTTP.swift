import Foundation

/// One parsed HTTP/1.1 fixture request.
///
/// Raw header values stay in memory only. The evidence recorder stores names,
/// presence flags, and hashes instead of the values themselves.
struct SpikeFixtureRequest: Sendable {
    let method: String
    let path: String
    let rawQuery: String
    let queryItems: [SpikeQueryItem]
    let headerNames: [String]
    let body: Data
    private let headerValues: [String: String]

    /// Build a request from already parsed pieces. The raw header values stay
    /// private to this type so callers cannot accidentally persist them.
    init(
        method: String,
        path: String,
        rawQuery: String,
        queryItems: [SpikeQueryItem],
        headerNames: [String],
        body: Data,
        headerValues: [String: String]
    ) {
        self.method = method
        self.path = path
        self.rawQuery = rawQuery
        self.queryItems = queryItems
        self.headerNames = headerNames
        self.body = body
        self.headerValues = headerValues
    }

    /// Look up one header value by case-insensitive name.
    func header(_ name: String) -> String? {
        headerValues[name.lowercased()]
    }

    /// Look up one query value by name.
    func queryValue(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }
}

/// One decoded query item.
struct SpikeQueryItem: Sendable {
    let name: String
    let value: String
}

/// One response header line.
struct SpikeFixtureHeader: Sendable {
    let name: String
    let value: String
}

/// One fixture response, optionally paced over time.
struct SpikeFixtureResponse: Sendable {
    var status: Int
    var reason: String
    var headers: [SpikeFixtureHeader]
    var body: Data
    /// Pacing used to keep the transfer in flight for lifecycle observation.
    var throttle: SpikeFixtureThrottle?
    /// Content-Length announced to the client. Defaults to the body byte count.
    var declaredByteCount: Int?
    /// When true the connection is cancelled after the body bytes are handed to
    /// the transport, producing a truncated response instead of a clean close.
    var closesAbruptly: Bool = false

    /// Plain response with a UTF-8 body.
    static func text(
        status: Int = 200,
        reason: String = "OK",
        body: String,
        contentType: String = "text/plain; charset=utf-8",
        extraHeaders: [SpikeFixtureHeader] = []
    ) -> SpikeFixtureResponse {
        SpikeFixtureResponse(
            status: status,
            reason: reason,
            headers: [SpikeFixtureHeader(name: "Content-Type", value: contentType)] + extraHeaders,
            body: Data(body.utf8),
            throttle: nil,
            declaredByteCount: nil,
            closesAbruptly: false
        )
    }

    /// Serialized head block for this response, excluding the body.
    func headData(bodyLength: Int) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(bodyLength)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for header in headers {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }
}

/// Minimal HTTP/1.1 request parser for the deterministic fixture server.
enum SpikeFixtureHTTPRequestParser {
    /// Byte offset just past the header block, when the block is complete.
    static func headerBlockEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return index + 4
            }
            index += 1
        }
        return nil
    }

    /// Total number of bytes the request needs, when the head is complete.
    static func expectedRequestLength(in bytes: [UInt8]) -> Int? {
        guard let headEnd = headerBlockEnd(in: bytes) else { return nil }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        let contentLength = declaredContentLength(inHead: head)
        return headEnd + contentLength
    }

    /// Parse a complete request.
    static func parse(_ bytes: [UInt8]) -> SpikeFixtureRequest? {
        guard let headEnd = headerBlockEnd(in: bytes) else { return nil }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }

        var headerValues: [String: String] = [:]
        var headerNames: [String] = []
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headerNames.append(name)
            headerValues[name.lowercased()] = value
        }

        let target = String(parts[1])
        let splitTarget = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = splitTarget.first.map(String.init) ?? target
        let rawQuery = splitTarget.count > 1 ? String(splitTarget[1]) : ""
        let queryItems = rawQuery
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { pair -> SpikeQueryItem in
                let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(halves.first ?? "")
                let value = halves.count > 1 ? String(halves[1]) : ""
                return SpikeQueryItem(
                    name: name.removingPercentEncoding ?? name,
                    value: value.removingPercentEncoding ?? value
                )
            }

        let bodyStart = headEnd
        let body: Data
        if bytes.count > bodyStart {
            body = Data(bytes[bodyStart...])
        } else {
            body = Data()
        }

        return SpikeFixtureRequest(
            method: String(parts[0]).uppercased(),
            path: path,
            rawQuery: rawQuery,
            queryItems: queryItems,
            headerNames: headerNames.sorted(),
            body: body,
            headerValues: headerValues
        )
    }

    private static func declaredContentLength(inHead head: String) -> Int {
        for line in head.components(separatedBy: "\r\n") {
            let lowered = line.lowercased()
            guard lowered.hasPrefix("content-length:") else { continue }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: separator)...]
            return Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}
