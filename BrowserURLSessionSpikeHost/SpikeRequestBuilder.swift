import Foundation

/// Builds app-owned transfer requests from observed WebKit navigation requests.
///
/// The builder is the single definition of request fidelity for the spike: it
/// decides which observed headers are copied, which are excluded because
/// URLSession owns them, and when synthetic credentials are attached for the
/// redirect-leak measurement.
@MainActor
enum SpikeRequestBuilder {
    /// Headers URLSession must own, plus credential headers the experiment
    /// never invents from an observation.
    static let excludedObservedHeaders: Set<String> = [
        "cookie",
        "host",
        "content-length",
        "connection",
        "proxy-connection",
        "accept-encoding",
        "authorization",
    ]

    /// Transfer paths that also run on the foreground control session.
    static let foregroundControlPaths: Set<String> = [SpikeContract.Path.stillTransfer]

    /// Build the app-owned transfer request for one observed browser request.
    static func transferRequest(
        from observed: URLRequest,
        cookies: [HTTPCookie],
        attachCredentials: Bool,
        omitUserAgent: Bool
    ) -> URLRequest {
        var request = URLRequest(url: observed.url ?? URL(string: "about:blank")!)
        request.httpMethod = observed.httpMethod ?? "GET"
        request.httpBody = observed.httpBody
        for (name, value) in observed.allHTTPHeaderFields ?? [:] where !excludedObservedHeaders.contains(name.lowercased()) {
            if omitUserAgent, name.caseInsensitiveCompare("User-Agent") == .orderedSame { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(SpikeContract.Transport.backgroundURLSession.rawValue, forHTTPHeaderField: SpikeContract.transportHeader)
        if let cookieHeader = SpikeCookieBridge.headerValue(cookies) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if attachCredentials {
            let pair = "\(SpikeContract.syntheticUserName):\(SpikeContract.syntheticPassword)"
            let encoded = Data(pair.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Deterministic form encoding for the replayed POST fixture.
    /// Serializes string fields using `application/x-www-form-urlencoded` encoding.
    static func formEncodedBody(_ values: [String: String]) -> Data {
        let encoded = values
            .sorted { $0.key < $1.key }
            .map { "\(formEncodedComponent($0.key))=\(formEncodedComponent($0.value))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func formEncodedComponent(_ value: String) -> String {
        value.utf8.map { byte in
            if byte == 0x20 {
                return "+"
            }
            if byte == 0x2A
                || (0x2D...0x2E).contains(byte)
                || byte == 0x5F
                || (0x30...0x39).contains(byte)
                || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
            {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }
        .joined()
    }

    /// Expected deterministic payload for a fixture URL, when one is served.
    static func expectedAsset(for url: URL) -> SpikeFixtureAsset? {
        switch url.path {
        case SpikeContract.Path.stillControl,
             SpikeContract.Path.stillTransfer,
             SpikeContract.Path.redirectTransferSingle,
             SpikeContract.Path.vaultControl,
             SpikeContract.Path.vaultTransfer,
             SpikeContract.Path.refererControl,
             SpikeContract.Path.refererTransfer,
             SpikeContract.Path.originControl,
             SpikeContract.Path.originTransfer,
             SpikeContract.Path.userAgentControl:
            return .stillImage
        case SpikeContract.Path.clipControl,
             SpikeContract.Path.clipTransfer,
             SpikeContract.Path.redirectTransferChain:
            return .clipVideo
        case SpikeContract.Path.attachmentControl:
            return .clipVideo
        case SpikeContract.Path.attachmentTransfer,
             SpikeContract.Path.failureCancel:
            return .largeAttachment
        case SpikeContract.Path.lifecycleTransfer:
            return .largeClip
        case SpikeContract.Path.signedPreRequest:
            return .signedResource
        default:
            return nil
        }
    }
}

extension SpikeRedaction {
    /// Host and path of a raw header value such as a Referer, without query.
    static func hostPath(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return "unparsable" }
        return (url.host ?? "unknown") + url.path
    }
}
