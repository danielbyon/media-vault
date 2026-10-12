# WebPage / WebView Browser Migration Spike

Date: 2026-09-29

## Question

Can the current BrowserFeature replace its hand-owned `WKWebView` adapter and UIKit mounting bridge with WebKit's native SwiftUI `WebPage` / `WebView` APIs without losing the product's existing browser behavior?

## Spike result

**Promising, but not yet safe as a wholesale replacement.**

The app can preserve its existing TCA browser domain and replace a large amount of low-level WebKit plumbing with a main-actor runtime that owns one `WebPage` per logical web tab. Apple's APIs cover the important browser-model seams: observable metadata, navigation events, typed navigation errors, back-forward history, navigation policy, JavaScript dialogs, data-store selection, JavaScript execution, media state, and SwiftUI-native context menus.

The migration has four unresolved runtime/product compatibility gates:

1. **Site-created popup/window semantics.** `WebPage.NavigationAction.target` exposes enough information to detect a navigation targeted at a new window, but no `WebPage` API was found that corresponds to `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`, which currently lets the app return a new `WKWebView` created from WebKit's supplied configuration. Replacing that with "cancel and open the URL in a new WebPage" would preserve ordinary target=_blank links but can change JavaScript popup semantics such as about:blank bootstrap, window.opener, script-written content, and window.close.

2. **Pull-to-refresh / keyboard arbitration.** SwiftUI `WebView` does not publicly expose its underlying `UIScrollView`, so the existing `UIRefreshControl` + pan-recognizer implementation cannot be ported directly. However, this is no longer considered blocked: `WebView` exposes WebKit scroll geometry and SwiftUI exposes scroll-phase observation for scrollable views. A public-API implementation can plausibly latch software-keyboard presence when interaction begins, observe downward overscroll through WebView scroll geometry, dispatch reload only after an eligible completed pull, and render an app-owned SwiftUI refresh indicator. The exact current arbitration semantics still require an iOS 27 runtime proof.

3. **Viewport previews and Safari-style transitions.** The current implementation captures `WKWebView` with `takeSnapshot` and registers the exact live `WKWebView` as the transition surface. `WebPage` supports exporting image/PDF content, and a SwiftUI `WebView` could also be hosted in an app-owned UIKit boundary and hierarchy-rendered, but neither option has yet been proven to produce the exact currently visible viewport pixels with the timing and reliability required by the existing tab-card transition contract. SwiftUI WebView does not expose the underlying `WKWebView` for the current live-surface transition path.

4. **Media boundary parity.** `WebPage.Configuration` exposes AirPlay and HTML-video playback behavior, and `WebPage` can close Picture-in-Picture/fullscreen media presentations. No configuration property equivalent to the current `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback = false` was found. If "PiP cannot start" is an invariant rather than simply a current setting, that requires a product decision or a retained WKWebView path.

These are compatibility questions, not objections to WebPage itself. The rest of the migration maps cleanly.

## Recommended architecture

Keep framework objects out of `BrowserFeature.State`. Continue to treat TCA as the authoritative logical browser model and persistence owner.

Suggested boundary:

```
BrowserFeature / TCA
  logical tabs
  selected tab
  Start Page
  omnibox + search policy
  bookmarks/history
  profile preference + confirmation
  URL-only open-tab restoration
  preview revision policy
  tab overview + transition state
            |
            v
BrowserPageClient               // reducer-facing, Sendable values only
            |
            v
@MainActor BrowserPageRuntime   // platform owner
  [BrowserTabID: PageContext]
  shared profile data store
  command/navigation correlation
  event projection
            |
            +---- PageContext
            |       WebPage
            |       navigation observer/task
            |       back-forward token projection
            |       navigation decider
            |       dialog presenter
            |
            v
WebView(page)                   // selected page only
```

A background logical tab can retain a `WebPage` even while it has no `WebView` attached. Apple explicitly supports using `WebPage` without displaying it. When selected, the page is bound to exactly one `WebView`.

