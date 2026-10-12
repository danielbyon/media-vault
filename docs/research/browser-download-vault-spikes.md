# Browser Download-to-Vault Spikes

Date: 2026-09-29

## Why this is a migration gate

Browser acquisition is not an incidental browser feature in this product. The product contract requires Browser to be a first-class acquisition path, requires every acquisition source to converge on one durable ingestion pipeline, and requires accepted bytes to be under app control in protected staging before receipt acknowledgment.

Issues #42 and #43 deliberately split two behaviors:

- **#42 Browser Download Handling** — ordinary browser downloads, including non-media downloads, with no permanent Downloads library.
- **#43 Save Browser Media to Vault** — explicit user acquisition of supported accessible media/links into the unified ingestion pipeline.

A WebPage/WebView migration is therefore acceptable only if these flows can be preserved without private WebKit APIs, scraping, restriction circumvention, or a browser-specific permanent store.

## Current repository boundary

The current `MediaLibraryClient.importFile(URL)` is an import tracer, not the future browser-acquisition boundary. It assumes a caller already owns a readable local source URL, copies that file into protected staging, validates one ordinary still image, finalizes the resource, and commits it before returning.

That is correct for the current Files tracer but is insufficient for browser acquisition because browser acquisition must eventually support:

- network transfer progress and cancellation;
- background continuation where the platform permits;
- protected staging receipt before canonical validation/commit;
- durable ingestion recovery through issue #13;
- media and non-media download classification;
- browser session/authentication continuity;
- lock/relaunch behavior;
- multiple future media kinds.

The product contract also distinguishes protection classes: final resources/caches use `.complete`, while background-receipt staging uses `.completeUnlessOpen`. The current resource repository applies `.complete` to its staging tree, so browser background receipt should not simply download into the current tracer's staging directory.

## Important WebPage/WebView finding

The public SwiftUI WebKit API exposes enough information to **identify** download navigations:

- `WebPage.NavigationAction.shouldPerformDownload` reports a web-content download intent.
- A navigation decider can return `.download` for a navigation action.
- A navigation decider can return `.download` for a navigation response, which is how attachment/non-displayable responses are normally converted to downloads.

However, the public `WebPage` API does not currently expose the matching download object/event/destination lifecycle that `WKWebView` exposes with `WKDownload` and `WKDownloadDelegate`.

This is not merely an omission in sample code. WebKit added a SwiftUI download design in January 2025 with `WebPage.startDownload`, an observable downloads sequence, and a download coordinator, then removed that implementation in March 2025 before the public SwiftUI API shipped. Current WebKit source still exposes download policy decisions but not that client-facing WebPage download lifecycle.

By contrast, public `WKWebView` still provides:

- `startDownload(using:)`;
- navigation-action/response-to-`WKDownload` delegate callbacks;
- destination selection;
- suggested filenames;
- progress;
- redirects;
- authentication challenges;
- failure resume data.

This creates a real migration risk for #42.

## Separate the transfer problem from the ingestion problem

The browser should not own canonical import semantics. The eventual shape should be:

```
Browser interaction
       |
       v
Browser acquisition intent
  - ordinary download
  - Save to Vault
       |
       v
Acquisition transport
  - WebKit download, or
  - background URLSession
       |
       v
protected receipt staging
       |
       v
unified ingestion boundary (#13)
  received -> validating -> duplicateCheck
  -> ready -> committing -> complete
       |
       v
Media Library
```

The transfer transport may differ by browser interaction while both paths converge once bytes are safely staged.

## Spike 1 — Public WebPage ordinary downloads

### Question

Can a shipping app using only public `WebPage` / `WebView` APIs receive and manage the file produced after returning `.download`?

### Fixture

Use a local deterministic HTTP server and a WebPage-backed WebView with routes for:

1. `<a download href="/image.jpg">`;
2. normal link whose response has `Content-Disposition: attachment`;
3. response with a MIME type WebKit cannot display;
4. redirect into an attachment;
5. authenticated download using a browser cookie;
6. a generated `blob:` download.

### Experiment

The navigation decider returns `.download` when:

- `NavigationAction.shouldPerformDownload == true`, or
- the navigation response is an attachment/non-displayable type.

Record every public callback/event available to the app.

### Pass condition

A public API provides the resulting download/file, destination selection, progress, completion/failure and cancellation semantics sufficient to route the result into app-controlled staging.

### Fail condition

WebKit begins/converts the navigation to a download but the app has no public API to obtain/control the resulting file.

### iOS 27 result — 2026-10-08

**Experiment verdict: FAIL. Task status: completed.** The iOS 27 runtime returned `.download` for the rendered-page fixtures, but the public `WebPage` / SwiftUI `WebView` surface exposed no resulting download object, destination decision, file URL handoff, download progress, completion, failure, cancellation, or resume data. The missing public seam is decisive; the ten-second observation windows are supporting runtime evidence, not the sole basis for the result.

#### Public SDK surface inspected

The iOS 27 `WebKit.swiftinterface` exposes `NavigationAction.request` and `shouldPerformDownload`, `NavigationResponse.response` and `canShowMimeType`, action/response methods on `WebPage.NavigationDeciding`, navigation events, `WebPage.estimatedProgress`, and page-level `stopLoading()`. `WebPage.NavigationEvent` contains provisional start, server redirect, commit, and finish events; it is a page-navigation sequence, not a download lifecycle. `WebPage.NavigationDeciding` has no download-object handoff method.

The public `_WebKit_SwiftUI.WebView` interface exposes initializers for a `WebPage` or URL and no raw `WKWebView` or download delegate. The same iOS 27 SDK separately includes `WKWebView` navigation delegate `didBecomeDownload` callbacks and `WKDownload` / `WKDownloadDelegate` APIs for destination selection, progress, cancellation, completion, failure, and resume data. Those APIs are attached to `WKWebView`; this experiment did not bridge or use them, and the public `WebPage` / `WebView(WebPage)` interface provides no connection to them.

The interface evidence came from these files in the installed iOS 27 SDK:

- `WebKit.framework/Modules/WebKit.swiftmodule/arm64-apple-ios-simulator.swiftinterface`: `NavigationAction`, `NavigationResponse`, and `NavigationDeciding` (lines 336–379); `WebPage.navigations` and `estimatedProgress` (lines 528–538); `WebPage.stopLoading()` (line 601).
- `Cryptexes/OS/System/Library/Frameworks/_WebKit_SwiftUI.framework/Modules/_WebKit_SwiftUI.swiftmodule/arm64-apple-ios-simulator.swiftinterface`: `WebView.init(WebPage)` and `WebView.init(url:)` (lines 91–94).
- `WebKit.framework/Headers/WKNavigationDelegate.h`: action/response `didBecomeDownload` callbacks (lines 183 and 192).
- `WebKit.framework/Headers/WKDownload.h` and `WKDownloadDelegate.h`: download object, cancellation, destination, completion, failure, and resume data (for example, lines 63, 70, 99, and 106).

In the WebPage Swift interface, `NavigationAction.shouldPerformDownload` and `NavigationResponse.canShowMimeType` are present, while no WebPage download lifecycle symbols are present.

#### Runtime fixture matrix

Each case was initiated by tapping a control in the rendered page. The blob case used a rendered page button whose JavaScript created and clicked the `blob:` anchor. HTTP request and transfer evidence came from the loopback fixture server. Tests require fixture-specific policy events after each baseline and validate each HTTP response classification and server transfer. The redirect's initial 302 and final attachment response are checked independently. HTTP download fixtures had a ten-second observation window after their server transfers; the generated blob fixture had a ten-second window after its page-side trigger. The failure probe waited for the server's truncated-transfer record before collecting runtime events. The cancellation probe records the server send outcome after `WebPage.stopLoading()`.

**Evidence boundary:** Runtime tests establish that each rendered interaction occurred, that the expected action-level or response-level policy was returned, and that the matching local fixture response/transfer was recorded. They collect the public runtime events that actually exist, but do not assert the absence of synthetic download-lifecycle event kinds. Inspection of the installed iOS 27 SDK interfaces establishes that the WebPage/WebView surface has no public download handoff or lifecycle APIs; the runtime observations support that finding but do not independently prove an API is nonexistent. A server send-completion outcome means the local send operation completed; it does not prove that the WebPage or app consumed the body.

| Fixture | Runtime policy and callback evidence | Loopback / page-side evidence | Runtime result |
| --- | --- | --- | --- |
| Normal HTML control | Action `.allow`; response `.allow`, HTTP 200, `canShowMimeType=true`; navigation committed and finished; the exported trace includes page `estimatedProgress` samples 0.1 and 0.5. | `GET /normal`, HTTP 200, full 114-byte body. | Control passed. |
| `<a download>` | Action-level policy recorded `shouldPerformDownload=true` and `.download`; a response-policy event was not observed in the runtime trace. | `GET /download-attribute`, HTTP 200, `text/plain`, no attachment header; response send completed with declared/body length 27/27. | Runtime policy and fixture evidence verified; overall lifecycle FAIL comes from SDK interface inspection. |
| `Content-Disposition: attachment` | Action `.allow`; response-level `.download`, HTTP 200, `text/plain`, `canShowMimeType=true`, `Content-Disposition: attachment; filename=fixture.txt`. The attachment header, not MIME alone, drove the policy. | `GET /attachment`, HTTP 200, full 28-byte body; response send completed. | Runtime policy and fixture evidence verified; overall lifecycle FAIL comes from SDK interface inspection. |
| Non-displayable MIME | Action `.allow`; response-level `.download`, HTTP 200, `application/x-spike-binary`, `canShowMimeType=false`. | `GET /non-displayable`, HTTP 200, full 7-byte body; response send completed. | Runtime policy and fixture evidence verified; overall lifecycle FAIL comes from SDK interface inspection. |
| Redirect to attachment | Action `.allow` for `/redirect` and the redirected attachment; response-level `.download` on the final HTTP 200 `text/plain` attachment, `canShowMimeType=true`. | Independently verified `/redirect` HTTP 302 and `Location: /attachment?source=redirect`, then the final attachment HTTP 200 and full 28-byte body; both response sends completed. | Runtime policy and fixture evidence verified; overall lifecycle FAIL comes from SDK interface inspection. |
| Cookie-authenticated attachment | Action `.allow`; response-level `.download`, HTTP 200, `text/plain`, `canShowMimeType=true`, attachment header. | `GET /cookie-attachment` included `spike-auth=[synthetic cookie value redacted]`; the HTTP 200 response send completed with declared/body length 29/29. | Runtime policy and fixture evidence verified; overall lifecycle FAIL comes from SDK interface inspection. |
| Generated `blob:` download | The rendered page confirmed the button's JavaScript trigger ran; the action recorded `shouldPerformDownload=true` and action-level `.download`. | No loopback HTTP request occurred for the generated blob. | Runtime page-side trigger and policy verified; overall lifecycle FAIL comes from SDK interface inspection. |
| Truncated-response failure probe | Response-level policy returned `.download` for HTTP 200 with `canShowMimeType=false` and an attachment header. WebKit reported `application/macbinary` as `URLResponse.mimeType`; the server's `Content-Type` header was `application/octet-stream`. Runtime observations were collected after the server transfer. | Server recorded `truncated-response-sent`: declared length 2048 bytes, body length 64 bytes, then closed. | Runtime policy and truncated server outcome verified; overall lifecycle FAIL comes from SDK interface inspection. |
| Slow-transfer cancellation probe | Action-level policy returned `.download` with `shouldPerformDownload=true`; the host then called public `WebPage.stopLoading()`. | After Stop, the server recorded `delayed-body-sent` for the 1024-byte body (send completion). This reports the server send result, not proof the client consumed the body. | Runtime policy, Stop ordering, and server outcome verified; overall lifecycle FAIL comes from SDK interface inspection. |

The exported normal-control trace contains `WebPage.estimatedProgress` samples 0.1 and 0.5 before navigation completion. The download fixtures may emit page-level navigation progress, but the recorded values are not download progress and no download-specific progress API is present in the inspected WebPage/WebView interfaces. The truncated fixture's server-side send outcome does not demonstrate that WebKit consumed the body or expose a download failure callback. Server completion is not evidence that the app received or controlled a file.

