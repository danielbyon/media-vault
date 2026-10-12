import Foundation

/// Shared fixture contract for the Spike 2 browser and background-transfer experiment.
///
/// The macOS host-process fixture server, the disposable iOS experiment host,
/// and the UI tests all compile this file so that ports, fixture paths,
/// synthetic credentials, anchors, and session identifiers cannot drift
/// between the three processes. Nothing in this file is used by the shipping
/// app, the browser feature, or the media library.
enum SpikeContract {
    /// Primary fixture origin. Loopback requests from the iOS Simulator reach
    /// the macOS listener because the simulator shares the host network stack.
    static let primaryHost = "127.0.0.1"
    /// Secondary fixture origin. It resolves to the same listener but is a
    /// different origin and a different cookie domain, which is what makes
    /// cross-origin credential tests meaningful.
    static let secondaryHost = "localhost"
    /// Fixed listener port so every process can agree without discovery.
    static let port = 18742

    /// Base URL string for one of the fixture origins.
    static func baseURLString(host: String) -> String {
        "http://\(host):\(port)"
    }

    /// Base URL for one of the fixture origins.
    static func baseURL(host: String) -> URL {
        guard let url = URL(string: baseURLString(host: host)) else {
            preconditionFailure("The fixture base URL must be constructible")
        }
        return url
    }

    /// URL for a fixture path on one of the fixture origins.
    static func url(host: String = primaryHost, path: String) -> URL {
        guard let url = URL(string: baseURLString(host: host) + path) else {
            preconditionFailure("The fixture URL must be constructible")
        }
        return url
    }

    /// Stable identifier for the app-owned background transfer session. Apple
    /// reattaches terminated applications to transfers through this value.
    static let backgroundSessionIdentifier = "com.danielbyon.mediavault.spike.browserurlsession.transfer"

    /// Request header the experiment app adds to every request it performs
    /// itself. A fixture request without this header came from WebKit.
    static let transportHeader = "X-Spike-Transport"
    /// Random, per-task join key that links server observations to task events.
    static let transferCorrelationHeader = "X-Spike-Transfer-Correlation"

    /// Values recorded for the transport header.
    enum Transport: String, Sendable {
        case backgroundURLSession = "urlsession-background"
        case foregroundURLSession = "urlsession-foreground"
    }

    /// Synthetic user name for the local HTTP authentication fixture. It is
    /// intentionally non-sensitive and must never appear in persisted artifacts.
    static let syntheticUserName = "spike-user"
    /// Synthetic password for the local HTTP authentication fixture.
    static let syntheticPassword = "spike-pass-2-synthetic"
    /// Synthetic browser-login cookie name.
    static let syntheticAuthCookieName = "spike-auth"
    /// Synthetic browser-login cookie value.
    static let syntheticAuthCookieValue = "spike-auth-2-synthetic"

    /// Cookie names whose scope behavior the experiment measures. Their values
    /// are deliberately non-secret so the fixture server can report exactly
    /// which marker arrived at which origin.
    enum ScopeMarker: String, CaseIterable, Sendable {
        case path = "spike-scope-path"
        case secure = "spike-scope-secure"
        case otherHost = "spike-scope-other-host"
        case expired = "spike-scope-expired"

        var value: String { "marker-\(rawValue)" }
    }

    /// User agent the experiment app owns and sets on its WebPages so that the
    /// browser request and the app transfer can be compared without reading
    /// platform-internal user agent strings.
    static let appOwnedUserAgent = "MediaVaultSpikeBrowser/1.0 (iOS 27.0; BrowserURLSessionSpike)"

    /// Directory name for host-side evidence artifacts under the repository
    /// build directory.
    static let evidenceDirectoryName = "spike-2-evidence"

    /// Directory name for the disposable app-owned scratch inside the iOS
    /// application container. It never touches the shipping vault.
    static let scratchDirectoryName = "BrowserURLSessionSpikeScratch"

    /// Directory name for the persisted experiment event log inside the iOS
    /// application container.
    static let appEvidenceDirectoryName = "BrowserURLSessionSpikeEvidence"