Do **not** place `WebPage` in reducer state. It is a main-actor framework object and would couple the deterministic domain to UI/framework lifetime. The existing app-owned `BrowserTab` projection remains the correct TCA representation.

## Current-to-new mapping

| Current responsibility | WebPage / WebView replacement | Confidence | Notes |
| --- | --- | --- | --- |
| `BrowserWebKitAdapter.contexts` | `BrowserPageRuntime.pages[BrowserTabID]` | High | One WebPage per logical web tab |
| `WKWebView` KVO for title/loading/progress | Observable `WebPage.title`, `url`, `isLoading`, `estimatedProgress` | High | Removes KVO lifecycle |
| `WKNavigationDelegate` lifecycle | `WebPage.navigations` and per-command load sequences | High | Typed navigation events/errors |
| `WKBackForwardList` projection | `WebPage.backForwardList` | High | Items are Identifiable, Equatable, Sendable |
| reducer-issued load/reload/history commands | `page.load(...)`, `page.reload(fromOrigin:)`, `page.load(item)` | High | Each returns navigation event sequence |
| process termination mapping | `WebPage.NavigationError.webContentProcessTerminated` | High | Cleaner than delegate callback |
| JS alert/confirm/prompt | `WebPage.DialogPresenting` | High | File-input handling is also covered |
| link context menu | `.webViewContextMenu` | High | App can keep Open/New Tab/Copy/Share menu |
| back/forward gestures | `.webViewBackForwardNavigationGestures(.enabled)` | High | Native SwiftUI modifier |
| Persistent-Private profile | `configuration.websiteDataStore = .default()` | High | Same current app-scoped store behavior |
| Ephemeral profile | shared `.nonPersistent()` store used by every page in session | High | Rotate store when profile changes |
| custom navigation policy | `WebPage.NavigationDeciding` | High | Also exposes download intent and target frame |
| JavaScript calls | `WebPage.callJavaScript` | High | Native async Swift API |
| find UI | SwiftUI WebView find navigator | Medium/High | Validate exact Command-L / focus interactions |
| `BrowserWebView: UIViewRepresentable` | direct `WebView(page)` | High for display | Transition/refresh requirements complicate full deletion |
| popup creation | NavigationDeciding target interception | Partial | Loses WKUIDelegate create-web-view configuration semantics |
| `WKWebView.takeSnapshot` | WebPage image export or app-owned host capture | Unknown | Must prove visible viewport fidelity |
| live WebKit transition boundary | app-owned WebView host/frozen representation | Unknown | Changes current live-surface transition mechanism |
| UIRefreshControl + pan observation | WebView scroll geometry + SwiftUI scroll phases + app-owned indicator | Medium | Different implementation, but current gesture-latching semantics appear reproducible with public APIs; requires runtime proof |
| direct `UIScrollView.keyboardDismissMode` | likely `.scrollDismissesKeyboard(.interactively)` | Medium | Must verify it propagates to WebView in iOS 27 |
| disable PiP at configuration time | no equivalent identified | Partial/blocked | WebPage can close media presentations after the fact |

## Navigation correlation

The current `BrowserWebKitNavigationCorrelation` exists mainly because KVO metadata callbacks do not carry a `WKNavigation` identity and stale delegate callbacks can arrive after a newer reducer command.

`WebPage` should let this become smaller, but it should not be deleted blindly:

- `page.navigations` reports every user and programmatic navigation.
- A reducer-issued `load`, `reload`, or `load(backForwardItem)` returns a sequence scoped to that specific programmatic navigation.
- The runtime still needs an explicit rule for overlapping programmatic commands and user navigations so only the current logical navigation completes the current preview revision.

Recommended spike implementation: keep `BrowserNavigationOperationID` initially and move correlation into `BrowserPageRuntime.PageContext`. Use the command-specific sequence as the authoritative completion for reducer-issued work. Use the global `page.navigations` stream only for externally initiated navigation. After parity tests pass, evaluate whether the operation ID can be replaced with a simpler page revision.

