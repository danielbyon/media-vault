import Foundation

/// Enforces an origin boundary for redirects followed by a companion download.
enum WKDownloadOriginPolicy {
    /// Returns whether a redirect remains inside the request's original HTTP(S) origin.
    static func allowsRedirect(from source: URL, to destination: URL, initial: URL) -> Bool {
        guard let sourceOrigin = Origin(url: source),
              let destinationOrigin = Origin(url: destination),
              let initialOrigin = Origin(url: initial)
        else {
            return false
        }

        guard !(sourceOrigin.scheme == "https" && destinationOrigin.scheme == "http") else {
            return false
        }

        return sourceOrigin == destinationOrigin && destinationOrigin == initialOrigin
    }

    /// Provides a sanitized reason that can be included in experiment evidence.
    static func denialReason(from source: URL, to destination: URL, initial: URL) -> String {
        guard let sourceOrigin = Origin(url: source),
              let destinationOrigin = Origin(url: destination),
              let initialOrigin = Origin(url: initial)
        else {
            return "non-http-origin"
        }
        if sourceOrigin.scheme == "https" && destinationOrigin.scheme == "http" {
            return "https-downgrade"
        }
        if sourceOrigin != destinationOrigin {
            return "cross-origin"
        }
        if destinationOrigin != initialOrigin {
            return "outside-initial-origin"
        }
        return "allowed"
    }

    /// A normalized HTTP origin, including its effective port.
    private struct Origin: Equatable {
        let scheme: String
        let hostname: String
        let port: Int

        init?(url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased(),
                  !host.isEmpty
            else {
                return nil
            }
            self.scheme = scheme
            self.hostname = host
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }
}