    /// Launch argument that resets disposable experiment state at startup.
    static let resetLaunchArgument = "--spike-reset"
    /// Delays hashing so the recovery test can terminate after the file move.
    static let delayTransferDigestArgument = "--spike-delay-transfer-digest"
    /// Launch arguments used to correlate the synthetic background-event probe.
    static let backgroundEventsProbeArgument = "--spike-background-events-probe"
    static let backgroundEventDeliveryIdentifierArgumentPrefix = "--spike-background-event-delivery-id="

    /// Fixture paths shared by the server, the app, and the UI tests.
    enum Path {
        static let menu = "/menu"
        static let health = "/health"
        static let evidence = "/__spike/evidence"
        static let appEvent = "/__spike/app-event"
        static let reset = "/__spike/reset"
        static let exportEvidence = "/__spike/export"
        static let lifecycleMarker = "/__spike/lifecycle-marker"

        static let stillControl = "/fixtures/still.png"
        static let stillTransfer = "/transfer/still.png"
        static let clipControl = "/fixtures/clip.bin"
        static let clipTransfer = "/transfer/clip.bin"

        static let attachmentControl = "/attach/control/clip.bin"
        static let attachmentTransfer = "/attach/transfer/clip.bin"
        static let attachmentControlPrefix = "/attach/control/"
        static let attachmentTransferPrefix = "/attach/transfer/"

        static let redirectControlSingle = "/redirect/control/one"
        static let redirectControlChain = "/redirect/control/chain"
        static let redirectChainControlSecond = "/redirect/control/chain-second"
        static let redirectTransferSingle = "/transfer/redirect/one"
        static let redirectTransferChain = "/transfer/redirect/chain"
        static let redirectChainTransferSecond = "/transfer/redirect/chain-second"

        static let credentialControlSameOrigin = "/credential/control/same-origin"
        static let credentialControlCrossOrigin = "/credential/control/cross-origin"
        static let credentialTransferSameOrigin = "/transfer/credential/same-origin"
        static let credentialTransferCrossOrigin = "/transfer/credential/cross-origin"
        static let credentialTerminal = "/credential/terminal"

        static let login = "/login"
        static let loginSubmit = "/login/submit"
        static let vaultControl = "/vault/asset"
        static let vaultTransfer = "/transfer/vault/asset"
        /// Page that offers the protected resources without signing in, so an
        /// unauthenticated profile can be measured against the same controls.
        static let vaultGuard = "/vault/guard"

        static let scopeSetup = "/scope/setup"
        static let scopeSetupOtherHost = "/scope/setup-host"
        static let scopeProbeControl = "/scope/probe"
        static let scopeProbeTransfer = "/transfer/scope/probe"

        static let refererGuard = "/referer/guard"
        static let refererControl = "/referer/asset"
        static let refererTransfer = "/transfer/referer/asset"

        static let originGuard = "/origin/guard"
        static let originControl = "/origin/asset"
        static let originTransfer = "/transfer/origin/asset"

        static let userAgentGuard = "/ua/guard"
        static let userAgentControl = "/ua/echo"
        static let userAgentTransferOwned = "/transfer/ua/echo"
        static let userAgentTransferDefault = "/transfer/ua/echo-default"

        static let postForm = "/post/form"
        static let postControl = "/post/inbox"
        static let postTransfer = "/transfer/post/inbox"

        static let signedMint = "/signed/mint"
        static let signedPreRequest = "/transfer/signed/consume"
        static let signedResponseTriggered = "/signed/attach/consume"

        static let blobGuard = "/blob/guard"

        static let lifecycleGuard = "/lifecycle/guard"
        static let lifecycleTransfer = "/transfer/lifecycle/clip-8m"

        static let failureClose = "/transfer/failure/close"
        static let failureCancel = "/transfer/failure/cancel"

        static let authGuard = "/auth/guard"
        static let authControl = "/auth/asset"
        static let authTransfer = "/transfer/auth/asset"
    }

    /// Every path prefix the experiment app intercepts and converts into an
    /// app-owned transfer instead of letting WebKit act on it.
    static let transferPrefix = "/transfer/"
    /// Prefix for attachment cases that must be intercepted after the response
    /// arrives, because only the response reveals the attachment disposition.
    static let responseTriggeredAttachmentPrefix = "/attach/transfer/"
    /// Prefix for signed one-time URLs that are only discovered after WebKit
    /// already consumed the token.
    static let responseTriggeredSignedPrefix = "/signed/attach/"
    /// Prefix for POST probes, which are never replayed without a request body.
    static let postTransferPrefix = "/transfer/post/"
    /// Path fragment that asks the app to attach synthetic credentials to an
    /// app-owned transfer so redirect propagation can be measured.
    static let credentialFragment = "/credential/"
}