This avoids combining "adopt WebPage" with a simultaneous reducer-state redesign.

## Profile lifecycle

The existing global profile boundary maps cleanly:

- Persistent-Private: all new `WebPage.Configuration` values receive the persistent app data store.
- Ephemeral: create one `WKWebsiteDataStore.nonPersistent()` per Browser ephemeral session and inject that same store into every WebPage created in that session.
- Switching profiles still retires/destroys every current page context and leaves the logical Browser with its existing one-fresh-Start-Page behavior.
- Bookmarks/history remain app-owned and are not migrated or erased by the website-data profile boundary.
- URL-only restart persistence stays unchanged; no WebPage session serialization should be introduced.

## Rendering strategy to test

The selected web tab should eventually render approximately as:

```swift
BrowserWebPageSurface(tabID: tab.id)
    .scrollDismissesKeyboard(.interactively)
```

where `BrowserWebPageSurface` resolves the existing runtime-owned WebPage and renders:

```swift
WebView(page)
    .webViewBackForwardNavigationGestures(.enabled)
    .webViewContextMenu { element in
        // existing app-owned link actions
    }
```

Do not resolve/create a WebPage from ordinary SwiftUI body recomputation. The runtime must keep page identity stable across view updates and tab-overview presentation changes.

## Required runtime spike before migration approval

A real iOS/iPadOS 27 executable spike should prove the following against public API only:

### Gate A — tab lifetime

1. Create two WebPages sharing the current profile data store.
2. Load both.
3. Render only page A, then replace the rendered WebView with page B, then A again.
4. Confirm page A retains DOM/history/scroll/session state while unmounted and background navigation remains coherent.
5. Confirm no WebPage is ever bound to two WebViews simultaneously.

### Gate B — keyboard and refresh

1. Apply `.scrollDismissesKeyboard(.interactively)` to WebView and verify a focused HTML field dismisses interactively.
2. Observe the WebView with `onScrollPhaseChange` and `webViewOnScrollGeometryChange`; verify interaction start/end and downward overscroll are reported reliably without accessing `UIScrollView`.
3. Reproduce the current latch rule: sample software-keyboard presence when the pull begins, keep that decision stable even if the keyboard dismisses during the drag, and consume each completed eligible pull exactly once.
4. Drive `WebPage.reload(...)` from that state machine and render an app-owned SwiftUI refresh indicator. Preserve ordinary scrolling and back/forward gestures.
5. Try `.refreshable` as an optional simplification, but do not depend on it unless runtime behavior proves WebView actually supplies the expected refresh UI/lifecycle.
6. If scroll phase or overscroll geometry is insufficient to reproduce the arbitration deterministically, retain the current WKWebView path for refresh rather than reaching into WebView internals.

### Gate C — previews and transitions

1. Render a deterministic local page with easily identifiable pixels.
2. Compare:
   - `WebPage.exported(as: image ...)` for the viewport region, if its image configuration provides the required viewport semantics;
   - hierarchy capture of an app-owned UIKit host containing `WebView(page)`.
3. Test before/after navigation commit, after one and two display turns, after scrolling, with images/video/canvas where practical.
4. Confirm that the captured image matches the actual visible viewport.
5. Run the existing page-to-card and card-to-page geometry transition using the host as a frozen surface.
6. Confirm there is no blank flash or stale-page frame.

### Gate D — site-created windows

Use deterministic pages that exercise:

1. ordinary `target="_blank"`,
2. `window.open("https://...")`,
3. `window.open("about:blank")` followed by script-written content,
4. opener-to-child JavaScript communication,
5. child `window.close()`.

If only cases 1–2 can be preserved by NavigationDeciding, decide explicitly whether the product accepts simplified popup semantics. If not, keep WKWebView for this behavior or reject the WebView migration.

