import Foundation

/// Mutable fixture state that must be resettable between test runs.
///
/// Signed token values exist only in this in-memory map so that raw tokens are
/// never written to evidence artifacts. The evidence recorder keeps the
/// sanitized ledger of labels and consumption outcomes.
final class SpikeFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var tokenLabelsByValue: [String: String] = [:]
    private var mintedTokenCount = 0

    /// Mint a new single-use token and return its raw value plus a stable label.
    func mintToken() -> (value: String, label: String) {
        lock.lock()
        defer { lock.unlock() }
        mintedTokenCount += 1
        let label = "token-\(mintedTokenCount)"
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokenLabelsByValue[value] = label
        return (value, label)
    }

    /// Sanitized label for a raw token value, when the token was minted here.
    func label(forToken token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokenLabelsByValue[token]
    }

    /// Drop all minted tokens.
    func reset() {
        lock.lock()
        tokenLabelsByValue.removeAll()
        mintedTokenCount = 0
        lock.unlock()
    }
}