/// One deterministic fixture payload served by the host-process fixture server.
enum SpikeFixtureAsset: String, CaseIterable, Sendable {
    case stillImage = "still-2k"
    case clipVideo = "clip-64k"
    case largeAttachment = "attach-2m"
    case largeClip = "clip-8m"
    case signedResource = "signed-2k"

    /// Number of bytes the fixture server sends for this asset.
    var byteCount: Int {
        switch self {
        case .stillImage: 2_048
        case .clipVideo: 65_536
        case .largeAttachment: 2_097_152
        case .largeClip: 8_388_608
        case .signedResource: 2_048
        }
    }

    /// Seed used by the deterministic payload generator.
    var seed: UInt8 {
        switch self {
        case .stillImage: 11
        case .clipVideo: 23
        case .largeAttachment: 37
        case .largeClip: 53
        case .signedResource: 71
        }
    }

    /// Content type announced for this asset.
    var contentType: String {
        switch self {
        case .stillImage: "image/png"
        case .clipVideo, .largeClip: "video/mp4"
        case .largeAttachment, .signedResource: "application/octet-stream"
        }
    }

    /// File name announced for attachment responses.
    var suggestedFilename: String {
        switch self {
        case .stillImage: "still.png"
        case .clipVideo: "clip.mp4"
        case .largeAttachment: "attach.bin"
        case .largeClip: "clip-8m.mp4"
        case .signedResource: "signed.bin"
        }
    }

    /// Transfer pacing for assets that must stay in flight long enough to
    /// observe suspension, cancellation, or early client disconnect.
    var throttle: SpikeFixtureThrottle? {
        switch self {
        case .largeAttachment: SpikeFixtureThrottle(chunkBytes: 65_536, chunkDelayMilliseconds: 500)
        case .largeClip: SpikeFixtureThrottle(chunkBytes: 131_072, chunkDelayMilliseconds: 500)
        case .stillImage, .clipVideo, .signedResource: nil
        }
    }

    /// Deterministic payload bytes. Every process that regenerates the payload
    /// produces identical bytes, so SHA-256 comparisons stay meaningful.
    var payload: Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in 0..<byteCount {
            bytes[index] = UInt8((index &* 31 &+ Int(seed)) % 251)
        }
        return Data(bytes)
    }
}

/// Pacing description for a throttled fixture response.
struct SpikeFixtureThrottle: Sendable {
    let chunkBytes: Int
    let chunkDelayMilliseconds: Int
}

/// One experiment case that both the rendered fixture menu and the UI tests
/// agree on, so that anchor labels and paths never drift.
struct SpikeFixtureCase: Sendable, Hashable {
    let id: String
    let title: String
    let controlLabel: String?
    let controlPath: String?
    let transferLabel: String?
    let transferPath: String?