### Gate E — media restrictions

1. Verify AirPlay remains disabled.
2. Attempt HTML5 PiP.
3. Determine whether WebView/WebPage can prevent PiP rather than merely close it afterward.
4. If not, decide whether the current PiP-disabled setting is a required product invariant.

### Gate F — browser download-to-vault acquisition

This is a **primary migration gate**, not a future follow-up. Browser acquisition is the reason the product ships a first-class browser, and issues #42/#43 require both ordinary WebKit-style downloads and explicit Save to Vault.

Current public `WebPage` APIs can identify download-intended navigation actions/responses and can return `.download`, but no public WebPage download-object/destination/progress lifecycle was found. WebKit previously implemented such a SwiftUI download coordinator and removed it before the public API shipped. Public `WKWebView` still exposes the full `WKDownload` lifecycle.

Run the dedicated experiments in `docs/research/browser-download-vault-spikes.md` before approving a WebPage migration. In particular, prove:

1. what actually happens after a WebPage navigation policy returns `.download`;
2. whether explicit HTTP(S) Save to Vault can use background URLSession while preserving browser login/session semantics;
3. whether a narrow WKWebView/WKDownload bridge is sufficient where WebKit semantics are required;
4. how inline unlinked media is identified for long-press Save to Vault, because SwiftUI WebView's public activated-element information currently exposes only a link URL;
5. that completed bytes enter protected receipt staging and the unified ingestion boundary before the UI reports acceptance, including lock/relaunch recovery.

If these cannot be satisfied cleanly with public APIs, retaining WKWebView for the visible browser is preferable to reducing browser plumbing at the expense of the browser's core acquisition job.

## Migration sequence if gates pass

1. Add `BrowserPageRuntime` behind the existing reducer-facing client contract. Preserve reducer actions/state and most tests.
2. Port profile creation, load/reload/back/forward, metadata, navigation failure/process termination, dialogs, and context menus.
3. Replace `BrowserWebView` with the WebView-based selected-page surface.
4. Port preview/readiness handling using the validated capture strategy.
5. Port or deliberately redesign refresh/keyboard behavior based on Gate B.
6. Port site-created-window behavior only to the level proven in Gate D.
7. Delete WKWebView-specific KVO/delegate/token/attachment/readiness code only after behavior tests no longer depend on it.
8. Rename `BrowserWebKitClient` only after the migration is complete; avoid combining semantic migration with broad naming churn.

## Expected code impact

Likely substantial simplification:
- `BrowserWebKitAdapter.swift`: mostly replaced.
- `BrowserWebView.swift`: mostly replaced if refresh/keyboard gate succeeds.
- `BrowserWebKitReadinessCoordinator.swift` / `BrowserWebKitReadinessProbe.swift`: likely replaced or significantly reduced if host capture timing is reliable.
- KVO and WKNavigationDelegate-specific navigation correlation: substantially reduced.
- JS dialog and link-menu UIKit plumbing: removed.
- direct WKBackForwardList projection mechanics: reduced.

Likely retained:
- BrowserFeature reducer/state/helpers.
- BrowserTab and logical tab policy.
- Browser settings/profile confirmation semantics.
- bookmarks/history/suggestions.
- open-tab URL persistence.
- tab overview layout/swipe/scroll anchoring.
- transition coordinator and geometry policy, although its web-content source may change from live WKWebView to a frozen host representation.
- preview revision/cache semantics.
- Browser navigation parsing/search-provider logic.

## Validation limitation of this spike

The repository targets iOS 27, but the available execution container has no Apple SDK/WebKit runtime and cannot compile or launch the iOS target. A small API-shaped WebPage/WebView prototype was drafted against the current Apple documentation to expose integration seams, but it was intentionally not retained as production source because it could not be compiled or behavior-tested here.

The remaining uncertainty is therefore concentrated in the explicit runtime gates above rather than in the high-level architecture.
