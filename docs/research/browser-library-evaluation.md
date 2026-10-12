# Embedded Browser Library Evaluation

Date: 2026-09-29

## Question

Can the app replace most of its custom BrowserFeature implementation with an existing open-source Swift/iOS browser library while preserving the current product contract: isolated in-app browsing, multiple logical tabs, bookmarks/history, persistent-private and ephemeral profiles, URL-only tab restoration, app-owned start page and omnibox policies, tab previews/overview, and custom page-to-card transitions?

## Current implementation surface

The current BrowserFeature is not only a WKWebView wrapper. It owns logical tab state and selection, bookmarks/history, omnibox/suggestions, browser settings, website-data profile lifecycle, open-tab persistence and lazy restoration, back/forward presentation, JavaScript-dialog state, preview caching, refresh/keyboard arbitration, and custom tab transition coordination.

The product contract also requires an isolated in-app browser, prefers Apple-native behavior where it satisfies the contract, keeps browser persistence isolated, and prohibits turning the product into an analytics/remote-crash/developer-telemetry surface.

## Findings

### Apple WebKit for SwiftUI (not open source, but the strongest implementation-cost reduction)

Apple added native SwiftUI WebKit APIs in iOS 26: `WebView` and observable `WebPage`. Apple's browser sample uses these APIs for loading/observing content, back-forward history, custom URL schemes, favicons, favorites, and sharing, and explicitly says they simplify browser implementation compared with `WKWebView`.

`WebPage.Configuration.websiteDataStore` accepts a `WKWebsiteDataStore`; Apple documents a nonpersistent store for private browsing. `WKWebsiteDataStore` also supports persistent stores, including identified stores for profile browsing. This maps closely to the app's Persistent-Private/Ephemeral boundary.

These APIs can plausibly replace substantial low-level adapter/view/KVO/delegate plumbing while leaving the app-owned TCA state model, tab overview, persistence policies, and custom transitions intact. Apple does not appear to provide a complete multi-tab browser shell or the app's Safari-style page-to-card transition semantics.

Sources:
- https://developer.apple.com/documentation/webkit/building-a-cross-platform-web-browser
- https://developer.apple.com/documentation/webkit/webkit-for-swiftui
- https://developer.apple.com/videos/play/wwdc2025/231/
- https://developer.apple.com/documentation/webkit/webpage/configuration/websitedatastore
- https://developer.apple.com/documentation/webkit/wkwebsitedatastore

### Mozilla Firefox iOS BrowserKit

Firefox's repository contains a nested Swift package named `BrowserKit` with products including `WebEngine`, `TabDataStore`, `ToolbarKit`, `Redux`, and others. `WebEngine` defines one engine view plus multiple engine sessions; an engine session corresponds roughly to a tab and exposes loading, reload, back/forward navigation, find-in-page, back-forward lists, state restoration, and close operations. `TabDataStore` persists window/tab data.

This is the closest open-source reusable browser substrate found, but it is not a drop-in browser shell. Firefox's actual `TabManagerImplementation` remains in the Firefox application target and is approximately 1,410 lines; it owns normal/private tabs, selection, restoration, screenshots, and related orchestration. Therefore BrowserKit would replace low-level engine/session plumbing, not the app-specific tab/session/UI state that accounts for much of this project's custom behavior.

Integration also has nontrivial friction:
- BrowserKit is a nested `BrowserKit/Package.swift`; the repository root `Package.swift` exposes only a Danger development package, so BrowserKit is not directly consumable from the Firefox repository as a normal remote SwiftPM dependency without extracting/forking or otherwise repackaging it.
- `WebEngine` depends on BrowserKit's `Common`; `Common` declares a Sentry dependency. That dependency does not by itself prove telemetry is transmitted, but it creates policy/audit work for a product that explicitly disallows remote-crash/developer-telemetry surfaces.
- BrowserKit also carries its own Redux infrastructure rather than matching the app's TCA architecture.
- License: MPL-2.0.

