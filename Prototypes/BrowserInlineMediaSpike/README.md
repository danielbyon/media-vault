# Inline-media long-press experiment

This disposable target tests whether a SwiftUI `WebView` on iOS/iPadOS 27 can
identify an image or video selected by a real long press. The target is separate
from the shipping app and does not download, save, or ingest media.

## Components

1. `fixture_server.py` serves one centered target per page. It records fixed
   fixture request paths and bounded app/test observations in memory. The
   recorder uses a run-specific token for app/test posts; pages can only write
   the constrained page-world probe record.
2. `BrowserInlineMediaSpikeHost` displays a public SwiftUI `WebView`. Native
   mode installs no script. Bridge mode installs one public `WKUserScript` in
   `WKContentWorld.defaultClient` at document start in all frames. It listens
   for `contextmenu` and inspects at most eight entries in that event's
   composed path to separate selected media from an enclosing anchor.
   Diagnostic mode additionally listens for `pointerdown` and `touchstart`,
   but reports no source URLs for those events.
3. `BridgePayload` rejects malformed, synthetic, stale, and wrong-world
   messages. It leaves unsupported or credential-bearing URL candidates
   without a transferable media URL. All candidates remain untrusted page
   metadata. WebKit's content world and frame metadata are recorded
   separately. The decoder never authorizes a transfer.
4. The UI test target performs actual `XCUICoordinate.press(forDuration:)`
   interactions and retains a screenshot after each press. Accessibility menu
   labels are observed independently of WebKit messages.

## Reproduce

From the repository root, run:

```sh
bash Scripts/swift-tools.sh bootstrap
bash Prototypes/BrowserInlineMediaSpike/run-spike.sh
```

The runner finds the available iPhone 17 and iPad Pro 11-inch (M5) iOS 27
simulators, runs configured SwiftFormat and strict SwiftLint on every Spike 5
Swift file, runs parser and fixture tests, then serially runs the dedicated
`BrowserInlineMediaSpike` scheme on each device. Its timestamped output is
written under `.build/browser-inline-media-spike5/`; this directory is ignored
by Git. The raw recorder JSON contains fixed fixture paths and redacted URL
paths, not media bytes or credentials. A per-device Markdown matrix is also
generated. `git diff --check` runs last.

For a focused rerun of selected UI test methods, set `SPIKE_ONLY_TESTS` to
comma-separated method names. The same build, lint, fixture, and simulator
setup still runs; only the XCUITest selection changes.

The native API availability proof is reproducible with the installed SDK:

```sh
xcrun swiftc -typecheck \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios27.0-simulator \
  Prototypes/BrowserInlineMediaSpike/evidence/native-api-probe.swift
```

That probe intentionally fails because `WebView.webViewContextMenu` is marked
unavailable on iOS. The source is retained in the evidence directory, and the
runner captures the compiler diagnostic with its other validation logs. Native
menu visibility must therefore be read separately
from availability of an app context-menu callback.

## Interpretation

An XCUITest press proves an automation-delivered touch gesture, while the
screen attachment and accessibility labels show the resulting native menu.
Only an accepted `contextmenu` message can count as gesture-scoped selected
resource metadata. Pointer/touch diagnostics show event delivery but cannot
identify or authorize media. A page-supplied URL, including one accompanied by
`event.isTrusted`, is never permission to transfer bytes.
