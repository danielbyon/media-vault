---
status: accepted
date: 2026-10-12
---

# Retain WKWebView as the visible browser for v1

The authenticated iOS/iPadOS browser retains its existing adapter-owned WKWebView for each logical web tab, rather than migrating the visible engine to SwiftUI WebPage/WebView or adopting an external browser shell. The TCA BrowserFeature remains the authority for tabs, Start Page, history/bookmarks, profile selection, URL-only restoration, preview revisions, and transitions; framework objects remain outside reducer state.

The trade-off is deliberate. Apple's SwiftUI WebKit APIs could simplify KVO, navigation, and view plumbing, but the six acquisition spikes establish no public app-owned file/destination/progress lifecycle after WebPage returns a download policy. The installed iOS 27 SDK also marks SwiftUI webViewContextMenu(menu:) unavailable on iOS; Spike 5's genuine long presses surfaced no selected-media callback. A companion WKWebView cannot generally reconstruct the visible page's cookies, POST/body, consumed signed request, or page-generated blob resource. Existing WKWebView preserves the already-implemented popup, refresh/keyboard arbitration, exact viewport snapshot, and tab transition behavior without a simultaneous migration. Existing link-context-menu behavior and WKDownload interfaces remain accessible through its public UIKit/WebKit delegates, although full ordinary-download integration is still unimplemented.

## Considered options

- **Full WebPage/WebView migration:** rejected for v1; download handoff is missing and popup, previews, refresh, PiP, and selected-element parity are not established.
- **WebPage with a never-mounted companion WKWebView or URLSession replay:** rejected as a general browser download implementation; Spikes 2–4 found credential/redirect, request replay, and blob incompatibilities.
- **Third-party browser libraries:** rejected as a wholesale replacement; Mozilla, DuckDuckGo, and wrapper offerings do not replace the app's established TCA tab/presentation and privacy policies at acceptable integration cost.
- **Retain the current WKWebView:** accepted, notwithstanding continued responsibility for its adapter implementation.

## Consequences and reconsideration

1. Build ordinary browser downloads on the *originating visible WKWebView* through public WKDownload delegate handoff, not by replaying a request in a companion. This is an implementation direction, not a runtime-parity claim.
2. Keep current Persistent-Private/Ephemeral website-data-store policies, app-owned tab persistence, preview cache lifetime, and decoy/authentication behavior unchanged.
3. A UIKit WKContextMenuElementInfo supplies a public linkURL, **not** a proven URL for an unlinked image/video. Retaining WKWebView does not close the selected-inline-media requirement in issue #43. Do not infer media selection from a page request or scrape the DOM.
4. Revisit SwiftUI WebPage only if the public iOS API exposes adequate download-file lifecycle and a supported selected-resource interface, and the existing browser's popup, refresh, preview, transition, and media behavior all pass parity tests.

**Decision scope:** Browser architecture only; no production downloads or Save-to-Vault functionality is declared complete. See docs/research/browser-architecture-evidence-and-decision.md.
