import Foundation

/// Verbose diagnostics for the fixture server, enabled with the
/// `SPIKE_FIXTURE_DIAGNOSTICS` environment variable.
enum SpikeFixtureDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["SPIKE_FIXTURE_DIAGNOSTICS"] == "1"
}