**Remaining uncertainty:** this run exercised iOS 27 simulators, not physical devices, and does not establish whether WebKit internally retained or system-managed any downloaded bytes. Runtime traces contained no file handle or download lifecycle callback, but that observation does not prove an API is absent. Inspection of the installed public SDK interfaces establishes the API boundary independently of the observation window.

#### Runtime and commands

- Xcode 27.0, build 27A266a.
- iOS Simulator SDK 27.0.
- iOS 27.0 simulator runtime, build 24A434.
- Exercised on iPhone 17 and iPad Pro 11-inch (M5) simulators.
- `rtk make spike-webpage-download` — the fixture-matrix UI test passed on iPhone 17 (167.125 seconds) and iPad Pro 11-inch (M5) (173.540 seconds), iOS 27. Xcode's post-test simulator-diagnostics collection for the iPad hit its 600-second timeout after XCTest reported the test pass; treat that as a simulator-diagnostics limitation, not a fixture assertion failure.
- `rtk bash ./Scripts/with-xcode-27-rc.sh xcodebuild -quiet -skipMacroValidation -workspace App.xcworkspace -scheme WebPageDownloadSpike -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -clonedSourcePackagesDirPath $REPOSITORY_ROOT/.build/SourcePackages -derivedDataPath $TMPDIR/media-vault-spike-final-dd build-for-testing` — passed.
- `rtk bash ./Scripts/with-xcode-27-rc.sh xcodebuild -quiet -skipMacroValidation -workspace App.xcworkspace -scheme WebPageDownloadSpike -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -clonedSourcePackagesDirPath $REPOSITORY_ROOT/.build/SourcePackages -derivedDataPath $TMPDIR/media-vault-spike-final-dd -resultBundlePath $TMPDIR/media-vault-spike-final2.xcresult test-without-building` — one UI test passed; the structured fixture matrix was exported from its result bundle.
- `rtk make lint` — passed with exit code 0; SwiftFormat and SwiftLint reported no formatting or lint violations, and the compiler-backed analyzer completed its enabled rules.
- `rtk make build` — passed with exit code 0 for normal App Debug/Release iPhone and Debug iPad builds.
- `rtk make test` — passed with exit code 0 for the normal App test suite and `ApplicationFoundation` package tests.
- `rtk bash ./Scripts/with-xcode-27-rc.sh xcodebuild -version` — Xcode version check.
- `rtk bash ./Scripts/with-xcode-27-rc.sh xcrun --sdk iphonesimulator --show-sdk-version` — SDK version check.

**Decision:** Do not approve a full `WebPage` replacement for ordinary browser downloads on parity alone. The public WebPage policy callback can initiate a download, but the app cannot own the resulting file lifecycle through this API surface.

**Recommended next spike:** Proceed separately to the documented Spike 2, which tests a WebPage intent plus background `URLSession` transfer against browser cookies, redirects, request method/body/headers, authentication, signed URLs, and background behavior. Treat `blob:` as a known incompatibility unless a separate mechanism is demonstrated. This result does not implement that bridge or migrate BrowserFeature.

## Spike 2 — WebPage intent + background URLSession transfer

### Question

Can a user-initiated request in the public `WebPage` / SwiftUI `WebView` browser be handed to an app-owned background `URLSession` while preserving the browser session's cookies, request headers, method/body, redirects, and authentication behavior, and does that transfer survive the lifecycle states the product contract needs?

### Experiment verdict — 2026-10-08

**Experiment verdict: PARTIAL (no scenario was BLOCKED). Task status: completed.**

The disposable iOS 27 host (`BrowserURLSessionSpikeHost`), UI test target (`BrowserURLSessionSpikeTests`), and separate macOS host-process fixture server (`Prototypes/BrowserURLSessionSpike`) ran 16 tests on each simulator with 0 failures. Run `20261009T004803Z` saved separate snapshots before the next device could reset the shared fixture: `.build/spike-2-evidence/iphone-17.json` and `.build/spike-2-evidence/ipad-pro-11-m5.json`. The iPhone trace contains 652 requests and 1,456 app events (613 WebKit, 37 background URLSession, 2 foreground URLSession); the iPad trace contains 607 requests and 1,394 app events (568, 37, and 2 respectively). Each snapshot carries its simulator label, and each hash event joins to its transfer through task, process, run, role, and correlation identifiers.

Across distinct transfer correlations, the iPhone snapshot records 19 byte-identical SHA-256 results, 8 cases without a hash verdict, and 2 expected negative mismatches; the iPad records 14 byte-identical results, 8 without a hash verdict, and the same 2 negative mismatches. Hash equality is asserted for direct resources, redirects, response-triggered attachment replay, Persistent-Private cookie access, Referer, pre-request signed URLs, and lifecycle transfers. Request-semantic probes for cookie scope, User-Agent, POST, and HTTP authentication are assessed from server observations and are not presented as hash comparisons. The experiment remains PARTIAL: a manually attached `Cookie` header crossed an origin-changing redirect; a response-triggered single-use URL was consumed by WebKit before replay; `blob:` has no HTTP(S) URL; and system relaunch and force-quit remain unverified.

### Candidate flow

```unknown
NavigationAction.request (public WebKit request snapshot)
        |
        +-- action-time interception (the transfer path this spike measures)
        |     |
        |     +-- cookies from the page's exact WKWebsiteDataStore
        |     |     (WKHTTPCookieStore + RFC 6265 scope filter)
        |     +-- observed headers copied except URLSession-owned / credential headers
        |     |
        |     v
        |   background URLSessionDownloadTask (stamped X-Spike-Transport)
        |     |
        |     v
        |   delegate moves the system temporary file into disposable scratch
        |     |
        |     v
        |   SHA-256 compared against the fixture server's payload hash
        |
        +-- response-time interception (only when the response reveals an attachment)
              WebKit performs the request; the response policy cancels it;
              the remembered action request is replayed once by the same session
```

### Session bridge

Implemented rules (disposable host only; nothing in this bridge exists in the shipping browser):

