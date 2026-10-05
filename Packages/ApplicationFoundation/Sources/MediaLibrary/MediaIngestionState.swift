/// The durable lifecycle of one media import accepted by the library.
///
/// Raw values are stored in SQLite. Keep them stable so a later application
/// version can continue reconciling imports written by an earlier version.
public enum MediaIngestionState: String, CaseIterable, Sendable {
    /// Original bytes are protected in app-controlled staging.
    case received

    /// The staged bytes are being checked against the supported media policy.
    case validating

    /// The validated item is ready for the duplicate-policy decision point.
    case duplicateCheck

    /// No duplicate decision is required and the item can be committed.
    case ready

    /// The permanent resource and canonical metadata are being committed.
    case committing

    /// Canonical metadata and its permanent resource are durably committed.
    case complete

    /// A later workflow must decide whether the accepted item can proceed.
    case awaitingUserDecision

    /// An attempted import stopped and retains its durable evidence.
    case failed

    /// Import was cancelled and retains its durable evidence for later policy.
    case cancelled
}