Sources:
- https://github.com/mozilla-mobile/firefox-ios/blob/main/BrowserKit/Package.swift
- https://github.com/mozilla-mobile/firefox-ios/blob/main/Package.swift
- https://github.com/mozilla-mobile/firefox-ios/blob/main/BrowserKit/Sources/WebEngine/Engine.swift
- https://github.com/mozilla-mobile/firefox-ios/blob/main/BrowserKit/Sources/WebEngine/EngineSession.swift
- https://github.com/mozilla-mobile/firefox-ios/blob/main/BrowserKit/Sources/TabDataStore/README.md
- https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/TabManagement/TabManagerImplementation.swift
- https://github.com/mozilla-mobile/firefox-ios/tree/main/SampleBrowser

### DuckDuckGo BrowserServicesKit / apple-browsers

DuckDuckGo publishes its iOS/macOS browser source and shared browser modules. Its current `BrowserServicesKit` exports useful components including Bookmarks, History, Suggestions, ContentBlocking, DDGNavigation, and WK abstractions.

It is a subsystem library collection, not a complete embeddable multi-tab browser shell. The current package lives inside the apple-browsers monorepo and uses several local path dependencies to sibling packages, so adopting selected modules externally would likely require extraction/fork maintenance or bringing in a large portion of the repository. It could reduce cost for individual browser services, but it does not replace the app's tab model, chrome, overview, profile policy, restoration policy, or custom transitions.

License: Apache-2.0.

Sources:
- https://github.com/duckduckgo/apple-browsers
- https://github.com/duckduckgo/apple-browsers/blob/main/SharedPackages/BrowserServicesKit/Package.swift
- https://github.com/duckduckgo/BrowserServicesKit

### Brave

Brave's active iOS implementation lives inside `brave-core`; the older standalone `brave-ios` repository is archived. The source contains many browser-specific modules, but it is structured as a full browser application/product rather than a small embeddable browser SDK. Reusing it would resemble maintaining a fork/port and would not preserve the existing TCA/browser-state architecture cheaply.

License: MPL-2.0.

Sources:
- https://github.com/brave/brave-core/tree/master/ios/brave-ios
- https://github.com/brave/brave-ios

### Smaller Swift packages

Several maintained packages provide clean SwiftUI wrappers around WKWebView:
- Cybozu WebUI: active Swift 6.2 package, MIT; provides WKWebView in SwiftUI, delegates, configuration, refresh, and proxy APIs. Its own README points iOS 26+ projects toward Apple's native WebView.
- markbattistella/BrowserKit: MIT wrapper supporting SFSafariViewController/WKWebView.
- Kyle Hickinson SwiftUI-WebView: thin SwiftUI WKWebView wrapper.

These do not provide the multi-tab/session/bookmark/history/profile/overview behavior needed here and therefore would mostly replace code already superseded by Apple's native WebKit-for-SwiftUI API.

Sources:
- https://github.com/cybozu/WebUI
- https://github.com/markbattistella/BrowserKit
- https://github.com/kylehickinson/SwiftUI-WebView

Two projects look superficially closer but are not suitable drop-ins:
- AiBrowserKit has a full multi-tab UI only on macOS; iOS exposes lower-level WebKit helpers.
- NovaBrowser implements tabs, screenshots, bookmarks, history and private browsing as an iOS app, but is a very small/unproven project rather than a reusable package and its product/state semantics do not match this app.

Sources:
- https://github.com/NerdSnipe-Inc/AiBrowserKit
- https://github.com/omnificate/NovaBrowser

## Conclusion

No current open-source Swift package found is a clean replacement for the project's browser feature at comparable functionality and integration quality.

The highest-leverage path is not a wholesale browser-library replacement. It is to preserve the app-owned TCA browser domain and evaluate replacing the low-level WKWebView adapter/view plumbing with Apple's iOS 26+ `WebPage`/`WebView` APIs. Mozilla BrowserKit is the only open-source substrate worth a technical spike if an engine abstraction is desired, but its packaging, dependencies, architecture mismatch, and the fact that Firefox still owns its tab manager in the app target substantially reduce the expected savings.