1. The experimental page is created with `WebPage.Configuration.websiteDataStore` set to the exact store under test — `WKWebsiteDataStore.default()` for the Persistent-Private profile (the shipping browser's default behavior) and `WKWebsiteDataStore.nonPersistent()` for Ephemeral. No other code path creates or reads a cookie jar for the transfer.
2. Cookies are read from that store's `WKHTTPCookieStore` (`cookies(for:)`) and filtered with the RFC 6265 rules the bridge implements: domain match (including `.domain` suffix rules), path match, Secure (HTTPS only), expiry, and empty value. Every cookie decision (name, included/excluded, reason) is recorded.
3. The transfer request is built from the observed `NavigationAction.request`: URL, method, body, and observed headers are copied except `cookie`, `host`, `content-length`, `connection`, `proxy-connection`, `accept-encoding`, and `authorization`. The `Cookie` header is set from cookies scoped to the initial request URL. This does not scope that literal header again after a redirect; the cross-origin fixture demonstrated that URLSession forwarded it to the new host.
4. Both app-owned sessions disable URLSession's own cookie machinery (`httpCookieStorage = nil`, `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`) so a transfer cannot silently depend on URLSession's shared cookie jar. Apple documents shared cookie storage as the default for background sessions; a separate URLSession cookie-store design was not tested and must not be assumed to preserve WebPage store isolation.
5. Every app-owned request carries `X-Spike-Transport: urlsession-background` (or `urlsession-foreground` for the control). WebKit requests carry no such header, so the fixture server can attribute every request to the transport that actually performed it.
6. Each navigation decider owns an immutable profile. The transfer captures that profile before asynchronous cookie lookup and reads only that profile's WebPage store. A deterministic gate paused a Persistent-Private cookie read, changed the selected profile to Ephemeral, and verified the transfer still used and recorded the Persistent-Private cookie. The test then tore down without an active transfer.

### Background redirect and credential boundary

Apple's background download documentation states that redirects are always followed and `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` is not called for a background session ([Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)). The host implements the delegate callback for comparison, but the recorded background transfers did not receive it. The server observed the app-attached `Cookie` header at the `localhost` target of a redirect from `127.0.0.1`; `Authorization` was stripped, but the cookie was not.

This means the current background-session design has no per-hop delegate point at which it can remove or re-scope that manually attached cookie. Treat arbitrary cookie-authenticated URLs that may redirect across origins as unsupported and unsafe for this bridge. Do not ship the current header bridge for that class. A future design needs an independently enforceable redirect boundary (for example, a resource class whose server contract forbids cross-origin redirects) or a different transfer mechanism; the experiment did not establish a safe general-purpose alternative. Apple's default background cookie store is shared ([URLSessionConfiguration.httpCookieStorage](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpcookiestorage)), so turning it on is not a demonstrated substitute for the exact WebPage store.

### Fixture matrix as executed

Sixteen UI tests, each driving rendered-page controls or the documented lifecycle probe:

1. `test01` direct still/video GETs and one/chain redirects (control and transfer paths);
2. `test02` `Content-Disposition: attachment`: WebKit-native control and response-triggered transfer;
3. `test03` in-page login, cookie scope markers, persistent-versus-ephemeral isolation, and same-origin / cross-origin credential redirects;
4. `test04` Referer, Origin, and owned/default User-Agent;
5. `test05` form POST probe and one controlled replay;
6. `test06` single-use signed URLs intercepted before the request and triggered at the response;
7. `test07` HTTP Basic authentication: browser challenge and background-session challenge;
8. `test08` failure and cancellation (server truncates mid-response; app cancels in flight);
9. `test09` `blob:` limitation;
10. `test10` background/suspension (8 MiB throttled transfer while the app is backgrounded);
11. `test11` harness-initiated termination and explicit relaunch;
12. `test13` successful completion, digest, and active/persisted metadata cleanup;
13. `test14` profile selection changing while cookie preparation is paused;
14. `test15` cancellation and reconciliation of a retrying task before reset;
15. `test16` background-event timeout state and completion-handler ordering;
16. `test99` matrix summary and redaction verification.

Fixture paths and payloads come from one shared contract (`SpikeFixtureContract.swift`) compiled into server, host, and tests: still 2,048 B PNG, clip 65,536 B MP4, attachment 2,097,152 B throttled at 64 KiB/500 ms, lifecycle clip 8,388,608 B throttled at 128 KiB/500 ms, signed resource 2,048 B. Payload bytes are deterministic per asset seed and regenerated in every process, so SHA-256 comparisons are meaningful without transferring hashes.

### Per-case decision table

| Case | Browser-side observation | App-owned transfer | Status |
| --- | --- | --- | --- |
| Direct still | Control page GET served the 2,048 B still. | Action-time interception; background download 2,048 B, scratch SHA-256 = server SHA-256 = expected payload. | PASS |
| Direct clip | Control page GET served the 65,536 B clip. | Background download 65,536 B, byte-identical. | PASS |
| Single redirect | Fixture server recorded `302` on the redirect and `200` on the terminal. | Background session followed one hop; 2,048 B SHA-256 matched. | PASS |
| Redirect chain | Fixture server recorded `302 → 302 → 200` across the three requests; the UI assertion checks these codes. | Background session followed the chain; 65,536 B SHA-256 matched. | PASS |
| Attachment (WebKit control) | Plain link whose response is an attachment; the app observed the action and the served bytes. | No app-owned transfer: WebKit downloaded it itself, was never asked for a response policy, and exposes no completion handoff. | PARTIAL |
| Attachment (response-triggered) | Action allowed so the response reveals `Content-Disposition`; WebKit began its own GET (131,072 of 2,097,152 B sent) before the cancel. | Remembered action request replayed once; background download 2,097,152 B byte-identical. | PASS |
| Vault cookie transfer | In-page login set the session cookie in the page's exact store. | Persistent-Private transfer returned `200`, attached the scoped cookie, and matched the 2,048 B asset hash. The Ephemeral negative control returned `403` (`session-cookie-missing`). | PASS |
| Cookie scope | Page set path-, Secure-, expired-, and other-host marker cookies. | Bridge excluded every out-of-scope marker and included only in-scope cookies. | PASS |
| Credentials, same-origin redirect | Fixture server recorded `302` to a same-origin terminal (`200`). | Authorization was dropped and scoped Cookie retained on the terminal; 203 B response. | PASS |
| Credentials, cross-origin redirect | Fixture server recorded `302` to `localhost` (different origin, same listener). | Authorization dropped, but the app-attached Cookie header reached the cross-origin terminal (`hasSyntheticAuthCookie=true`); background redirect delegate did not run. | FAIL |
| Store isolation | Ephemeral profile loaded the same protected page. | Ephemeral transfer carried no Persistent-Private cookie; server recorded `session-cookie-missing`. | PASS |
| Referer | Guard page served the asset only when the observed Referer was present. | Replayed Referer; 2,048 B byte-identical. | PASS |
| Origin | Top-level navigation carried no `Origin` header. | The app-owned request received `403` (`origin-missing-or-mismatched`); no value existed to copy and the experiment refused to invent one. | UNVERIFIED |
| User-Agent (copied) | Page used the spike-owned UA; server echoed it. | Copied UA reproduced exactly. | PASS |
| User-Agent (omitted) | Same observed UA. | Omitting it produced the session default, so fidelity requires copying the observed value. | PASS |
| POST replay | Form submission intercepted before WebKit sent it; the encoded body was observable on the intercepted request. | One controlled `200` replay carried the same 18 bytes; the fixture inbox recorded one side effect. | PASS |
| Signed URL, pre-request | Action-time interception of a URL carrying a one-time token. | Background session consumed `[synthetic one-use token redacted]` (2,048 B byte-identical); `[synthetic one-use token redacted]` remains unused in the ledger. | PASS |
| Signed URL, response-triggered | WebKit's unavoidable `200` request consumed `[synthetic one-use token redacted]` before the response revealed the attachment. | Background replay received `403 token-already-consumed` (26 B). | FAIL |
| HTTP auth, browser | `401` challenge surfaced to `NavigationDeciding`. | WebKit accepted the supplied synthetic credential. | PASS |
| HTTP auth, background | `401` challenge to the background task. | Task-level delegate challenge delivered and satisfied; no credential persisted. | PASS |
| Truncated response | Fixture declared `200` and closed before the body completed. | A truncated response produced 8 attempts with growing backoff and no terminal outcome inside the observation window; the platform retried the idempotent GET instead of surfacing a failure. | PARTIAL |
| Cancellation | Throttled response in flight. | Task cancellation stopped it; the server observed the early close. | PASS |
| `blob:` | Page-generated `blob:` download triggered. | No HTTP(S) URL exists; deliberately not transferred. | FAIL |
| Background suspension | 8 MiB throttled transfer; app stays backgrounded for the bounded transfer window. | On both devices the server completed all 8 MiB, URLSession delivered its terminal callback, and the app hashed the file before foreground reactivation. See device-specific byte counts and timestamps below. | PASS |
| Harness termination | `XCUIApplication.terminate()` issued by the test harness. | Not system termination; reported as harness-initiated only. | PARTIAL |
| Explicit relaunch | `app.launch()` after harness termination. | New process instance reattached or received the transfer (`task-restored`); byte-identical hash after relaunch. | PARTIAL |
| Completion cleanup | Successful direct background transfer. | `test13` joins start, terminal, digest, and settled events by task/process/run/correlation; completion and matching SHA-256 precede settled state with 0 active records and 0 unfinished metadata. | PASS |
| Profile change during preparation | Persistent-Private cookie lookup held before store access; selection changed to Ephemeral. | `test14` used only the originating profile's exact WebPage store and attribution; teardown had no active transfer. | PASS |
| Reset during retry | A truncated-response task was active when reset began. | `test15` cancelled and reconciled the task before clearing scratch and metadata; server observed no later retries or callback attributed to the new run. | PASS |
| Background event timeout | Test harness probes a delivery whose event stream remains unresolved. | `test16` records `deliveryState=incomplete` and retains the handler; it does not report successful event delivery or release the system handler on timeout. | PASS |
| System relaunch | — | No genuine system-initiated launch was produced. | UNVERIFIED |
| Force-quit | — | Not exercised. Apple documents that a user force-quit cancels background transfers and prevents automatic relaunch; that is the documented expectation, not runtime coverage ([Apple's background URLSession documentation](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background%28withidentifier%3A%29)). | UNVERIFIED |
| Redaction | Raw fixture evidence and the app export were checked for the synthetic secrets. | No password, cookie value, credential pair, or signed token value present. | PASS |
| Matrix summary | — | PASS. | PASS |

### Lifecycle strategy and evidence

The lifecycle cases need a fixture that stays alive while the iOS app does not, so the server runs as a separate macOS host process on loopback port 18742. An in-app server cannot establish survival after suspension or termination, and the host process can also record the exact moment a connection closes.

The app-owned background session uses the stable identifier `com.danielbyon.mediavault.spike.browserurlsession.transfer`, `isDiscretionary = false`, and `sessionSendsLaunchEvents = true`. The app retains the system completion handler until `urlSessionDidFinishEvents(forBackgroundURLSession:)`. A 25-second timeout records an incomplete delivery while retaining the handler; timeout is not treated as event completion. `test16` exercises that state through a harness probe, not an operating-system delivery cycle. The download delegate moves the system temporary file into disposable scratch before returning, and the coordinator waits for file handoff, terminal callback, digest, and metadata cleanup before declaring a transfer settled.

The independent fixture server records send samples and response completion times. For `test10`, the app background interval and server observations were:

| Device | Background interval (host timestamps) | Bytes sampled after backgrounding | Server response complete | App terminal / SHA-256 | Foreground reactivation |
| --- | --- | ---: | --- | --- | --- |
| iPhone 17 | 1791507356.483–1791507392.268 | 7,995,392 of 8,388,608 | 1791507390.069 | 1791507390.097 / 1791507390.108 | 1791507392.268 |
| iPad Pro 11-inch (M5) | 1791508585.034–1791508620.454 | 8,126,464 of 8,388,608 | 1791508618.665 | 1791508618.692 / 1791508618.695 | 1791508620.454 |

The bytes sampled after backgrounding exclude bytes sent before the background marker. In both traces the server sent the complete 8 MiB response and recorded completion, then the app recorded its terminal callback and matching SHA-256 before foreground reactivation. The expected and downloaded lifecycle hash was `eb537eedd2998c4bfa00fc9ebcc6adfaf61b05923c3a05db1f8e2a7f78a2d8b6` on each device.

For `test11`, the restored task, moved file, terminal callback, and digest are joined by task ID `1`, transfer correlation, run ID, and process instance. The iPhone and iPad correlation and process-instance UUIDs are redacted in this review copy. On each device, the restored task was followed by the file move, terminal callback, and digest; these are historical Spike 3 events, not Spike 4 evidence.

Reset cancels tasks from both sessions and waits for task disappearance, terminal callbacks, digest work, and any pending background event handler before clearing metadata or scratch. If its bounded wait expires, it records `runtime-reset-incomplete` and preserves that state. The dedicated `test15` passed on both devices and found no retry after reset. The iPad snapshot also records a separate earlier reset timeout at 1791508538.504 with one remaining session task and one pending terminal callback; that attempt preserved state and is not counted as a completed reset. System-initiated relaunch and user force-quit were not exercised and remain UNVERIFIED. All lifecycle evidence is simulator-only; no physical-device run was performed.

### Environment

- Xcode 27.0 (27A266a); fixture server built with `swiftc -swift-version 6`.
- iOS 27.0 simulators: iPhone 17 `[iPhone 17 simulator UDID redacted]`; iPad Pro 11-inch (M5) `[iPad Pro 11-inch M5 simulator UDID redacted]`.
- Host-process fixture server on loopback port 18742 with two origins: `127.0.0.1` (primary) and `localhost` (secondary, same listener but a different origin and cookie domain, which is what makes the cross-origin credential case meaningful).
- Run identifier `20261009T004803Z`. Per-device fixture traces are `.build/spike-2-evidence/iphone-17.json` and `.build/spike-2-evidence/ipad-pro-11-m5.json`; their result bundles are `.build/spike-2-evidence/20261009T004803Z-iphone-17.xcresult` and `.build/spike-2-evidence/20261009T004803Z-ipad-pro-11-m5.xcresult`. The runner snapshots the iPhone trace before starting the iPad suite, which resets shared fixture state. `fixture-server.json` is the latest server snapshot (iPad); use the labeled per-device snapshots for device-specific comparisons.

### Exact validation commands

```sh
make spike-browser-urlsession   # runs ./Prototypes/BrowserURLSessionSpike/run-spike.sh
```

`run-spike.sh` performs, in order:

1. fixture server build (host process, Swift 6):
   ```sh
   bash ./Scripts/with-xcode-27-rc.sh xcrun swiftc -swift-version 6 -O -g \
     -o .build/spike-browser-urlsession/bin/spike-fixture-server \
     Prototypes/BrowserURLSessionSpike/Shared/SpikeFixtureContract.swift \
     Prototypes/BrowserURLSessionSpike/FixtureServer/*.swift
   ```
2. start the server on port 18742 with `--evidence .build/spike-2-evidence/fixture-server.json` (the script refuses to start when the port already has a listener);
3. run the dedicated scheme on each device, iPhone first:
   ```sh
   bash ./Scripts/with-xcode-27-rc.sh xcodebuild -skipMacroValidation \
     -workspace App.xcworkspace -scheme BrowserURLSessionSpike -configuration Debug \
     -destination 'platform=iOS Simulator,name=<device>,OS=27.0' \
     -clonedSourcePackagesDirPath .build/SourcePackages -derivedDataPath <temporary> test
   ```
4. `curl -fsS http://127.0.0.1:18742/__spike/export`, then SIGTERM the server (10-second grace, SIGKILL fallback) so it persists evidence before exiting.

Measured results: iPhone 17: 16 tests, 0 failures; iPad Pro 11-inch (M5): 16 tests, 0 failures. Focused reruns covered direct/redirect correlation and successful completion cleanup. Repository gates `make lint`, `make build`, and `make test` passed after the simulator matrices; the Delegation v3 `RESULT.json` records the gate outcomes.

The Delegation-bound `repo_validate` `all` profile ran `make all` as one bounded command twice. The first attempt timed out at 900 seconds during iPhone Release compilation. The retry completed linting with zero reported violations, then timed out at 900 seconds while the compiler-backed analyzer built SwiftParser. The independent `make lint`, `make build`, and `make test` runs passed; Delegation technical readiness remains failed on its bound `all` validation check.

### Public SDK surface inspected

- `WebKit.framework/Modules/WebKit.swiftmodule/arm64-apple-ios-simulator.swiftinterface` (iPhoneSimulator SDK): `WebPage.Configuration.websiteDataStore` (line 132); `NavigationAction` (336) with `request` (346) and `shouldPerformDownload` (349); `NavigationResponse` (362); `NavigationDeciding` (375); `WebPage.navigations` (528). `NavigationAction.request` exposes URL, method, headers, and a body when WebKit has one; no public WebPage API exposes a download object, destination decision, or download completion. Apple's [`websiteDataStore`](https://developer.apple.com/documentation/webkit/webpage/configuration/websitedatastore) and [`WebPage.NavigationAction`](https://developer.apple.com/documentation/webkit/webpage/navigationaction) documentation describes these public surfaces.
- `WebKit.framework/Headers/WKWebsiteDataStore.h`: `defaultDataStore` (47), `nonPersistentDataStore` (53), `httpCookieStore` (85).
- `WebKit.framework/Headers/WKHTTPCookieStore.h`: observer protocol (41), `getAllCookies:` (58), `setCookie:completionHandler:` (70), `deleteCookie:` (81).
- `Foundation.framework/Headers/NSURLSession.h` (iPhoneSimulator SDK): `backgroundSessionConfigurationWithIdentifier:` (1297), `discretionary` (1398), `sessionSendsLaunchEvents` (1421), `URLSession:didBecomeInvalidWithError:` (1650), `URLSessionDidFinishEventsForBackgroundURLSession:` (1672), and download delegate callbacks `didFinishDownloadingToURL:` (1861) and `didWriteData:totalBytesWritten:totalBytesExpectedToWrite:` (1866). Apple's [`URLSessionDownloadTask`](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask) documentation describes temporary-file handling; [`Downloading files in the background`](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background) describes suspension, relaunch, and redirect limitations.

Unavailable or absent request fields on this surface: `Origin` is not present for top-level navigations, there is no public download object or destination handoff, and a replay is a new request rather than a resumed or duplicated WebKit transfer — which is exactly why this experiment compares server-observed bytes for both transports instead of assuming equivalence.

### Redaction verification

The fixtures use known synthetic secrets (`[synthetic Basic password redacted]`, `[synthetic cookie value redacted]`, and one-time `token` query values). After the run, the exported evidence was searched for those raw strings: no occurrence of `[synthetic Basic password redacted]`, `[synthetic cookie value redacted]`, `token=`, `[synthetic Basic credential pair redacted]` was found in the exported evidence document. The server stores cookie names and a shared cookie-hash prefix rather than values, and query **keys** rather than query values; the app-side export emits names, presence flags, counts, and hashes only. Test 12 asserts the same absence against both the fixture evidence document and the app export at runtime.

### Unsupported and unverified subset

1. Cross-origin credential forwarding is unsafe for the tested background-session bridge: the app-attached `Cookie` header survives a redirect to a different origin. Apple documents that background sessions always follow redirects without calling the redirect delegate, so this bridge cannot implement per-hop stripping there. Do not use it for arbitrary cookie-authenticated URLs until a redirect boundary is enforced outside that callback.
2. Response-triggered interception cannot support single-use URLs: WebKit's own request consumes the token before the app can transfer it. Only action-time interception works for that class.
3. `blob:` page-generated downloads are not HTTP(S) resources and were deliberately not transferred.
4. WebKit-native attachments remain outside app control (no response-policy callback, no completion handoff), which reproduces Spike 1's finding inside this harness.
5. Truncated responses are retried by the background session with growing backoff and produced no terminal outcome inside the observation window, so failure surfacing must be designed around, not assumed.
6. System-initiated relaunch and user force-quit are UNVERIFIED; lifecycle evidence is simulator-only and, for the termination case, harness-initiated.
7. `Origin` cannot be reconstructed from the public navigation action for top-level navigations.

### Pass condition and overall assessment

Pass condition: HTTP(S) resources reachable in the normal browser session produce byte-identical downloads through the background URLSession for the supported matrix, including browser login cookies, and survive the background lifecycle the product contract requires.

Outcome: the per-device evidence records byte-identical downloads for the supported action-time HTTP(S) subset, with hashes correlated to the corresponding task and server request. Separate server-observed assertions confirmed cookie scope, User-Agent, POST-body replay, HTTP authentication, and cancellation; those request-fidelity cases are not described as hash-verified. Background execution and the test-harness relaunch path were demonstrated; genuine system relaunch remains unverified. An earlier iPad reset timeout also remains visible as incomplete evidence, while the dedicated cancellation/reset regression passed. The measured unsupported and unsafe classes mean an app-owned session is a viable transport only for an explicit subset of browser-initiated media requests, not a drop-in replacement for WKDownload semantics.

### Recommendation for #42 and #43

- Save to Vault (#43): the action-time bridge works for the measured ordinary HTTP(S) subset, but do not ship it for arbitrary cookie-authenticated URLs. A background session follows redirects without a delegate decision, and this run proved an exact-store cookie header can cross origins. Restrict any candidate use to requests whose resource contract independently guarantees no cross-origin redirect, or choose another transfer design; this spike did not prove a general safe alternative. Use action-time interception for single-use URLs. Treat response-time replay as an extra request and only consider it for idempotent resources. HTTP authentication used a transient credential in the harness; credential persistence was not established.
- Ordinary browser downloads (#42): an app-owned session cannot cover `blob:` or WebKit-native attachments, so it is not a full replacement for the WebKit download path; the practical shape remains hybrid.
- Full WebPage migration: this spike does not block it and does not complete it. The transfer/session seam is workable for the supported subset, but browser-parity download semantics (Spike 3) and the remaining lifecycle proof (system relaunch, physical device) stay open.

## Spike 3 — WebPage browsing + WKWebView download bridge (completed 2026-10-09)

### Question and assessment

Can a visible public `WebPage`/SwiftUI `WebView` hand an explicitly selected HTTP(S) request to a retained, non-visible `WKWebView` that uses the exact same `WKWebsiteDataStore`, then receive `WKDownloadDelegate` destination, progress, redirect, authentication, finish, failure, cancellation, and resume callbacks?

**Overall assessment: PARTIAL.** The companion can use the same store object and can complete ordinary request-backed GET downloads with a verified scratch file. Its redirect delegate can enforce a same-origin boundary, and the independent fixture server observed no request to either denied destination. However, the same store object did not make the WebPage's HttpOnly or Secure cookies appear on the companion's outgoing requests. A captured POST body was not sent, a response-triggered single-use URL was replayed after consumption, a `blob:` URL remained page-bound, and supplied resume data did not produce a destination file. This is not whole-browser session or download parity.

### Reproduce and evidence

Run `make spike-browser-wkdownload`. The manual target starts the fixture server as a separate host process on loopback HTTP `127.0.0.1:18753` and controlled HTTPS `127.0.0.1:18754`, creates a short-lived self-signed fixture certificate, resets fixture state per device, and runs the dedicated `BrowserWKDownloadSpike` scheme serially on iPhone 17 and iPad Pro 11-inch (M5) simulators. The server logs sanitized request metadata, payload lengths and hashes, timestamps, and transfer completion. It never exports cookie, Basic password, request-body, or signed-token values.

The correction run used Xcode 27.0 (build `27A266a`), the iOS Simulator 27.0 SDK, and iOS 27.0 simulator build `24A434`. The host run summary reports exit status 0. Both devices passed all five UI tests. Separate evidence is preserved here:

- Run summary: `.build/spike-3-evidence/20261009T165836Z-30456/run-summary.json`.
- iPhone: `.build/spike-3-evidence/20261009T165836Z-30456/iphone/fixture-evidence.json` and `BrowserWKDownloadSpike.xcresult`.
- iPad: `.build/spike-3-evidence/20261009T165836Z-30456/ipad/fixture-evidence.json` and `BrowserWKDownloadSpike.xcresult`.

The correction run added `testEphemeralTeardownCancelsOnlyRetiringProfileDownloads` and `testLateTerminalOutcomeCannotChangeNewerScenarioStatus`; both passed on iPhone and iPad alongside the existing background/lifecycle, origin-policy, and runtime-matrix tests. The independent host recorded the active Ephemeral transfer as incomplete: iPhone sent 16,711,680 of 33,554,432 bytes by 17:00:24.588 UTC; iPad sent 18,350,080 of 33,554,432 bytes by 17:05:52.618 UTC. The corresponding teardown events then reported reconciliation complete, the retiring context retained through reconciliation, and a new profile/store identity with zero cookies. Neither retiring operation published a completed scratch receipt. In each device run, the unrelated Persistent transfer remained active through teardown and the host later recorded the full 33,554,432-byte response at 17:00:33.071 UTC on iPhone and 17:06:01.113 UTC on iPad.

The late-callback probe also used independent server timestamps. The host recorded an incomplete 8 MiB response at 17:00:46.385 UTC on iPhone (1,835,008 bytes) and 17:06:23.543 UTC on iPad (1,703,936 bytes). Each timeout event recorded a requested cancellation, a reconciled terminal callback, and an observed incomplete server transfer. After a newer ordinary scenario took ownership, replaying the prior terminal outcome was recorded as ignored; its status and owner remained unchanged. Callback evidence retains the scenario run, operation, profile, website-data-store, parent-resume, and destination identities. Terminal reconciliation is recorded only after finish, failure, or cancellation handling; an unreconciled timeout remains incomplete. The retiring context is retained if teardown cannot reconcile within its bounded wait.

Changing the visible profile selection and destroying a profile session are separate operations. The selection control records `underlying_session_destroyed=false` and leaves already-started operations attached to their captured context. Explicit Ephemeral retirement cancels only coordinators owned by that profile, reconciles them before removing its website data and replacing the context, and preserves unrelated-profile operations.

Repository validation: `make build` and `make test` passed separately. `make lint` and the configured Delegation v3 `lint` profile (validation ID `validation-2026-10-09T17-12-02-993Z-631de1bc`) stopped at `git diff --check` on the inherited space-before-tab at Makefile line 93; that non-append-only recipe line was left unchanged. Direct configured SwiftLint (`bash ./Scripts/swift-tools.sh lint`) found zero violations in its 135 configured files, which exclude the Spike 3 directories. A separate direct SwiftLint invocation over the five Spike 3 Swift files found 85 violations, primarily line/file/type/function length, line length, brace spacing, cyclomatic complexity, and trailing-comma rules. `make lint-analyze` passed its compiler-backed four-pass analysis of 134 configured files with zero violations; it also excludes the Spike 3 directories. The dedicated Spike 3 scheme compiled and ran those files on both simulators. Xcode printed LLVM profile-write warnings during analysis, but the analyzer exited successfully and processed all 134 files.

The matrix below describes observed behavior, including cases where the tested capability failed. The fixed JPEG and H.264 MP4 fixtures are checked in under `Prototypes/BrowserWKDownloadSpike/fixtures/`; the server does not need a media encoder at runtime.

### Public SDK audit

The installed SDK headers and Swift interface were inspected under `iPhoneSimulator27.0.sdk`:

- `WKWebView.startDownload(using:completionHandler:)` creates a `WKDownload`; `resumeDownload(fromResumeData:completionHandler:)` creates a new download for nonempty resume data.
- `WKDownload` conforms to `NSProgressReporting`, exposes `progress`, `originalRequest`, and a weak `delegate`, and supports `cancel(_:)` with optional resume data. The coordinator therefore retains the WebView, coordinator, download, and delegate for each operation.
- `WKDownloadDelegate` provides destination, HTTP-redirection, authentication-challenge, finish, and failure callbacks. The destination's parent must already exist and the selected destination must be new. Omitting the redirect callback uses WebKit's default redirect behavior, so the experiment implements an explicit decision.
- `WebPage.Configuration.websiteDataStore`, `WebPage.NavigationAction.request`, and `shouldPerformDownload` are public. A visible selected response can return `.download`, but WebPage does not expose its resulting `WKDownload`, destination callback, or download progress. `WKWebView.startDownload` is a separate request; the runtime comparison below shows that passing the observed request object does not guarantee equivalent request semantics.

Primary references: [WKWebView.startDownload](https://developer.apple.com/documentation/webkit/wkwebview/startdownload(using:completionhandler:)), [WKWebView.resumeDownload](https://developer.apple.com/documentation/webkit/wkwebview/resumedownload(fromresumedata:completionhandler:)), [WKDownload](https://developer.apple.com/documentation/webkit/wkdownload), [WKDownloadDelegate](https://developer.apple.com/documentation/webkit/wkdownloaddelegate), [destination callback](https://developer.apple.com/documentation/webkit/wkdownloaddelegate/download(_:decidedestinationusing:suggestedfilename:)), [redirect decision](https://developer.apple.com/documentation/webkit/wkdownloaddelegate/download(_:decidedpolicyforhttpredirection:newrequest:)), [cancel and resume data](https://developer.apple.com/documentation/webkit/wkdownload/cancel(_:)), [WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore), and [WebPage.NavigationAction](https://developer.apple.com/documentation/webkit/webpage/navigationaction).

### Fixture matrix

| Fixture | Result | Observed behavior |
| --- | --- | --- |
| Ordinary visible navigation | **PASS** | `/normal` remained on the ordinary `.allow` path and reached the independent server. Only a selected experiment control was intercepted. |
| Visible attachment and companion attachment | **PARTIAL** | The visible attachment control returned WebPage `.download`; WebPage exposed no app-owned destination or completion receipt. The explicit companion GET produced a verified 581,632-byte scratch file with SHA-256 `89853b6bec13cf153243ab46a7050cfeb190aa592c91b770b1cba1e6f1af60c1`, matching the visible control's server response. GET, Referer, Origin, User-Agent hash, and Authorization semantics matched; the visible request sent `spike_http_only`, while the companion sent no cookie. The hostile suggested filename was ignored. |
| Direct still image and video | **PASS** | Visible WebPage controls returned `.download`. The companion completed `image/jpeg` (222 bytes, SHA-256 `72400effcd608610b5b3ce17cba806e246219cc57985580be76e1aef3dfe3376`) and `video/mp4` (1,478 bytes, SHA-256 `b366c8ac6b93776ef6d6196fc365e8e41312055bacbf546504c218b7875693f8`) with no `Content-Disposition`. Each downloaded file's size and hash matched its visible-control response. |
| Same-origin redirect chain | **PASS** | Both same-origin redirect callbacks were allowed; the server recorded both redirect hops and the final resource request. |
| Cross-origin redirect and HTTPS downgrade | **PASS (boundary enforced)** | The delegate cancelled both cases. The server recorded the initial redirect responses and **zero** requests to `/prohibited/cross-origin` and `/prohibited/https-downgrade`. The decision event explicitly records that credential safety was not inferred from callback availability; enforcement is supported by the missing destination requests. |
| Persistent-Private HttpOnly cookie | **FAIL (session parity)** | The companion's `WKWebsiteDataStore` was pointer-identical to the originating WebPage store, and `WKHTTPCookieStore` lookup returned the HttpOnly cookie name. The companion request nevertheless had no Cookie header and received 401; the visible control sent the cookie and succeeded. A shared store identity is not proof that WebKit transfers page session state to a newly started download. |
| Separate-store negative control | **PASS (negative control)** | The companion was given a distinct nonpersistent store, cookie lookup did not see the originating cookie, and the server returned 401. |
| Secure cookie over controlled HTTPS | **PARTIAL** | The visible HTTPS control sent the Secure cookie. The exact-store companion lookup saw its name but sent no cookie and received 401. The HTTP negative control also received 401 without the Secure cookie. The loopback certificate was trusted only for the fixture; this does not qualify production certificate handling. |
| Basic authentication | **PASS (challenge path)** | The separate `/basic/resource` fixture challenged both visible WebPage and companion requests; each reached a Basic-authenticated 200 response. Evidence records origin, scheme, and a sanitized username hash prefix only. The harness credentials are synthetic and are not persisted. |
| GET header fidelity | **PARTIAL** | The visible attachment control and companion used GET with no body. Sanitized Referer and User-Agent hash matched; Origin was absent on both top-level requests, and Authorization was absent. Cookie behavior differed as described above. No headers were synthesized to create parity. |
| POST body and side effect | **FAIL (body fidelity)** | `WebPage.NavigationAction.request` exposed a POST body (36 bytes; hash only), and the original `URLRequest` object was passed to `startDownload`. The server observed one POST with a zero-byte body and exactly one contained side effect. Do not support POST acquisition through this bridge. |
| Single-use signed URL | **PARTIAL** | The pre-request token was used once and returned 200. The separate response-triggered token was consumed by the WebPage request (200); the companion's new request reused it and received 403. Token values were not exported. |
| Page-generated `blob:` URL | **FAIL (page-bound resource)** | The originating WebPage reported the blob action as page-bound; no companion HTTP(S) request was started. |
| Progress, destination, cancellation, and resume | **PARTIAL** | Actual `WKDownload.progress` was observed. Destinations were unique operation-named files in pre-existing temporary scratch directories; suggested names were ignored. Cancellation produced nonempty resume data (7,931 bytes on iPhone; 7,901 bytes on iPad), and resume created a new operation ID and delegate. The resumed request had no Range header; the server sent the full 8 MiB and progress reached 1.0, but `downloadDidFinish` had no destination file. The coordinator recorded failure and published no completed receipt. HTTP error responses also produced failure records independently from cancellation and resume-data records. |
| Profile selection and active Ephemeral teardown | **PASS (teardown isolation); FAIL (automatic cookie parity)** | Changing visible selection records `underlying_session_destroyed=false`; a running operation remains bound to its captured profile and store. Explicit retirement cancels and reconciles the active Ephemeral transfer before removing its store, retains the old context through reconciliation, publishes no completed stale receipt, and creates a replacement with a different profile/store identity and zero cookies. On both devices, an unrelated Persistent transfer completed with the expected full body after Ephemeral teardown. The exact-store Ephemeral companion still sent no cookie and received 401. |
| Timeout and stale terminal callback | **PASS (scenario ownership)** | The host fixture recorded actual progress followed by incomplete server bodies, and cancellation terminal handling was reconciled before timeout status was finalized. After a newer scenario became current, the test replayed the old terminal outcome; the event was ignored and did not change the newer scenario's status or owner. The evidence records identities and server timestamps independently of UI status. |
| Background and process lifecycle | **PARTIAL** | The host process recorded the transfer finishing while scene phase was background, before returning active. The host-process fixture also observed an incomplete transfer after harness-initiated termination; an explicit relaunch had a new process ID. This does not prove process suspension behavior or background completion after suspension. Genuine system relaunch, user force-quit, and physical-device behavior are **UNVERIFIED**. |

### Comparison with Spike 2 and recommendations for #42/#43

Spike 2's background `URLSession` bridge could replay browser cookies for its supported subset, but the fixture proved that a manually attached Cookie header survived a cross-origin redirect. Spike 3 provides a safer redirect boundary: its `WKDownloadDelegate` denied cross-origin and HTTPS-downgrade redirects, and the independent server observed no request to either prohibited destination. It also exposes WebKit's download progress, destination, authentication, finish, failure, and cancellation lifecycle for successful GETs. That makes it more capable for native download callbacks, while the missing automatic cookies, POST-body loss, response-triggered signed-token replay, page-bound `blob:` data, and failed resume make it less capable for session fidelity and reliable continuation. It is safer at the tested redirect boundary, but is not a generally more capable acquisition transport than Spike 2. Neither bridge provides whole-browser parity.

- **#42, ordinary browser downloads:** WebPage can return `.download` for an explicit attachment control but does not expose the file lifecycle needed for an app-owned receipt. Keep the existing WKWebView path for native/session-bound browser downloads until an equivalent supported path is proven. A companion bridge may cover only the measured, explicit GET subset; do not describe it as a general WebPage download manager.
- **#43, Save to Vault:** limit any future bridge candidate to a user-selected, idempotent HTTP(S) GET whose resource does not depend on page cookies or page-local state. Enforce same-origin redirects and reject HTTPS downgrades. Do not use it for POST, response-triggered single-use URLs, `blob:`, or reliable resume. Do not replay Cookie or Authorization headers. A verified scratch file still needs to pass the production ingestion acceptance boundary; this spike wrote nothing to MediaLibrary or the ingestion journal.
- **WebPage migration:** visible browsing can migrate independently, but the companion is not a session-preserving substitute. Retain the current WKWebView path for page-bound cookie and blob behavior unless a separate experiment establishes an equivalent public API path. No production BrowserFeature migration is included here.

This is a compatibility bridge for a narrow request-backed subset, not proof that WebPage itself has native download-file support or that a same-store companion shares all browser session semantics.

## Spike 4 — Explicit Save to Vault from a link/direct media URL

### Question

Can #43 be implemented as an app-owned acquisition action independently from generic browser downloads?

### Environment and method

The disposable host and fixtures ran on the iPhone 17 and iPad Pro 11-inch (M5) simulators using iOS 27.0 (runtime build 24A434) and Xcode 27.0 (27A266a). The visible browser used public `WebPage`; an app-owned `WKWebView` created each acquisition `WKDownload` with the exact selected website data store. Only explicit fixture Save links and app controls initiated acquisition. The fixture server captured requests independently from sanitized app events. A short-lived fixture CA was installed in each simulator so the HTTPS-to-HTTP redirect could reach the delegate boundary.

The fixture-generated `vault-save:` link actions exercised explicit-save routing with synthetic page links. They did not establish native SwiftUI WebView context-menu integration or a user long-press path. Spike 5 must verify that integration through a genuine long press and the selected element exposed by the supported WebKit API.

Run the experiment from the repository with `make spike-browser-save-to-vault`. It runs the UI matrix and a focused ingestion test serially on each simulator. The ingestion test receives the JPEG receipt copied from that simulator's host container. The disposable worktree started at `origin/main`; only the Spike 3 fixture server, two media fixtures, and the existing research document were copied from the dirty primary checkout.

### Fixture results

| Fixture | iPhone 17 | iPad Pro 11-inch (M5) | Evidence and boundary |
| --- | --- | --- | --- |
| Explicit link to still image | **PASS** | **PASS** | Receipt contained the exact 222 fixture bytes, SHA-256 `72400effcd608610b5b3ce17cba806e246219cc57985580be76e1aef3dfe3376`. |
| Repeated save to the same receipt identity | **PASS** | **PASS** | The second transfer was rejected as a duplicate; the first accepted receipt remained available for journal reconciliation. |
| Action-time single-use signed still URL | **PASS** | **PASS** | One explicit action produced one `/signed/pre-request` request, status 200 and `first-use`; the response-triggered signed endpoint received zero requests. The consumed token is not counted as a second request or a direct-page success. |
| Explicit link to MP4 | **PASS** | **PASS** | Receipt-only result: 1,478 unchanged bytes, SHA-256 `b366c8ac6b93776ef6d6196fc365e8e41312055bacbf546504c218b7875693f8`. No canonical video asset was created. |
| Direct still-image page | **PASS** | **PASS** | After normal page navigation displayed the image, the separate Save action acquired a byte-identical still receipt. |
| Direct video page | **PARTIAL** | **PASS** | The iPhone's Save control was not hittable while `WebPage` presented the MP4 page. On iPad, the action produced the same 1,478-byte receipt as the fixture. This is not consistent direct-page video support across the requested devices. |
| Same-origin redirect chain | **PASS** | **PASS** | The delegate allowed both same-origin hops and the fixture observed the final request. The final `application/octet-stream` body was rejected before receipt publication. |
| Cross-origin redirect | **PASS** | **PASS** | `http://localhost:18753` redirected to `http://127.0.0.1:18753`; the delegate denied it and the independent fixture observed zero requests to `/prohibited/cross-origin`. |
| HTTPS downgrade | **PASS** | **PASS** | The trusted loopback TLS fixture redirected from HTTPS to HTTP; the delegate denied it and the independent fixture observed zero requests to `/prohibited/https-downgrade`. |
| Logged-in HttpOnly cookie | **PARTIAL** | **PARTIAL** | Ordinary `WebPage` navigation sent the HttpOnly cookie and received 200. The companion used the same store identity but sent no cookie and received 401. No cookie or authorization value was copied into acquisition requests. |
| Ephemeral-profile negative control | **PASS** | **PASS** | The isolated profile had no authenticated cookie; the acquisition request had an empty cookie list and received 401. |
| Unsupported MIME, invalid claimed image, and 404 | **PASS** | **PASS** | A completed octet-stream transfer, invalid bytes labelled `image/jpeg`, and a missing-resource response each produced no receipt. The MIME type was treated as a hint; image bytes were decoded before acceptance. |
| Cancellation | **PASS** | **PASS** | The slow response was cancelled before all 8 MiB arrived: the fixture sent 3,866,624 of 8,388,608 bytes on iPhone and 3,932,160 of 8,388,608 on iPad. No receipt was published. |
| POST, `blob:`, and `data:` | **PASS** | **PASS** | Each was rejected before an app-owned request; the server's POST side-effect count remained zero. |
| Ordinary navigation | **PASS** | **PASS** | The normal page loaded through the visible browser without a Save action or receipt acceptance. |

The direct-link and signed still receipts, linked MP4 receipt, and iPad direct-video receipt were app-owned receipts only. Each receipt lived under a separate receipt-staging directory; WebKit's transfer scratch and the MediaLibrary canonical staging directory were separate locations. No receipt was acknowledged as committed by the host.

### Direct-video Save control investigation

On iPhone 17, the direct MP4 URL loaded in `WebPage`, but the visible `save-current-page` button reported `isHittable == false`. The captured accessibility frame was `(11.33, 105.33, 138.67, 20.33)` inside the `(0, 0, 402, 874)` app window; the WebPage occupied `(6, 183.3, 390, 650)`. The accessibility snapshot contained three windows and a separate `Window (Main)` with a `Media` element at `(0, 236, 402, 402)`. The button was on-screen in the host window, so ordinary SwiftUI clipping does not explain the failed hit test. The separate media window indicates that WebKit's native direct-video presentation made the underlying host control unavailable.

The first UI-test trace also exposed an automation defect: it called `.tap()` after recording `isHittable == false`; XCTest scrolled the element and reported the computed hit point as `{-1, -1}`. That was not a valid Save interaction. The test now calls `.tap()` only when the control is hittable and retains the hit-test, accessibility, and screenshot evidence. The final iPhone and iPad UI runs each passed. The iPhone produced no `direct-page-video` receipt; page-display GETs are not counted as an explicit Save. The iPad control was hittable and the UI-level XCUITest tap produced the 1,478-byte receipt. This remains an iOS 27 simulator finding; no physical-device behavior is claimed. The sanitized runtime evidence is in the task review bundle under `evidence/direct-video-iphone-*`.

### Terminal-event profile attribution follow-up

A focused XCUITest on iPhone 17 (iOS 27.0, build 24A434) started a slow transfer in the Persistent profile, selected Ephemeral while that transfer was active, then inspected the fixture's terminal event. The test passed and confirmed that the terminal event retained the originating profile and profile ID and the same operation ID as `transfer-started`. The change affects event attribution only; terminal status, operation identity, and cleanup behavior remain unchanged.

### SQLite journal handoff and Data Protection

The focused `BrowserReceiptIngestionTests.reconcilesTransferredReceipt` test used the actual still receipt bytes from the simulator app container. In the authorized test target it staged those bytes with a `.completeUnlessOpen` request, copied them unchanged into the existing `FileMediaResourceRepository` staging path with a `.complete` request, inserted a `.received` entry into the real `SQLiteMediaLibraryStore` journal via test-only `@testable` access, and called the real `MediaLibraryImporter.loadAssets()` reconciliation path. It asserted that the asset was hidden before reconciliation, then became one still-image asset with the fixture byte count and SHA-256. The durable temporary SQLite database was closed and reopened; the asset remained loadable and the journal was empty. Recorded transitions were `received` → `validating` → `duplicateCheck` → `ready` → `committing` → `complete`.

On both simulators, `FileManager.attributesOfItem` returned `nil` for the receipt file after requesting `.completeUnlessOpen` and for canonical staging after requesting `.complete`. The host likewise reported receipt protection as unreported. The experiment therefore proves that the protection requests were made, but does not establish the effective Data Protection class. No physical device was tested.

This proves that transferred still bytes can be reconciled by the existing SQLite journal in an isolated, persistent test store. It does **not** establish a production browser-receipt acceptance API. The bridge had to copy bytes into canonical staging and seed the internal journal from test code. `MediaLibraryClient.importFile(URL)` was not used. Production `MediaLibraryClient` remains Files-oriented; a browser handoff cannot currently submit a protected receipt through an app-accessible MediaLibrary boundary.

The repository-owned `make lint`, `make build`, and `make test` gates passed in the disposable worktree; the focused browser receipt journal test also passed on both simulators. A follow-up ran the three failing `MediaLibrarySnapshotTests` cases on the unchanged base commit `50497c1` and on Spike 4 with Xcode 27.0 (27A266a), iPad Pro 11-inch (M5), and iOS 27.0 (24A434), using the same simulator and exact same test filter. All three failed in both worktrees with identical captured/reference dimensions: compact-phone empty Library `320×568` vs `480×852`; regular-width iPad committed still `834×1194` vs `1251×1791`; compact-phone unsupported-import error `320×568` vs `480×852`. The snapshot test source was byte-identical. These failures are pre-existing and were not introduced by Spike 4. The full package suite is still not claimed as passing on iPad.

### Security and lifecycle limits

- The tested `WKDownloadDelegate` redirect callback denied cross-origin and HTTPS-downgrade destinations before either prohibited fixture received a request. Same-origin redirects were allowed. This is fixture-backed evidence for the exercised public WebKit path, not a blanket guarantee for every server, proxy, DNS, or authentication configuration.
- The companion did not inherit the browser's HttpOnly cookie even when both used the exact same `WKWebsiteDataStore`. Authenticated media is unsupported by this experiment; manually copying credentials is not a safe substitute.
- Only explicit, idempotent HTTP(S) GET requests were eligible. HTTP was permitted only for loopback fixtures. POST, `blob:`, and `data:` were rejected. Suggested filenames were ignored and bytes were checked against supported image/MP4 signatures.
- Video acceptance stopped at byte-identical receipt staging. Existing MediaLibrary reconciliation supports still images; canonical video import was not tested or claimed.
- Physical-device protection attributes, background continuation, lock/suspend behavior, system termination, force-quit, relaunch recovery, and interruption across process death remain unverified and belong in Spike 6.

### Issue #43 architectural verdict

**PARTIAL: the experiment validates a narrow explicit-GET acquisition mechanism, but does not justify production BrowserFeature migration or resolve #43.** Anonymous explicit still links and selected direct still pages worked on both simulators; linked MP4 worked as receipt-only bytes; redirect interception was proven against independent zero-request fixture assertions. Authenticated requests, direct video selection on iPhone, effective file protection, and the production receipt-acceptance seam remain blockers or limitations. Keep this outside production until MediaLibrary offers an intentional receipt acceptance boundary that reuses the single journal and validates the required file protection on device. Do not interpret test-only journal access as product API parity.

### Spike 5 and Spike 6 handoff

Spike 5 must first verify that a genuine user long-press in the native SwiftUI WebView presents the context menu and exposes the selected element through supported public API. Spike 4's fixture-generated `vault-save:` link actions do not prove this integration. It should then determine whether `ActivatedElementInfo` exposes an unlinked image or video resource without broad DOM enumeration. Keep the user gesture as the sole discovery trigger.

Spike 6 should validate `.completeUnlessOpen` receipt staging and `.complete` canonical resources on physical devices, then exercise lock, suspension, cancellation, process termination, relaunch, and journal recovery. It must verify whether an accepted receipt survives each interruption and ensure no partial asset becomes visible.

## Spike 5 — Long-press Save to Vault on inline media

### Question

Spike 4's fixture-generated `vault-save:` link actions did not exercise this native context-menu path. Treat native SwiftUI WebView menu presentation and selected-element delivery from a genuine long press as a required Spike 5 verification.

Can SwiftUI WebView identify the actual inline image/video resource that the user long-pressed without page scraping?

### Important API constraint

The installed iOS 27.0 SDK exposes `WebView.ActivatedElementInfo.linkURL`, but marks SwiftUI's `.webViewContextMenu(menu:)` modifier **unavailable on iOS**. A compiler probe against the iOS 27 simulator SDK fails with that exact diagnostic. The app therefore has no supported SwiftUI callback that can receive even a linked element from an iOS long press. Native menu presentation must be recorded separately from callback availability; it cannot be interpreted as a callback returning an empty URL.

This is relevant because #43 explicitly says "media/links", not only links.

### Experiment A — public context-menu data only

Fixtures:

1. `<a href="image.jpg"><img ...></a>`;
2. unlinked `<img src="image.jpg">`;
3. `<picture><source ...><img ...></picture>`;
4. `<video src="video.mp4">`;
5. video with nested `<source>`;
6. CSS background image;
7. canvas-rendered image;
8. same-origin and cross-origin iframe media where the long press can reach the inner frame.

Record native menu presentation and labels after an actual XCUITest long press, separately from public callback availability. On iOS 27, `ActivatedElementInfo` cannot be delivered through `.webViewContextMenu`; there is no `linkURL` callback result to record for any element.

### Experiment B — narrow user-gesture script bridge

Because Experiment A confirms the callback limitation, test a narrowly scoped `WKUserContentController` script installed at document start that listens only for the user's `contextmenu` gesture and reports only the activated element's immediate resource metadata:

- tag name;
- `currentSrc` / `src` for IMG/VIDEO/AUDIO/SOURCE where applicable;
- `href` for anchors;
- page-reported frame URL/origin for comparison with WebKit-owned frame metadata; relative candidates use the WebKit frame request URL as their base.

Do **not** enumerate page media, walk the document for candidates, inspect encrypted streams, inspect canvas pixels, or scrape background resources.

The WebPage configuration publicly exposes a `WKUserContentController`, so this can be tested without private WebKit API. Gate interpretation on whether a genuine press actually delivers `contextmenu`. If it does not, use diagnostic-only `pointerdown` and `touchstart` observations to establish whether the gesture reaches the page, without treating those events as selected-resource evidence. Keep the activated media resource separate from an enclosing link by inspecting at most eight entries of the current event's composed path. Record WebKit-owned message world and frame metadata separately from page-provided fields; reject malformed, synthetic, and stale messages. No script URL is transfer authorization.

The disposable fixtures additionally cover responsive `<picture>` selection, a relative `src`, delayed source replacement, `blob:` and `data:` URLs, malformed payloads, forged page-world calls, and navigation-stale payloads. No script enumerates document media, scans unrelated ancestors, reads CSS image URLs or canvas pixels, or inspects encrypted streams or credentials.

### Product gate

Technical event delivery and product approval are separate gates. Even if a future iOS version delivers a genuine `contextmenu` event, approving a gesture-scoped script bridge under the existing "no scraping / no broad DOM instrumentation" invariant requires an explicit architecture decision. A message containing `event.isTrusted` and a plausible URL does not authorize acquisition. No production bridge or Save action is implemented by this spike.

### Disposable implementation and measurement rules

The isolated `BrowserInlineMediaSpike` scheme hosts SwiftUI `WebView(WebPage)` on iOS/iPadOS 27. A loopback Python fixture serves one centered activation target per page and separately records fixture requests, bounded app messages, and XCUITest press results. The host's native mode installs no user script. Bridge mode installs a public `WKUserScript` in `WKContentWorld.defaultClient` at document start in all frames. Only `contextmenu` may carry immediate selected-element metadata. Diagnostic mode adds `pointerdown` and `touchstart` records without source metadata. Both modes use the same real `XCUICoordinate.press(forDuration: 1.1)` action; the test attaches a screenshot after each press.

The bridge examines only the activated event's first eight composed-path entries, selecting an IMG/VIDEO/AUDIO/SOURCE if present and recording an enclosing A destination separately. It reports `currentSrc`, `src`, and `href` as candidates, redacts `blob:`/`data:` payloads, and never traverses the page for media. A pure Swift decoder checks the active fixture, WebKit content world and frame request, event trust flag, field types and bounds, and URL scheme. Page-supplied frame URL/origin remain separate from WebKit's `WKScriptMessage.world`, `frameInfo.isMainFrame`, `securityOrigin`, and `frameInfo.request.url`. Neither an accepted message nor `event.isTrusted` authorizes a transfer.

The dedicated runner is `bash Prototypes/BrowserInlineMediaSpike/run-spike.sh`. It runs the repository's configured SwiftFormat and strict SwiftLint directly over all Spike 5 Swift files, focused Swift and Python tests, the intentional iOS SDK compile-failure probe, serial UI tests on iPhone 17 and iPad Pro 11-inch (M5), and `git diff --check`. It writes timestamped JSON, Markdown matrices, logs, screenshots in `.xcresult`, and exit codes under ignored `.build/browser-inline-media-spike5/`. The tracked `Prototypes/BrowserInlineMediaSpike/evidence/` directory contains the sanitized review summary and per-device matrix after validation.

### Findings from genuine simulator presses

The full run used Xcode 27.0 (27A266a) and iOS/iPadOS simulator runtime 27.0 (24A434). The iPhone 17 and iPad Pro 11-inch (M5) each passed seven UI tests using actual `XCUICoordinate.press(forDuration: 1.1)` calls. A focused repeat passed three more UI tests per device to check diagnostic delivery on CSS, canvas, `blob:`, and `data:` targets and repeat the cross-origin iframe press. Both focused device test commands returned success. The focused shell runner had a post-test parse error after a concurrent edit to the runner; its exported evidence is complete, the corrected script passes `bash -n`, and `git diff --check` passed separately. The retained [iPhone matrix](../../Prototypes/BrowserInlineMediaSpike/evidence/iphone-matrix.md), [iPad matrix](../../Prototypes/BrowserInlineMediaSpike/evidence/ipad-matrix.md), [focused iPhone matrix](../../Prototypes/BrowserInlineMediaSpike/evidence/iphone-focused-matrix.md), [focused iPad matrix](../../Prototypes/BrowserInlineMediaSpike/evidence/ipad-focused-matrix.md), sanitized JSON, and screenshot bundle distinguish fixture loads, menu accessibility, script event delivery, and WebKit frame metadata. The fixture media GET column only shows what WebKit loaded; it does not identify what the user selected.

| Activated target | iPhone native mode | iPad native mode | Gesture-scoped bridge mode, both devices |
| --- | --- | --- | --- |
| Image inside an anchor | Native menu with link actions and Save to Photos | Same | Native menu, zero genuine `contextmenu` messages |
| Unlinked image; responsive `<picture>` | Native image menu | Native image menu | Native menu, zero genuine `contextmenu` messages |
| `<video src>`; video with nested `<source>` | No detected menu; inline play control visible | Same | No detected menu and zero `contextmenu`; diagnostic pointer/touch reached `VIDEO` |
| CSS background; canvas | No detected menu | No detected menu | No detected menu and zero `contextmenu`; diagnostic pointer/touch reached the CSS target or `CANVAS` |
| Same-origin iframe image | Native image menu | Native image menu | Native menu, zero `contextmenu`; inner-frame pointer/touch delivered |
| Cross-origin iframe image | No menu detected in one native-mode press; a menu appeared in bridge and diagnostic modes and both native repeat presses | Native image menu, including both native repeat presses | Native menu, zero `contextmenu`; inner-frame pointer/touch delivered with distinct origin |
| Responsive, relative, changed-source, `blob:`, and `data:` images | No separate native-only case | No separate native-only case | Native image menus, zero genuine `contextmenu` messages; diagnostic pointer/touch reached both opaque URL image targets |

The linked image fixture uses `/media/image-a.jpg` as its media resource and `/destination/link` as its enclosing link destination. The native menu previews the separate link destination and offers Save to Photos, but the unavailable SwiftUI callback supplies neither URL to the app. The parser's linked-resource and relative-URL tests prove only how a well-formed hypothetical bridge message would be decoded; they are not runtime selection evidence. Responsive fixtures loaded `/media/image-a.jpg` on iPhone and `/media/image-wide.jpg` on iPad, and the dynamic fixture fetched both `/media/image-a.jpg` and `/media/image-b.jpg`. These request observations do not replace a user-selection callback. Valid in-page JPEG bytes were used for both `blob:` and `data:` fixtures, and their screenshots show image menus rather than text-selection fallbacks.

The diagnostic listener received pointer and touch messages from the unlinked image, both iframe interiors, both video forms, CSS target, canvas, and both opaque URL image targets. The WebKit-owned `WKScriptMessage` records identify the default client content world, main/subframe status, security origin, and frame request URL. They distinguish `127.0.0.1` from `localhost` in the cross-origin iframe. None contained selected-media metadata, by design. The genuine image and iframe presses produced native menus but no JavaScript `contextmenu` event, so the bridge's event-delivery gate failed before resource identification could be evaluated. CSS and canvas presses also delivered diagnostic events without a menu or `contextmenu`; this distinguishes event delivery from native menu support. A page-dispatched synthetic `contextmenu` reached the isolated handler and was rejected with `synthetic-event`; the page world could not call that handler directly. Unit tests reject malformed, wrong-world, and navigation-stale messages. A UI test proved navigation retires the active case, but an actual late WebKit callback after navigation was not observed or fabricated.

#### Architectural verdicts

1. **Native context-menu behavior:** iOS/iPadOS 27 WebView displayed native image menus for most image fixtures; video showed native play controls without a detected menu, and CSS/canvas showed no menu. One iPhone cross-origin iframe native press did not show a menu although other presses on that fixture did. Menu visibility is therefore an observation, not proof of a stable app hook.
2. **User-selected resource identification:** **Unsupported through the tested public SwiftUI route.** The installed iOS 27 SDK marks `.webViewContextMenu(menu:)` unavailable on iOS, so no activated-element callback exists to return either a URL or a nil URL. The narrow bridge received no genuine `contextmenu` selection message on either simulator. Network requests and an enclosing link are not selected-media evidence.
3. **Narrow bridge reliability and trust:** Its parser can bound a current activation path and keep media and link candidates separate, but the event-delivery gate failed on both devices. The parser and isolated content world reject the tested synthetic, malformed, wrong-world, and stale cases; page-controlled metadata remains untrusted even when `event.isTrusted` is true. Product acceptability of this bridge remains a separate explicit decision and is not established by this experiment.
4. **Usable Save-to-Vault affordance:** **Not available through the tested native SwiftUI WebView menu integration on iOS 27.** The visible Save to Photos item belongs to the system. The public SwiftUI modifier needed to add a selected-element Save action cannot compile for iOS, and the tested bridge supplies no genuine selected resource. Other app-owned UI approaches and physical-device behavior were not tested.

**Spike 5 verdict: capability unsupported under the tested public SwiftUI WebView routes on iOS/iPadOS 27 simulators.** Do not begin production inline-media Save-to-Vault implementation from these results. Spike 4 remains **PARTIAL**: this experiment does not repair its authenticated acquisition, direct iPhone video selection, receipt acceptance, Data Protection, or lifecycle limitations.

### Spike 6 handoff

Spike 6 should test receipt staging and lock/relaunch recovery on physical devices, including `.completeUnlessOpen` staging and `.complete` canonical resources. It must keep received bytes recoverable until the journal can reconcile them, and ensure no partial asset becomes visible. This handoff does not implement Spike 6 or grant a browser long-press acquisition path.

## Spike 6 — Receipt staging and lock/relaunch lifecycle

### Question

Can either transfer transport land completed bytes into the future ingestion boundary without violating Data Protection or durable-recovery semantics?

### Required behavior

1. Allocate an opaque acquisition/ingestion identity before starting transfer.
2. Carry only opaque identity in background task metadata.
3. Transfer to a system temporary URL or a WebKit-writable temporary destination.
4. Before acknowledging receipt, move/copy the completed resource to app-controlled receipt staging protected appropriately for background completion.
5. Once protected bytes are under app control, reconcile into journal state `received`.
6. If the vault store cannot be opened because the app is locked/freshly relaunched, leave the receipt recoverable and defer DB reconciliation until authenticated access.
7. Never expose partially received bytes as a MediaAsset.
8. No permanent browser Downloads directory or browser-specific durable history.

### Pass condition

Suspend/terminate between every boundary and prove that the system reaches one of two states only:

- no accepted receipt exists and temporary data may be discarded; or
- protected receipt bytes exist with enough opaque metadata to reconcile idempotently later.

There must be no state where the UI reports accepted media but the only bytes still belong to WebKit/URLSession temporary storage.

### Spike 6 experiment — 2026-10-11

**Verdict: PARTIAL.** A dedicated iOS/iPadOS 27 host, independent fixture, and test-only journal handoff demonstrate a narrow explicit unauthenticated GET path. A later physical iPhone test demonstrated receipt creation and acceptance during an operator-confirmed lock interval, with the receipt file and directory reporting `.completeUnlessOpen`. It did not establish closed-file reopening while locked, physical canonical-file protection, genuine system relaunch, a production authentication boundary, or a production receipt API. Spike 4 remains **PARTIAL**; Spike 5 still has no demonstrated genuine selected-resource callback for inline media. This experiment does not change either verdict.

The host allocates three UUIDs before starting a credential-free `URLSession` background GET. Its task description contains only those UUIDs; Foundation may retain the request URL in system-owned task state. The delegate copies the completed temporary file **before returning** from `didFinishDownloadingTo`. The receipt provisional file is created exclusively with one writable descriptor, backup exclusion is requested, and `.completeUnlessOpen` is set and checked **before private bytes are written**. That same descriptor stays open through streaming, hashing, and file synchronization; the receipt is renamed and its directory synchronized. This avoids the earlier create-close-reopen path, which could not work for a file created while locked under [Apple's documented protection behavior](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeunlessopen). A separate `.completeUntilFirstUserAuthentication` metadata file contains only UUIDs, byte count, and SHA-256. **Acceptance is reported after the metadata rename and metadata-directory synchronization.** A crash after rename but before the callback returns can leave recoverable published metadata even if the callback did not report acceptance. Process-interruption tests do not prove survival of sudden power loss.

| Case | Result | Evidence and limit |
| --- | --- | --- |
| Explicit still-image GET and receipt publication | **PASS on simulators** | The final iPhone and iPad matrices each completed five UI tests. App events recorded opaque transfer IDs, received length, SHA-256, and publication; independent fixture records matched exact IDs, lengths, and digests with no Cookie or Authorization header. |
| Provisional copy, file sync/rename, metadata sync/publication, truncation, orphan cleanup | **PASS for injected process interruptions** | The standalone receipt-store suite passed six checkpoint cases plus temporary-file loss before and after preservation, exclusive descriptor lifetime/duplicate creation, ordinary failure cleanup, truncation rejection, malformed metadata quarantine, repeated scans, and byte-tamper detection. Unpublished orphaned bytes were not counted as accepted. No actual process kill at every checkpoint or sudden power-loss experiment was performed. |
| File protection request and inheritance | **PARTIAL; physical receipt observed** | The byte directory requests `.completeUnlessOpen`; the exclusively created receipt sets and checks that class on its still-open descriptor before any private write. A missing attribute on physical hardware aborts publication before private bytes; simulator nil is recorded as unverified. Metadata requests `.completeUntilFirstUserAuthentication`. The host also creates an empty child without explicit attributes to probe directory inheritance, removes it, and records directory and individual-file attributes. The physical iPhone run reported `.completeUnlessOpen` for the inheritance probe, receipt directory, and receipt file during an operator-confirmed lock interval. Canonical resources retain the production repository's `.complete` request, but that class was not measured on physical hardware. |
| Disposable backup exclusion | **PASS for resource-value checks** | The receipt-staging subtree, individual provisional/published receipt and metadata files, and acquisition event log request `isExcludedFromBackup`. Publication checks the value after each rename; focused tests check the directory and final files. Apple describes this as a [backup-exclusion resource value](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup), which file operations can reset. It is a system backup-policy request, not an absolute guarantee, and does not change canonical backup behavior. |
| Locked fresh-process handling | **PARTIAL** | The host has no MediaLibrary/SQLite dependency and scans opaque metadata before the synthetic “test unlock” button. Byte reopen is deferred until that button. The button is neither vault authentication nor a device unlock. The physical run accepted a receipt while locked and verified its bytes after unlock; it did not launch a fresh process or attempt a closed-file reopen while still locked. |
| Harness termination and explicit relaunch | **PASS on simulators** | A slow background task was recovered after XCTest `terminate()` followed by explicit `launch()` on both devices; a new host process observed the receipt. This is not a genuine system-initiated relaunch. |
| Home-background completion | **PASS for simulator backgrounding** | On each simulator, a slow GET started, the app entered the Home background scene phase, and a correlated fixture request completed before a receipt-accepted event. The UI reactivated the same app and observed the receipt. This does not demonstrate actual suspension, system relaunch, or physical-device behavior. |
| Cancellation and bounded timeout | **PASS for tested simulator policies** | Cancellation produced no accepted partial receipt. A separate fixture withheld its response; the app's five-second test timeout cancelled the task, and the independent server recorded zero bytes sent for the same transfer ID with no receipt acceptance. This is an app-enforced timeout, not a measured URLSession resource timeout. |
| Force-quit and system relaunch | **UNVERIFIED** | Deliberate force-quit, real OS suspension, and system-initiated background relaunch were not demonstrated. Harness `terminate()`/`launch()` remains separate evidence. |
| Authenticated journal handoff and canonical commit | **PASS only at the test seam** | Per-device package tests matched the exported host manifest and bytes to the independent server, inserted `.received` into the existing SQLite journal, reopened a fresh connection, and used the existing importer to commit once and load repeatedly without duplicate assets. Five additional deterministic package cases stopped before/after `.received`, after validation, after canonical commit, and after receipt cleanup; fresh stores recovered one exact asset without duplication. The runner transfers a copy of the receipt into the package-test process; it does not import the same physical protected file. |
| Receipt cleanup after durable production commit | **UNVERIFIED in production** | A test-only copied receipt and its metadata were removed after canonical commit, followed by fresh-store idempotence checks. The original host receipt is retained, because no production handoff or durable cleanup rule exists. |
| Physical device Data Protection | **PARTIAL; remaining class/lifecycle claims UNVERIFIED** | After signing was configured, a disposable host and fixed private-interface fixture ran on an iPhone 17 Pro Max. An unlocked control passed separately. For the locked run, the operator confirmed the phone stayed locked from the backgrounding signal until after the fixture completed. Physical app events report background receipt acceptance with `.completeUnlessOpen` on the receipt file/directory and inheritance probe. The physical receipt, manifest, and independent fixture match transfer identity, 8,388,690 bytes, and SHA-256; post-unlock verification passed. Closed-file reopen while locked, physical canonical `.complete`, and a genuine OS relaunch remain unverified. |
| Diagnostic privacy | **PASS for exported app and fixture events** | The runner validates exact event/fixture field names, types, and permitted values; it rejects requests with Cookie or Authorization and secret-bearing strings, including those starting with `f`. It exports fixed fixture paths, UUIDs, counts, digests, and protection reports, without media bytes. Raw `.xcresult` bundles remain local test artifacts and are not treated as sanitized exports. |

The reproducible command is `make spike-browser-receipt-lifecycle`; it creates ignored `.build/spike6-run-*` result directories with separate UI and journal `.xcresult` bundles and sanitized event summaries. The initial complete two-device run was `.build/spike6-run-20261012T043746Z`: five UI tests and two package tests (one with five dynamic interruption cases) passed per device. Later corrected runs are recorded below. Earlier `.build/spike6-run-20261011T083044Z` passed all iPad UI assertions but timed out during Xcode diagnostics before its package test; it remains a distinct incomplete run. The runner preserves a distinct timeout failure and never counts passing assertions as a completed command when diagnostics stall. A missing physical device is reported as unverified, not as a test pass. Code and runner details are in `Prototypes/BrowserReceiptLifecycleSpike/README.md`.

Repository `make lint`, `make build`, and `make test` subsequently passed. The compiler-backed lint gate initially identified a missing direct `GRDB` import in the new package test; after adding it, all four analyzer passes reported zero violations. The gate's LLVM profile-write warnings did not change its passing exit status.

After adding the five journal boundary cases and the simulator lifecycle cases, repository `make lint`, `make build`, and `make test` passed again. The full two-device Spike 6 runner completed with zero failed or skipped simulator tests. These gates do not convert simulator backgrounding into demonstrated OS suspension or establish hardware Data Protection.

The #17 production seam still needs an authenticated, idempotent receipt-to-journal API and a durable cleanup rule. #43 still needs a supported user-selected resource and safe browser-session transfer semantics. This experiment does not establish #42 ordinary WebKit download parity or justify a WebPage migration.

The Spike 6 independent-review corrections replaced a create-close-reopen receipt path with an exclusive descriptor held through protected streaming, added duplicate/descriptor/failure-cleanup tests, replaced a permissive diagnostic pattern with closed event and fixture schemas, and requested backup exclusion for disposable staging and acquisition evidence. The first review-correction simulator rerun encountered a transient UI observation failure in the five-second timeout case and then a separate Xcode diagnostics timeout. The test now relies on a durable timeout result plus independent, same-transfer fixture and start-event correlation rather than requiring XCTest to see a short-lived “downloading” label. That intermediate run is retained as a failed attempt and does not count as final evidence. Two subsequent clean two-device runs passed at `.build/spike6-run-20261012T055108Z` and `.build/spike6-run-20261012T060026Z`; each device completed five UI tests and two package tests with five dynamic interruption cases. The later final-source rerun at `.build/spike6-run-20261012T060723Z` completed the iPhone matrix and all five iPad UI assertions, but Xcode timed out during iPad post-test diagnostics before the iPad package command. A further fresh iPad build timed out before XCTest started. These are distinct Xcode command outcomes, not XCTest assertion failures. The completed two-device runs remain the strongest complete simulator evidence. All runs remain simulator-only and do not establish effective locked-device protection or system-initiated relaunch.

A compatible iPhone 17 Pro Max was connected for a physical attempt. The Mac served the fixed, credential-free fixture on a private IPv4 interface, but the initial Xcode builds could not install the disposable host or UI-test runner because a development account and provisioning profiles were unavailable. Those early attempts measured no device receipt or lock behavior. The fixture route set and credential policy were unchanged; the private address, signing identifier, and raw Xcode diagnostics are omitted from the sanitized review bundle.

An October 12 USB retry confirmed that Xcode recognized the same iPhone as a connected physical destination. Automatic provisioning initially failed again. After account setup and a manual Build For Testing, the disposable targets built for the phone. A temporary ignored Info.plist configured an HTTP exception for the one private fixture address, without adding routes or credential behavior. An unlocked-device control passed, but it was not counted as lock evidence. In a separate test, the operator confirmed the phone remained locked from the test's backgrounding signal until after the independent fixture recorded a complete 8,388,690-byte response. The phone's app event log recorded receipt acceptance before foreground activation and reported `NSFileProtectionCompleteUnlessOpen` for the inheritance probe, receipt directory, and individual receipt file. The copied device receipt, opaque manifest, event, and independent fixture agree on transfer ID, exact byte count, and SHA-256. XCTest then verified the receipt after unlock and synthetic test gate. The test passed with zero assertions failed. These observations establish receipt creation and acceptance during the confirmed lock interval. They do not establish closed-file reopen while locked, physical canonical `.complete`, a fresh locked process, genuine system-initiated relaunch, sudden-power-loss durability, or production authentication. The temporary Info.plist and signing changes were removed from the reviewed project source.

Final focused verification passed nine receipt-store tests, including six dynamic publication-interruption cases, and four Python fixture/sanitizer tests. Configured SwiftFormat found zero of five new Swift files needing formatting; strict SwiftLint found zero violations. `git diff --check`, runner shell syntax, Xcode project validation, and scheme XML validation passed. Repository `make lint` passed four compiler-backed complete-corpus analysis passes with zero violations, `make build` passed all three configured builds, and `make test` passed both app and package test commands. The later physical test adds direct receipt-file protection and locked-interval evidence, but does not close the remaining physical canonical protection, genuine system-relaunch, sudden-power-loss, or production authentication criteria.

## Decision matrix

| Requirement | Public WebPage download | Background URLSession | WKWebView/WKDownload bridge |
| --- | --- | --- | --- |
| Detect download intent | Yes | Uses WebPage intent | Uses WebPage intent/request |
| Browser-native download object | No public lifecycle found | No | Yes |
| Content-Disposition | Detect response / replay request | Yes | Yes |
| Cookie-authenticated HTTP(S) | WebPage itself yes; file handoff unresolved | Manual Cookie attachment in the tested design was unsafe across cross-origin redirects; authenticated acquisition unsupported | Shared `WKWebsiteDataStore` identity did not provide automatic HttpOnly-cookie parity to the companion `WKDownload` |
| Redirect/auth delegate fidelity | Handoff unresolved | Tested manually attached cookies could cross a cross-origin redirect; do not use that bridge | WebKit redirect delegate enforced the tested same-origin and downgrade boundary |
| `blob:` / page-generated download | Potentially WebKit knows, but app handoff unresolved | No ordinary network URL | Only if initiated in the originating WKWebView; bridge replay likely insufficient |
| Background/system-termination continuation | Not established | Strong documented support | Not established as durable background transfer |
| Direct receipt-staging destination | No public handoff | Move completed temp file | WKDownload delegate chooses destination |
| Fits #42 ordinary browser downloads | Unproven / likely insufficient | Partial emulation | Partial hybrid |
| Fits #43 explicit Save to Vault | No public download handoff; explicit GET requires a separate app-owned transfer | Validated only for the supported request-backed GET subset; manually attached cookies were unsafe across cross-origin redirects | Validated only for the supported request-backed GET subset; shared-store identity does not supply HttpOnly cookies |
| Native SwiftUI WebView context menu | Native image menus appeared in Spike 5, but `.webViewContextMenu(menu:)` is unavailable on iOS 27 and delivered no app selected-element callback | Does not supply a selection UI | The companion does not restore the visible SwiftUI menu callback; Spike 4's `vault-save:` links were synthetic fixture actions |
| Production receipt and durable lifecycle | Not implemented / unverified | Production receipt acceptance and durable lifecycle unverified | Production receipt acceptance, durable lifecycle, and effective device protection unverified |

## Working architectural hypothesis

Do not force #42 and #43 through one network transport merely because they both end in ingestion.

The observed results narrow the current hypothesis:

- **Visible browser:** WebPage/WebView if the other browser migration gates pass.
- **Explicit Save to Vault (#43):** validated only for the supported request-backed HTTP(S) GET subset. Spike 2's manually attached cookies were unsafe across cross-origin redirects. Spikes 3–4 showed that even an identical `WKWebsiteDataStore` does not automatically give a companion `WKDownload` the browser's HttpOnly cookies. Authenticated acquisition remains unsupported until a safe session boundary is demonstrated.
- **Ordinary browser downloads (#42):** keep a WebKit-native path where WebKit semantics are required; if public WebPage still provides no download lifecycle, this may be the feature that prevents a complete WKWebView removal.
- **Receipt convergence:** production receipt acceptance is not implemented. Durable background/relaunch lifecycle and effective device protection remain unverified; completed files cannot be assumed to enter the production issue-#13 receipt/journal boundary.
- **Inline-media selection:** Spike 5's genuine simulator presses showed native image menus but no app callback, because the SwiftUI context-menu modifier is unavailable on iOS 27. The narrow bridge received no genuine `contextmenu` event, despite diagnostic pointer/touch delivery. An inline-media Save action has no demonstrated selected-resource path in the tested SwiftUI WebView architecture. Spike 4's synthetic `vault-save:` fixture links remain separate evidence for explicit request-backed GET acquisition only.

The spikes above should decide whether the hybrid can be narrow enough to justify WebPage migration, or whether retaining WKWebView as the visible browser is cheaper and more correct because acquisition is the browser's primary product purpose.

## Order of execution

Run these before spending implementation effort on a WebPage migration:

1. Public WebPage ordinary download lifecycle.
2. Explicit Save-to-Vault request-backed GET transfer; evaluate any browser-session access without manually attaching cookies.
3. Inline-media long-press identification.
4. Background receipt staging + lock/relaunch.
5. WKWebView download bridge only if #1 fails or #2 has session-fidelity gaps.
6. Then run the existing WebPage tab/refresh/transition/popup gates.

A failure in browser downloads should weigh more heavily than modest savings in browser rendering code because acquisition is the reason this product carries a first-class browser.
