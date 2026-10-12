import CryptoKit
import Foundation

/// Hashing helpers for the Spike 2 experiment.
enum SpikeHash {
    /// Full SHA-256 digest used for byte-identity comparisons.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Short SHA-256 prefix used for redacted value comparisons, so that a
    /// secret value can be compared without being persisted.
    static func prefix(_ value: String) -> String {
        prefix(Data(value.utf8))
    }

    /// Short SHA-256 prefix of raw bytes.
    static func prefix(_ data: Data) -> String {
        digest(data).prefix(16).description
    }
}
