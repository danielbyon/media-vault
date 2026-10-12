import Foundation

/// Maps fixture paths to experiment behavior.
///
/// The mapping is deliberately explicit so that every measured case can be
/// traced to one decision, and so that no non-idempotent request is ever
/// replayed without a request body.
enum SpikeInterceptionPolicy {
    /// Action-time decision for a navigation.
    enum ActionDecision: Equatable {
        /// Let WebKit perform the request itself.
        case browser
        /// Cancel before WebKit sends anything and transfer with the app's session.
        case transfer(attachCredentials: Bool)
        /// Record method and body availability only; never replay.
        case postProbe
        /// Allow the action so the response reveals whether it is an attachment.
        case responseTriggeredTransfer
    }

    /// Response-time decision for a navigation response.
    enum ResponseDecision: Equatable {
        case allow
        /// Return the download policy so WebKit performs its own download.
        case webKitDownload
        /// Cancel and transfer with the app's session.
        case cancelAndTransfer
    }

    /// Action-time decision for a URL.
    static func actionDecision(for url: URL) -> ActionDecision {
        let path = url.path
        if path.hasPrefix(SpikeContract.responseTriggeredAttachmentPrefix)
            || path.hasPrefix(SpikeContract.responseTriggeredSignedPrefix) {
            return .responseTriggeredTransfer
        }
        if path.hasPrefix(SpikeContract.transferPrefix) {
            if path.hasPrefix(SpikeContract.postTransferPrefix) {
                return .postProbe
            }
            return .transfer(attachCredentials: path.contains(SpikeContract.credentialFragment))
        }
        return .browser
    }

    /// Response-time decision for a URL.
    static func responseDecision(for url: URL) -> ResponseDecision {
        let path = url.path
        if path.hasPrefix(SpikeContract.responseTriggeredAttachmentPrefix)
            || path.hasPrefix(SpikeContract.responseTriggeredSignedPrefix) {
            return .cancelAndTransfer
        }
        if path.hasPrefix(SpikeContract.Path.attachmentControlPrefix) {
            return .webKitDownload
        }
        return .allow
    }

    /// Stable case identifier derived from a URL and the transport mode.
    static func caseID(for url: URL, mode: String) -> String {
        let path = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
        return path.isEmpty ? mode : "\(path)-\(mode)"
    }
}
