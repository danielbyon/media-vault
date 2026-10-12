# Inline-media long-press evidence

This folder records the disposable Spike 5 experiment for Media Vault's
SwiftUI `WebView` on iOS/iPadOS 27. The experiment does not fetch selected
media or write to the vault. It starts from repository commit
`50497c10ab101c454db69e00a5fb23be1b5a1c3b` in an isolated worktree.

The installed toolchain is Xcode 27.0 (27A266a) with iOS simulator runtime
27.0 (24A434). The tested devices are iPhone 17 and iPad Pro 11-inch (M5).
The deterministic JPEG fixture has SHA-256
`72400effcd608610b5b3ce17cba806e246219cc57985580be76e1aef3dfe3376`;
the MP4 fixture has SHA-256
`b366c8ac6b93776ef6d6196fc365e8e41312055bacbf546504c218b7875693f8`.

## Reproduce

From the repository root:

```sh
bash Scripts/swift-tools.sh bootstrap
bash Prototypes/BrowserInlineMediaSpike/run-spike.sh
SPIKE_ONLY_TESTS=testFrameAndVideoDeliveryDiagnostics,testNonMediaAndOpaqueDeliveryDiagnostics,testNativeCrossFrameRepeat \
  bash Prototypes/BrowserInlineMediaSpike/run-spike.sh
```

The runner writes a timestamped directory below
`.build/browser-inline-media-spike5/` with full local logs, independent
recorder JSON, per-device matrices, and `.xcresult` bundles containing a
screenshot after every XCUITest press. It runs SwiftFormat, strict SwiftLint,
focused Swift and Python tests, an intentional compiler-failure API probe,
serial iPhone/iPad UI tests, and `git diff --check`.

The retained JSON contains only deterministic fixture paths and bounded,
sanitized observations. It omits recorder tokens, cookies, headers, media
bytes, `data:` payloads, and `blob:` identifiers. A media GET means that
WebKit loaded a fixture; it does not identify which resource a user selected.

## Native API proof

[`native-api-probe.swift`](native-api-probe.swift) attempts to install a
SwiftUI `WebView.webViewContextMenu` Save action. The installed iOS 27 SDK
reports `'webViewContextMenu(menu:)' is unavailable in iOS`. Its interface
includes `WebView.ActivatedElementInfo` in the modifier signature but marks the
modifier itself unavailable to the tested iOS target. A native image menu
visible in a screenshot is therefore independent of any app callback or URL
result.

## Interpretation boundary

Only a genuine `contextmenu` message from the installed isolated script
could provide selected-element candidates. Diagnostic pointer and touch
messages deliberately carry no resource URL. The native WebKit message
world, frame flag, security origin, and frame request are recorded separately
from the page's URL/origin fields. Even a well-formed candidate and
`event.isTrusted` would remain untrusted input, never permission to save bytes.

The parser's unit tests exercise linked-media separation, relative URL
resolution, opaque URL redaction, malformed and synthetic messages, frame
isolation, and navigation-stale rejection. A unit test payload is not evidence
that iOS delivered a genuine context-menu event.

## Full-run observations

The full serial run is
`.build/browser-inline-media-spike5/run-20261011T022402Z/`. Both device suites
passed seven UI tests. Xcode then logged a nonfatal 600-second timeout while
collecting extra iPad diagnostics; the iPad test command returned success and
retained its `.xcresult` bundle.

1. [iPhone matrix](iphone-matrix.md) and [iPad matrix](ipad-matrix.md) compare
   each fixture's native menu, unavailable app callback, bridge event count,
   and WebKit frame metadata. The source records are [iPhone JSON](iphone-evidence.json)
   and [iPad JSON](ipad-evidence.json).
2. [iPhone linked image](iphone-linked-menu.png) and
   [iPad linked image](ipad-linked-menu.png) show native link menus. Their
   preview displays the fixture's separate `/destination/link` response,
   while Save to Photos remains a system action. Neither screenshot proves an
   app-selected media URL.
3. [iPhone video](iphone-video-native.png) and
   [iPad video](ipad-video-native.png) show an inline play control with no
   detected context menu. Diagnostic messages from `VIDEO` prove pointer and
   touch delivery on both devices.
4. [iPhone blob image](iphone-blob-menu.png) and
   [iPad responsive image](ipad-responsive-menu.png) show valid image menus.
   The responsive page loaded `/media/image-wide.jpg` on iPad and
   `/media/image-a.jpg` on iPhone, but no selected URL reached the app.
5. [iPhone cross-origin frame without a detected menu](iphone-cross-iframe-no-menu.png)
   and [the same fixture with a menu](iphone-cross-iframe-menu.png) preserve
   the observed native-menu variability across modes. The long press was
   invoked in both cases; the diagnostic mode separately verified pointer and
   touch delivery from the inner frame.

Across the bridge matrix, all 14 element cases on each device reported zero
genuine JavaScript `contextmenu` messages. The synthetic event reached the
installed handler and was rejected. The page-world handler probe reported
`handler-not-visible`. No native iOS `WebView` activated-element callback was
available to test for a returned or absent URL.

## Focused event-delivery repeat

The focused serial run is
`.build/browser-inline-media-spike5/run-20261011T061802Z/`. Each device passed
three further UI tests using genuine long presses, and both saved device test
exit statuses are zero. Xcode logged a nonfatal 600-second iPad diagnostic
collection timeout before returning `TEST EXECUTE SUCCEEDED`. The shell runner
reported a post-test parse error because its source was edited during that
diagnostic wait; both device JSON and matrix exports had already completed.
The corrected runner passes `bash -n`, and its final `git diff --check` gate
was run separately with exit status zero. The [iPhone focused
matrix](iphone-focused-matrix.md) and [iPad focused matrix](ipad-focused-matrix.md)
retain their separate [iPhone JSON](iphone-focused-evidence.json) and
[iPad JSON](ipad-focused-evidence.json) observations.

Both devices delivered diagnostic pointer/touch messages from CSS background,
canvas, `blob:` image, and `data:` image targets. They delivered no genuine
`contextmenu` message or selected resource candidate. CSS and canvas showed
no detected native menu; the valid opaque URL images showed native image
menus. Both repeat native cross-origin iframe presses displayed an image menu
on each device. The full run's one iPhone native press without a detected menu
remains a recorded variation, not an assertion that cross-origin frames never
show a menu.

## Validation scope

The isolated Swift package passed 13 decoder tests with 116 of 116 source
lines covered; the fixture server passed seven HTTP tests. The dedicated
scheme built with Swift 6 strict concurrency and passed seven full-run plus
three focused UI tests on each simulator. The installed-SDK probe failed to
typecheck for the expected iOS-unavailable modifier diagnostic. Configured
SwiftFormat, strict SwiftLint on all six spike Swift files, and
`git diff --check` passed. Physical devices, other app-owned UI designs, and
actual post-navigation delayed WebKit message delivery were not exercised.