    /// All cases rendered on the fixture menu.
    static let all: [SpikeFixtureCase] = [
        SpikeFixtureCase(
            id: "direct-still",
            title: "Direct still image",
            controlLabel: "control still image",
            controlPath: SpikeContract.Path.stillControl,
            transferLabel: "transfer still image",
            transferPath: SpikeContract.Path.stillTransfer
        ),
        SpikeFixtureCase(
            id: "direct-clip",
            title: "Direct video resource",
            controlLabel: "control video resource",
            controlPath: SpikeContract.Path.clipControl,
            transferLabel: "transfer video resource",
            transferPath: SpikeContract.Path.clipTransfer
        ),
        SpikeFixtureCase(
            id: "attachment",
            title: "Content-Disposition attachment",
            controlLabel: "control attachment",
            controlPath: SpikeContract.Path.attachmentControl,
            transferLabel: "transfer attachment",
            transferPath: SpikeContract.Path.attachmentTransfer
        ),
        SpikeFixtureCase(
            id: "redirect-single",
            title: "Single redirect",
            controlLabel: "control single redirect",
            controlPath: SpikeContract.Path.redirectControlSingle,
            transferLabel: "transfer single redirect",
            transferPath: SpikeContract.Path.redirectTransferSingle
        ),
        SpikeFixtureCase(
            id: "redirect-chain",
            title: "Redirect chain",
            controlLabel: "control redirect chain",
            controlPath: SpikeContract.Path.redirectControlChain,
            transferLabel: "transfer redirect chain",
            transferPath: SpikeContract.Path.redirectTransferChain
        ),
        SpikeFixtureCase(
            id: "credential-same-origin",
            title: "Credentials across a same-origin redirect",
            controlLabel: nil,
            controlPath: nil,
            transferLabel: "transfer same-origin credentials",
            transferPath: SpikeContract.Path.credentialTransferSameOrigin
        ),
        SpikeFixtureCase(
            id: "credential-cross-origin",
            title: "Credentials across a cross-origin redirect",
            controlLabel: nil,
            controlPath: nil,
            transferLabel: "transfer cross-origin credentials",
            transferPath: SpikeContract.Path.credentialTransferCrossOrigin
        ),
        SpikeFixtureCase(
            id: "signed-pre-request",
            title: "Single-use signed URL intercepted before the request",
            controlLabel: nil,
            controlPath: nil,
            transferLabel: "transfer signed pre-request",
            transferPath: SpikeContract.Path.signedPreRequest
        ),
        SpikeFixtureCase(
            id: "lifecycle",
            title: "Background and termination lifecycle transfer",
            controlLabel: nil,
            controlPath: nil,
            transferLabel: "transfer lifecycle clip",
            transferPath: SpikeContract.Path.lifecycleTransfer
        ),
        SpikeFixtureCase(
            id: "failure-close",
            title: "Server closes mid-transfer",
            controlLabel: nil,
            controlPath: nil,
            transferLabel: "transfer truncated response",
            transferPath: SpikeContract.Path.failureClose
        ),
        SpikeFixtureCase(
            id: "failure-cancel",
            title: "App cancels an in-flight transfer",
            controlLabel: nil,
            controlPath: nil,
            transferLabel: "transfer cancellable response",
            transferPath: SpikeContract.Path.failureCancel
        ),
    ]
}

/// Anchor labels for pages that require their own navigation flow. They are
/// shared so the UI tests can tap them by label without scraping the page.
enum SpikeAnchor {
    static let fixtureMenuReady = "Fixture menu ready"
    static let loginControlLink = "control vault asset"
    static let loginTransferLink = "transfer vault asset"
    static let loginSubmitButton = "sign in"
    static let scopeProbeControlLink = "control scope probe"
    static let scopeProbeTransferLink = "transfer scope probe"
    static let scopeOtherHostLink = "set other-host marker"
    static let refererControlLink = "control referer asset"
    static let refererTransferLink = "transfer referer asset"
    static let originControlLink = "control origin asset"
    static let originTransferLink = "transfer origin asset"
    static let userAgentControlLink = "control user agent"
    static let userAgentTransferOwnedLink = "transfer owned user agent"
    static let userAgentTransferDefaultLink = "transfer default user agent"
    static let postControlButton = "submit control post"
    static let postTransferButton = "submit transfer post"
    static let signedPreRequestLink = "transfer signed token"
    static let signedResponseTriggeredLink = "attachment signed token"
    static let blobTriggerButton = "generate blob download"
    static let lifecycleTransferLink = "transfer lifecycle clip"
    static let authControlLink = "control authenticated asset"
    static let authTransferLink = "transfer authenticated asset"
}

/// Identifiers for native host controls the UI tests drive.
enum SpikeControlIdentifier {
    static let menuButton = "spike-menu"
    static let statusLabel = "spike-status"
    static let evidenceJSON = "spike-evidence-json"
    static let profilePicker = "spike-profile"
    static let resetButton = "spike-reset"
    static let transferCountLabel = "spike-transfer-count"
    static let profilePersistentButton = "spike-profile-persistent"
    static let profileEphemeralButton = "spike-profile-ephemeral"
    static let ready = "spike-ready"
    static let backgroundEventsProbeButton = "spike-background-events-probe"
}
