# Test Gates

Local and CI test gates require Xcode 27.2 release build `27B52` and the iOS
27.2 simulator runtime build `24B8117`. The toolchain wrapper checks both before
running a command and stops if either is missing. It does not download simulator
runtimes. CI also records the runner image, source revision, and selected
simulator UDID.

CI runs four functional test lanes and two snapshot qualification jobs.
`make test` runs the four functional Make targets locally. The 2x iPad job
compares visual snapshots against the canonical baseline, and the 3x iPhone job
qualifies focused root and hosted snapshots at the destination's native scale.

## Privacy test layers

Privacy coverage uses three layers so UIKit protection does not depend on
pixel-perfect full-window images.

| Layer | Purpose and coverage | Command |
| --- | --- | --- |
| A. Policy and session state | `ScenePrivacyCoverPolicyTests`, `RootFeatureTests`, and `VaultShellFeatureTests.navigationStateTracksTabsAndSettings` cover policy transitions, lock timing, cancellation, verification ordering, expired returns, tab selection, and Settings state transitions with deterministic state and clocks. | `make test` |
| B. UIKit protection behavior | App-hosted `ScenePrivacyCoverTests` exercise the real `RootView`, TCA store, scene, primary window, calculator decoy, and separate cover window. The hosted suites check attachment, occlusion, hit-test and accessibility isolation, reveal ordering, expiry, and cleanup without golden full-window snapshot comparisons. The sentinel-occlusion test runs on both the iPhone and canonical iPad destinations to exercise compact and regular fixtures. `BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testAuthenticatedShellTabsAreAccessibleAndChangeDestinations` checks Collections, Browser, and Library navigation in the simulator's default layout; it does not establish the two-layout privacy fixture matrix. | `make test` for hosted behavior; separate `BrowserTabOverviewUITests` selectors below |
| C. Native presentation snapshots | SnapshotTesting compares production calculator and Library content at compact and regular sizes. Locked and expired states share calculator references; authenticated and resumed states share Library references. The shell's rendered controls are covered by Layer B. Separate calculator snapshots cover the overlay's glyphs, keys, colors, and layout. Comparisons are exact. | `make test-snapshots`; focused root/hosted native-scale checks use `make test-native-snapshots` |

`make test` runs Layer A and the app-hosted part of Layer B through four
functional targets. The iPhone targets skip root-surface snapshots, hosted
presentation snapshots, and the five package snapshot suites. A separate App
invocation on the canonical iPad runs
`rootPrivacyCoverSynchronouslyOccludesPrivateSentinel`; that test exercises
both compact and regular fixtures. The browser UI target runs 15 simulator-safe
selectors through the `BrowserTabOverviewUITests` scheme on the canonical iPad:
four multi-scene cases and eleven qualification cases. Result checks require
the expected test identities and destination. All selected cases must pass;
the iPhone App lane alone permits its specifically identified physical-only
skip. `testSystemResizeChangesActualSceneGeometry` remains outside this
unattended suite under its existing qualification scope.
This host-only coverage does not enable multiple scenes in the shipping app
or replace physical scene/privacy qualification. Shell navigation and
Lock-control UI tests remain separate. `make test-snapshots` runs Layer C and
the repository's other exact visual suites. UIKit protection is checked
through state, accessibility, hit-testing, and synthetic private-pixel
occlusion assertions.

The hosted privacy behavior tests cover compact and regular fixtures in
`make test`. The remaining shell-control UI tests run in the separate
`BrowserTabOverviewUITests` scheme.

Layer B privacy fixtures use 320x568 compact and 1024x1366 regular dimensions.
`BrowserTabOverviewUITests` use simulator-default geometry and do not assert a
compact/regular trait pair. Layer C regular content snapshots use the 834x1194
iPad Pro fixture. The regular-width layouts use distinct dimensions for the
behavior and snapshot layers.

### Legacy privacy coverage migration

The tables map each former lifecycle assertion and the 16 full-window
references removed by this candidate to its replacement coverage. Before the
removal, the replacement behavior tests and presentation snapshots passed
locally. The evidence statuses in this migration table record the
pre-correction baseline; the corrective qualification is recorded in Section 7.
Historical CI run `42738343511` failed on three full-window captures
from a different host; the cause remains unknown. Later CI run `42774304680`
passed on the pre-correction candidate at `636bf7687f9fca95fa3dce94b23e874144f4a1b7`.
Its first snapshot attempt stopped when the XCTest runner hung before it
connected to the simulator. The successful second attempt passed the updated
snapshot suites. That CI result does not cover later corrective commits.

| Former assertion group | Layer | Current test or identity | Coverage | Evidence status | Qualification gate |
| --- | --- | --- | --- | --- | --- |
| `coveredSceneInstallsSceneBoundBarrier` | A, B | `ScenePrivacyCoverPolicyTests.activeSceneFollowsCallerCoverageUpdates`; `coveredSceneInstallsSceneBoundBarrier`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel`; `BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testAuthenticatedShellTabsAreAccessibleAndChangeDestinations` | Policy state, cover-window contract, modal accessibility, same-scene cover level above the primary window, direct hit-testing to visible interactive cover content, and shell actions in the UI-test simulator's default layout. The touch-delivery path is not executed. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `hiddenCoverIsLaidOutBeforeFirstDeactivation` | B | `hiddenCoverIsLaidOutBeforeFirstDeactivation`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel`; `rootPrivacyReturnAndExpiryOrdering` through `expectRootPrivacyCoverAttached` | Initial cover attachment, hidden state, loaded controller, nonzero bounds and frames, accessibility traits, and layout before deactivation in both layouts. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `sceneWillDeactivateImmediatelyShowsPrimaryDecoy` | B | `sceneWillDeactivateImmediatelyShowsPrimaryDecoy`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Library and Browser decoy behavior in the iPhone test run, plus synthetic sentinel occlusion in compact and regular fixtures on the iPad run. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `sceneDidEnterBackgroundImmediatelyShowsPrimaryDecoy` | B | `sceneDidEnterBackgroundImmediatelyShowsPrimaryDecoy`; `rootPrivacyReturnAndExpiryOrdering`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Background notification, cover visibility, and return ordering in hosted behavior tests; synthetic sentinel occlusion runs in compact and regular fixtures on iPad. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `calculatorFaceFitsCompactPhoneAndWideIPadLayouts` | B, C | `calculatorFaceFitsCompactPhoneAndWideIPadLayouts`; `ScenePrivacyCoverCalculatorSnapshotTests.compactPhoneSnapshot`; `ScenePrivacyCoverCalculatorSnapshotTests.regularIPadSnapshot` | Production calculator layout at compact and regular sizes. | Exact snapshots passed; the key-geometry mutation failed all 8 snapshots as expected. | `A/B gate` and `C gate` |
| `validatedCallerUpdateRevealsAfterInactiveCoverage` | A, B | `ScenePrivacyCoverPolicyTests.validatedUpdateAfterActivationRevealsScene`; `validatedCallerUpdateRevealsAfterInactiveCoverage`; `rootPrivacyReturnAndExpiryOrdering` | Validation ordering, cover presence before reveal, and post-activation reveal. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `coveredCallerUpdateBeforeWillDeactivateRemainsAcknowledged` | A, B | `ScenePrivacyCoverPolicyTests.coverageBeforeDeactivationAcknowledgesTransition`; `coveredCallerUpdateBeforeWillDeactivateRemainsAcknowledged` | Coverage acknowledged before deactivation and retained through the transition. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `staleUncoveredUpdateDoesNotRevealAfterActivation` | A, B | `ScenePrivacyCoverPolicyTests.staleUncoveredUpdateNeedsCoverageAcknowledgement`; `staleUncoveredUpdateDoesNotRevealAfterActivation` | A stale uncovered result cannot reveal without the required acknowledgement. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `validatedCallerUpdateBeforeActivationRevealsAfterActivation` | A, B | `ScenePrivacyCoverPolicyTests.validatedUpdateBeforeActivationWaitsForActivation`; `validatedCallerUpdateBeforeActivationRevealsAfterActivation` | A validated update remains covered until scene activation. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `initiallyCoveredInactiveSceneWaitsForActivation` | A, B | `ScenePrivacyCoverPolicyTests.initiallyInactiveSceneWaitsForActivation`; `initiallyCoveredInactiveSceneWaitsForActivation` | Initial inactive coverage remains closed until activation and validation. | Passed in final local Layer A/B qualification. | `A/B gate` |

The 16 retired images formed eight groups: one primary-window image per layout,
plus scene-cover images for inactive and background states.

| Former lifecycle reference group | Layer | Current test or identity | Coverage | Evidence status | Qualification gate |
| --- | --- | --- | --- | --- | --- |
| Authenticated active primary window | B, C | `BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testAuthenticatedShellTabsAreAccessibleAndChangeDestinations`; `BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testPersistentLockControlIsAccessibleAcrossAuthenticatedDestinations`; `root-content-v1-library-compact-iphone`; `root-content-v1-library-regular-ipad` | Root-content captures show authenticated Library content at compact and regular widths; separate UI tests exercise tab navigation and Lock control. | Strict root-content snapshots passed; the Library-control mutation failed the new root-presentation snapshot. The two focused UI tests passed separately. | `A/B gate` and `C gate` |
| Inactive protected primary window | B | `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Pixel occlusion, same-scene cover level above the primary window, and hit-test routing to a visible interactive cover descendant. Root-content calculator snapshots separately cover the locked decoy presentation. | The alpha-zero privacy mutation failed the alpha and private-pixel occlusion assertions; exact snapshots passed after restoration. | `A/B gate` |
| Inactive protected scene cover | B | `coveredSceneInstallsSceneBoundBarrier`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Cover visibility, key status, modal accessibility, cover level above the primary window, and direct hit-test routing in both layouts. | Layer B passed; the test checks cover level above the primary window and direct cover hit testing, not scene-wide ordering. | `A/B gate` |
| Background protected primary window | B | `rootPrivacyReturnAndExpiryOrdering`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Background grace, cover retention, sentinel occlusion, and primary-window state at both layouts. | Functional CI passed the behavior tests; the three old full-window captures were the only snapshot failures. | `A/B gate` |
| Background protected scene cover | B | `rootPrivacyReturnAndExpiryOrdering` | Cover remains visible and key during background grace and expiry at both layouts. | Functional CI passed the behavior tests; the three old full-window captures were the only snapshot failures. | `A/B gate` |
| Locked calculator decoy primary window | B, C | Calculator face checks; `root-content-v1-calculator-compact-iphone`; `root-content-v1-calculator-regular-ipad` | Production calculator content at both layouts. | The new native calculator snapshots failed 2/2 under the key-height mutation; the legacy calculator suite failed 8/8. | `A/B gate` and `C gate` |
| Resumed authenticated primary window | B, C | `rootPrivacyReturnAndExpiryOrdering`; `root-content-v1-library-compact-iphone`; `root-content-v1-library-regular-ipad` | Validated return ordering and Library content at both layouts. | The Import-control style mutation failed the root-presentation snapshot test; strict snapshots passed after restoration. | `A/B gate` and `C gate` |
| Expired return before authentication | B, C | `rootPrivacyReturnAndExpiryOrdering`; `root-content-v1-calculator-compact-iphone`; `root-content-v1-calculator-regular-ipad` | Expiry during cover, reveal ordering, and calculator content at both layouts. | Expiry and decoy behavior passed in Layer B; exact snapshots passed after restoration. | `A/B gate` and `C gate` |

The four Layer C content identities are
`root-content-v1-calculator-compact-iphone`,
`root-content-v1-calculator-regular-ipad`,
`root-content-v1-library-compact-iphone`, and
`root-content-v1-library-regular-ipad`. Locked and expired states share the
calculator identity. Authenticated and resumed states share the Library
identity. Xcode 27.2 build 27B52 and iOS 27.2 build 24B8117 recorded these
references on the canonical 2x iPad Pro 11-inch (M5). The three old
cross-host full-window failures belong to the historical run above. The later
green run used the migrated selectors after those references were removed.

## 1. Functional test gate

Run `make test` to invoke the four functional targets locally. It runs each
target even if an earlier one fails, then exits nonzero if any target failed.
The targets use the Makefile's verified iPhone and iPad destinations, which
default to iPhone 17 and iPad Pro 11-inch (M5) on iOS 27.2.

`make test-app` runs the App scheme's `AppTests` and `AppHostedTests` bundles on
iPhone. It skips the root-surface snapshot suite, hosted presentation snapshot,
and HTTP test suite; the HTTP matrix runs in a separate App invocation. The
snapshot selectors are:

- `-skip-testing:AppTests/RootSurfaceSnapshotTests`
- `-skip-testing:'AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPresentationSnapshotsCoverPrimaryShellStates()'`

`make test-application-foundation` runs the package scheme except for these five
snapshot suites:

1. `AppFeatureTests/VaultFeatureViewSnapshotTests`
2. `CalculatorFeatureTests/CalculatorViewSnapshotTests`
3. `MediaLibraryTests/MediaLibrarySnapshotTests`
4. `BrowserFeatureTests/BrowserViewSnapshotTests`
5. `PresentationSupportTests/ScenePrivacyCoverCalculatorSnapshotTests`

The original functional-gate baseline recorded 77 passing App tests and 446
passing ApplicationFoundation tests. Those are historical baseline counts,
not results for the current candidate. `make test-ipad-privacy` runs the
hosted `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` test on the
canonical iPad; it checks both compact and regular fixtures.

`make test-browser-download-ui` runs 15 exact selectors on the canonical iPad:
four `BrowserDownloadMultiSceneUITests` cases and eleven
`BrowserDownloadQualificationUITests` cases. The result checker requires every
selected identity to pass on the expected destination. All four targets
validate their result bundles and reject missing, unreadable, or empty results.
The only allowed App skip is
`AppHostedUITests/BrowserDownloadPersistenceIsolationTests/completedFilesRetainProtectionAndBackupExclusion()`;
it is a physical-only test and remains recorded as skipped, not passed.
ApplicationFoundation, iPad privacy, and browser UI require zero skipped tests.

`make all` runs `lint`, `build`, and `test`, including the iPad sentinel test.
It does not run snapshot suites. Snapshot evidence comes from
`make test-snapshots`.

## 2. Two-times iPad snapshot gate

Run `make test-snapshots`. The command uses `SNAPSHOT_DESTINATION`, which
defaults to `IPAD_DESTINATION`:
`platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.2`.

The canonical model is the iPad Pro 11-inch (M5) on iOS 27.2. The iPad mini
(A17 Pro) is available locally, but its availability on the `xcode-27` CI
runner is unverified. The implementation keeps one model for local and CI use
and does not switch models automatically.

The selected simulator reports:

- Runtime build: `24B8117`
- Main-screen scale: `2.000000`
- Main-screen size: `1668` by `2420` pixels
- Model identifier: `iPad17,2`

The App scheme runs these selections:

1. `AppTests/RootSurfaceSnapshotTests`
2. The hosted root presentation snapshot method.

The hosted root presentation method snapshots production content views with
SnapshotTesting's native SwiftUI `.image(layout:traits:)` strategy and its
default non-window capture. Locked and expired-return states snapshot
`decoySession.rootView`; authenticated and resumed states snapshot
`MediaLibraryView` after its load completes. Each pair shares the same
reference identity at compact phone and regular iPad sizes. These images cover
calculator and Library content, not shell toolbar, tabs, or material surfaces.
`VaultShellFeatureTests.navigationStateTracksTabsAndSettings` checks tab and
Settings reducer transitions. The separate `BrowserTabOverviewUITests` scheme
contains
`BrowserTabOverviewScrollUITests.testAuthenticatedShellTabsAreAccessibleAndChangeDestinations`,
which navigates among Collections, Browser, and Library;
`testPersistentLockControlIsAccessibleAcrossAuthenticatedDestinations`, which
checks the persistent Lock control in selected authenticated destinations; and
`testSettingsLockReturnsToCalculatorFromTopLevelAndBrowserSettings`, which
checks the Settings Lock action from top-level Settings and Browser Settings.
These three shell UI tests are outside `make test`; they do not prove the
two-layout fixture matrix or PAC-1/TAC-5, which remain deferred to Issue #59.
The hosted Layer C selector is:

`-only-testing:'AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPresentationSnapshotsCoverPrimaryShellStates()'`

The separate shell UI command targets the simulator's default layout:

```sh
./Scripts/with-xcode-27.2.sh xcodebuild \
  -workspace App.xcworkspace \
  -scheme BrowserTabOverviewUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.2' \
  -parallel-testing-enabled NO \
  -only-testing:BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests/testAuthenticatedShellTabsAreAccessibleAndChangeDestinations \
  -only-testing:BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests/testPersistentLockControlIsAccessibleAcrossAuthenticatedDestinations \
  -only-testing:BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests/testSettingsLockReturnsToCalculatorFromTopLevelAndBrowserSettings \
  test
```

The ApplicationFoundation scheme runs these five package snapshot suites:

1. `AppFeatureTests/VaultFeatureViewSnapshotTests`
2. `CalculatorFeatureTests/CalculatorViewSnapshotTests`
3. `MediaLibraryTests/MediaLibrarySnapshotTests`
4. `BrowserFeatureTests/BrowserViewSnapshotTests`
5. `PresentationSupportTests/ScenePrivacyCoverCalculatorSnapshotTests`

The baseline had 5 App snapshot tests and 32 ApplicationFoundation snapshot
tests. The candidate runs 5 App snapshot tests and 34 package snapshot tests.
Check `totalTestCount` in each result bundle; a command that discovers zero
tests does not qualify snapshots.

Baseline HEAD contains 37 snapshot methods and 65 reference files: 61 PNG
files and 4 text files. The canonical 2x baseline contains 39 methods and 55 reference
files: 51 PNG files and 4 text files. It adds one hosted root-presentation
method, a two-case calculator suite, four hosted content references, and two
calculator references, and retires the 16 full-window lifecycle images.

| Suite | Snapshot methods | PNG references | Text references |
| --- | ---: | ---: | ---: |
| `RootSurfaceSnapshotTests` | 4 | 3 | 1 |
| `VaultFeatureViewSnapshotTests` | 7 | 7 | 0 |
| `CalculatorViewSnapshotTests` | 8 | 8 | 0 |
| `MediaLibrarySnapshotTests` | 6 | 3 | 3 |
| `BrowserViewSnapshotTests` | 11 | 24 | 0 |
| `ScenePrivacyCoverCalculatorSnapshotTests` | 2 | 2 | 0 |
| `ScenePrivacyCoverTests` | 1 | 4 | 0 |

The 44 PNG references from the original baseline migration use the 2x rendering
scale for the canonical destination. That migration replaced all 44 PNG
references with suite-and-method paths and preserved the four text references.
The 44 migrated images were checked against the prior 3x references for the
expected 1.5x pixel-scale relationship and layout-equivalent content. The 16
former hosted privacy references covered these states and windows at compact
and regular widths. Their names remain here as migration history; their image
files are no longer snapshot inputs. The compact-phone states were captured as
compact fixtures by the canonical iPad snapshot run:

- Authenticated active, primary window:
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-authenticated-primary-window-compact-iphone.png`
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-authenticated-primary-window-regular-ipad.png`
- Inactive protected, primary window:
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-inactive-protected-primary-window-compact-iphone.png`
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-inactive-protected-primary-window-regular-ipad.png`
- Inactive protected, scene cover:
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-inactive-protected-scene-cover-compact-iphone.png`
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-inactive-protected-scene-cover-regular-ipad.png`
- Background protected, primary window:
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-background-protected-primary-window-compact-iphone.png`
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-background-protected-primary-window-regular-ipad.png`
- Background protected, scene cover:
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-background-protected-scene-cover-compact-iphone.png`
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-background-protected-scene-cover-regular-ipad.png`
- Locked calculator decoy, primary window:
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-locked-decoy-primary-window-compact-iphone.png`
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-locked-decoy-primary-window-regular-ipad.png`
- Resumed authenticated, primary window:
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-resumed-primary-window-compact-iphone.png`
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-resumed-primary-window-regular-ipad.png`
- Expired return before authentication, primary window:
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-expired-before-authentication-primary-window-compact-iphone.png`
  - `assertLiveWindowSnapshot-of-in-named.real-root-v3-expired-before-authentication-primary-window-regular-ipad.png`

The root content method adds four references: calculator and Library content
at each layout. Locked and expired states share calculator references;
authenticated and resumed states share Library references. The 16 former
lifecycle paths listed above remain here as migration history. Their files
were removed after replacement behavior and content coverage passed locally
and on the matching runner. They are no longer snapshot inputs.
Reference ownership follows the test target: hosted root images belong under
`AppHostedTests/__Snapshots__/ScenePrivacyCoverTests/`, and calculator view
images belong under
`Packages/ApplicationFoundation/Tests/PresentationSupportTests/__Snapshots__/ScenePrivacyCoverCalculatorSnapshotTests/`.

Source qualification records, original reference hashes, and comparison
manifests remain external evidence and are not test inputs. The 2x baseline
migration did not change snapshot precision, tolerance, or rendering
configuration.

The lifecycle snapshot method and its 16 full-window images are retired. Layer
B's occlusion sentinel, hit-test routing, and reveal-ordering tests verify real
UIKit cover behavior in both layouts. Layer C snapshots production calculator
and Library content through SnapshotTesting's native SwiftUI strategy. The
separate calculator suite tests the production UIKit calculator view. Snapshot
comparisons remain exact.

The tests post `UIScene` lifecycle notifications through `NotificationCenter`
and use an injected clock for expiry cases. These notifications are synthetic:
they do not exercise the operating system's background and suspension path or
qualify physical-device lifecycle behavior. TAC-3 and TAC-4 still require
separate device evidence. A background notification or observed process
identifier does not establish OS suspension. Accessibility qualification is
tracked separately under Issue #59.

Snapshot recording remains disabled by
`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never`; a missing reference fails the
test. Hosted content and calculator snapshots use exact comparison.
Do not record or replace references from a failing run;
candidate actual, reference, and difference images belong in external
comparison evidence.

### 2a. Focused native-scale qualification

The 55 canonical reference files remain unchanged: 51 PNGs and four text files.
Seven additional 3x PNGs bring the reference inventory to 62 files without adding
snapshot methods. At 2x, root and hosted content assertions retain their existing
reference identities. At 3x, root image names use `.3x.png`, and hosted content
names end in `-3x.png`. The five package snapshot suites remain qualified at 2x.

`make test-native-snapshots` uses `NATIVE_SNAPSHOT_DESTINATION`, which defaults
to `IPHONE_DESTINATION`, and `NATIVE_SNAPSHOT_EXPECTED_SCALE=3`. An explicit 2x
run uses the canonical iPad:

```sh
make test-native-snapshots \
  NATIVE_SNAPSHOT_DESTINATION='platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.2' \
  NATIVE_SNAPSHOT_EXPECTED_SCALE=2 \
  TEST_RESULTS_DIRECTORY="$HOME/Library/Logs/native-snapshot-evidence"
```

`NATIVE_SNAPSHOT_BUILD_DIRECTORY` defaults to the checkout's `.build`.
An external directory keeps DerivedData off the internal disk.
`SOURCE_PACKAGES_DIRECTORY` continues to accept the existing Make override.
The functional and canonical snapshot commands retain their defaults and
canonical 2x references.

The target runs two App-scheme selections sequentially, with parallel testing
disabled and `-collect-test-diagnostics never`. Expected-failure diagnostics
have previously hung; the result bundles and exported attachments supply the
evidence. There are no retries or test skips. The second selection and evidence
validation are attempted even if the first selection fails.

1. `AppTests/RootSurfaceSnapshotTests` must report exactly four passed tests.
   Its three image methods each emit one environment receipt:
   `compactPhoneSnapshot()`, `largePhoneSnapshot()`, and
   `regularWidthIPadSnapshot()`. The fourth test covers text.
2. `AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPresentationSnapshotsCoverPrimaryShellStates()`
   must report exactly one passed test. It performs eight hosted snapshot
   assertions across four identities:
   `root-content-v1-{calculator|library}-{compact-iphone|regular-ipad}`.
   Each identity must have exactly two receipts, attributed to that method.

Each summary must report the exact total and passed counts, zero failed tests,
and zero skipped tests. The target exports all attachments for each bundle.
The inline Python standard-library validator reads `manifest.json`, resolves
receipt files through `exportedFileName`, and recognizes their
`native-snapshot-environment` prefix through either that name or
`suggestedHumanReadableName`. Exporter suffixes do not change receipt identity.
Each receipt must belong to the corresponding test ID in the manifest.

Schema version 1 requires raw `qualification`, `expectedScale`, and
`recordMode` values of `"1"`, the requested `"2"` or `"3"`, and `"never"`.
Both numeric `nativeScale` and `referenceScale` must equal the requested scale.
The receipt also requires the expected `capture` and `target` (`AppTests` or
`AppHostedTests`), a positive integer `processID`, a nonempty `processName`,
and `validationError: null`. Missing, malformed, duplicated, mismatched, or
misattributed evidence fails qualification even when Xcode exits successfully.

The Make invocation clears ambient `NATIVE_SNAPSHOT_QUALIFICATION`,
`NATIVE_SNAPSHOT_EXPECTED_SCALE`, and `SNAPSHOT_TESTING_RECORD`. It explicitly
passes `TEST_RUNNER_NATIVE_SNAPSHOT_QUALIFICATION=1`,
`TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE=2` or `3`, and
`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never` through Xcode's runner transport.
The receipts prove what the test process received and which scale it used.
Direct Xcode runs without these overrides are allowed for development; their
receipts do not qualify the run.

The hosted native layouts accept a 32-point top inset on iPad and a 54-point
top inset on iPhone. These are accepted native test-host geometries. They do
not establish physical-device layout or lifecycle behavior, and the two scales
need not produce identical point geometry.

Every invocation creates a fresh evidence directory below
`TEST_RESULTS_DIRECTORY`, or below
`NATIVE_SNAPSHOT_BUILD_DIRECTORY/TestResults` when that option is unset.
Both bundles, all attachment exports, summaries, Xcode logs, export logs, and
validation logs remain there after build cleanup, including on failure.
Interrupted runs can leave partial evidence; partial evidence does not qualify.

## 3. Result bundles and failure handling

`TEST_RESULTS_DIRECTORY` is optional. Each functional target and
`make test-snapshots` creates a unique subdirectory below it and directs
`xcodebuild` to write result bundles there. Xcode writes bundles directly, so
completed and partial results remain after success, failure, cancellation, and
build cleanup. The local `make test` aggregate gives each target its own unique
result subdirectory. CI uses a separate parent directory for each matrix lane
and uploads that lane's result bundles, captured Make log, and
`source-identity.json`.

`XCODE_BUILD_ROOT` selects temporary DerivedData and build-product storage for
`make build`, the functional targets, and `make test-snapshots`. Cleanup removes the
invocation's generated build root and preserves the caller's result directory
and unrelated files. Without `TEST_RESULTS_DIRECTORY`, bundles stay in the
temporary root and are removed during normal cleanup.

`make test-native-snapshots` writes result bundles, summary output, exported
attachments, and validation logs to a unique `native-snapshots.*` directory
under `TEST_RESULTS_DIRECTORY`. Without that setting, it writes under
`NATIVE_SNAPSHOT_BUILD_DIRECTORY/TestResults`. The target removes its temporary
build root after the run.

`make destination-test` exercises these ownership rules with disposable process
fixtures. It covers completed and partial results, later failures, graceful and
abrupt termination, repeated invocations, paths with spaces, cleanup boundaries,
and artifact-name/report consistency. Abrupt-termination tests signal only
their own mock process groups, exercising cleanup without launching Xcode or
simulators.

The functional targets check exact test identities, expected simulator
destinations, and result counts with `Scripts/assert-xcresult-tests.py`.
The App and ApplicationFoundation targets derive their expected identities from
Xcode test enumeration. The App check allows only the named physical-only skip;
all required App tests and every selected HTTP matrix case must pass. The other
three targets require every selected test to pass with no skips. A missing,
unreadable, or empty result bundle fails its target.

`make test` attempts all four targets so one lane's failure does not hide the
results from the others. It exits nonzero if any target fails.

`make test-snapshots` runs both schemes even when the first scheme fails. It
records each scheme's `xcodebuild` status and result-bundle validation status
independently, attempts validation for both bundles regardless of either
`xcodebuild` result, and reports every failure category it observed. The target
exits nonzero when any status fails; a later passing scheme cannot clear an
earlier failure. Preserved `xcresult` bundles remain the source for the
per-scheme executed counts.

The functional targets validate each bundle after its test command. The App
target attempts its HTTP invocation and validates its results even if an
earlier App check failed. `make test-snapshots` validates each bundle after its
scheme's test command; a validation failure does not stop the second scheme,
and the target reports every failure it observed.

Both snapshot `xcodebuild test` commands set
`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never`. `TEST_RUNNER_` is Xcode's
test-runner environment propagation prefix, and the test process receives the
suffix as `SNAPSHOT_TESTING_RECORD=never`. SnapshotTesting therefore fails when
an expected reference is missing instead of creating one. A comparison failure
against an existing reference still fails and still attaches its actual,
reference, and difference artifacts to the result bundle. Neither behavior
replaces a tracked reference.

## 4. Continuous integration

`.github/workflows/tests.yml` runs four functional matrix copies, an `iOS tests`
aggregate, and the two snapshot qualification jobs.

1. `functional-tests` has four matrix entries: `App`, `ApplicationFoundation`,
   `iPad privacy`, and `Browser download UI`. Each entry calls its fixed Make
   target: `test-app`, `test-application-foundation`, `test-ipad-privacy`, or
   `test-browser-download-ui`. The matrix sets `fail-fast: false`, so one failed
   lane does not cancel the other three. Each copy runs on `xcode-27` with a
   90-minute timeout, the Xcode 27.2 toolchain, destination verification, and
   the Swift package cache. The iPhone App and package targets receive the
   verified iPhone and iPad simulator IDs; the two iPad targets use the verified
   canonical iPad ID. The destination-resolver and clean-target mock checks run
   once in the App copy; simulator verification remains in every copy.

2. Every matrix copy writes to its own
   `.build/TestResults/<lane>` directory. It retains the Make output log,
   `source-identity.json`, and the target's result bundles in that directory.
   The identity file records the workflow event SHA, checked-out commit and
   parents, and, for pull requests, the exact head SHA, base SHA, and integration
   SHA. The step saves this identity before failing if the checked-out commit
   does not match the event SHA. The upload artifact name includes the lane,
   GitHub run ID, and attempt number. Upload runs after success or failure and
   is advisory: missing files produce a warning, and an upload action failure
   does not change the functional lane conclusion. Check the job step and log
   when the artifact is missing or its upload did not succeed.

3. Job `test`, named exactly `iOS tests`, has `if: always()` and depends on the
   functional matrix. It succeeds only when the matrix job conclusion is
   exactly `success`. Failure, cancellation, skipping, or any other conclusion
   fails the aggregate. Every copy runs its target without `continue-on-error`;
   only the evidence-upload step uses advisory `continue-on-error`. No matrix
   copy has a job-level skip condition. The two snapshot jobs remain
   separate workflow checks; they are not folded into the `iOS tests` aggregate.

4. `snapshot-qualification`, named `Snapshot qualification (2x iPad)`, runs
   `make test-snapshots` on the canonical 2x iPad. Its result bundles remain
   under `.build/TestResults`, and the always-run upload uses
   `2x-ipad-snapshot-evidence-run-<run_id>-attempt-<run_attempt>`. Its final
   step reports command and upload outcomes.

5. `native-snapshot-qualification`, named
   `Native snapshot qualification (3x iPhone)`, runs
   `make test-native-snapshots` with a 60-minute job timeout and a 45-minute
   test-step timeout. It uses the pinned `xcode-27` runner, toolchain preflight,
   and package cache. Results remain under `.build/NativeSnapshotResults`, and
   the always-run upload uses
   `native-3x-iphone-snapshot-evidence-run-<run_id>-attempt-<run_attempt>`.

The two snapshot jobs keep their existing job names, destinations, timeouts,
commands, status summaries, and artifact paths. Each remains an independent
workflow check. A failed snapshot command can indicate a reference mismatch,
build error, unavailable simulator, or timeout; inspect that job's artifact or
log before assigning a cause. A passing 2x command confirms that the committed
references match in the automated run and both schemes recorded positive test
counts. Owner visual review remains separate.

Each test job resolves simulator IDs through `make verify-test-destination`
or `make verify-snapshot-destination`. The Makefile owns the expected device
names and OS versions. The resolver reads structured simulator inventories,
requires an available device with the complete expected name in the pinned
runtime and build, and checks that the App scheme lists its UDID as an available
destination. Duplicate names fail unless `VERIFIED_SIMULATOR_UDID` selects one
valid device explicitly.

The functional matrix passes both preflight IDs as
`VERIFIED_SIMULATOR_UDID` and `VERIFIED_IPAD_SIMULATOR_UDID`. Each Make target
rechecks the destinations it uses before invoking `xcodebuild` with the verified
UDID. The logs record the expected and resolved names, runtime identifier and
build, UDID, and executed command. A device that becomes unavailable causes the
invocation to fail.

The App matrix copy runs `make destination-test` and `make clean-test` for the
host regression suites. The destination suite uses synthetic inventories and
records commands received at the execution boundary, including all four
functional Make targets. Neither suite creates, erases, or modifies simulators.

## 5. Changing the selection

The suite selectors and canonical destination are defined once near the top of
the Makefile. When adding or removing a snapshot suite, update both the Makefile
selector and this document, then verify executed and skipped counts from a fresh
`xcresult` bundle.

## 6. Baseline local qualification (2026-11-09)

The separated privacy candidate passed its local gates on 2026-11-09 with
Xcode 27.2 release build `27B52` and the iOS 27.2 runtime build `24B8117`.
`make lint` exited 0 with four SwiftLint analysis passes over 146 files and no
violations. `make build` exited 0 for Debug iPhone, Release iPhone, and Debug
iPad. `make test` passed 79 App tests and 450 ApplicationFoundation tests on
iPhone 17 simulator `5427190A-1362-49FA-9294-7D3DB219EAC0`; its iPad invocation
passed one parameterized sentinel-occlusion test with both compact and regular
arguments on iPad Pro 11-inch (M5), `EF3E9282-D537-4E4A-953E-E21DBBD838DB`.
`make test-snapshots` passed 5 App snapshots and 34 ApplicationFoundation
snapshots on that iPad. Snapshot recording was set to `never`. Logs and result
bundles are preserved under the Qwizlab qualification directory.

The pre-correction candidate at `636bf7687f9fca95fa3dce94b23e874144f4a1b7`
passed CI run [42774304680](https://github.com/danielbyon/media-vault/actions/runs/42774304680).
The iOS test job passed 79 App tests, 452 ApplicationFoundation tests, and the
iPad privacy test. The initial snapshot attempt stopped before XCTest connected
to the simulator because the runner hung during launch; it reported no snapshot
assertion failure. The successful rerun passed 5 App snapshots and 34
ApplicationFoundation snapshots. The workflow finished green. Its evidence
artifacts are [iPhone tests](https://github.com/danielbyon/media-vault/actions/runs/42774304680/artifacts/13744168171),
[initial snapshot attempt](https://github.com/danielbyon/media-vault/actions/runs/42774304680/artifacts/13744383108),
and [successful snapshot rerun](https://github.com/danielbyon/media-vault/actions/runs/42774304680/artifacts/13746151239).

The Debug configuration retains `DEVELOPMENT_TEAM = HSX7X97PF8` for owner
signing of physical-device builds. Simulator qualification does not rely on
this team setting, and it does not substitute for physical-device evidence.

## 7. Corrective local qualification (2026-11-10)

The PR #118 correction passed its local gates with Xcode 27.2 release build
`27B52` and the iOS 27.2 runtime build `24B8117`. `make lint` passed four
complete-corpus analyzer runs over 146 files with zero violations. `make build`
passed Debug iPhone, Release iPhone, and Debug iPad builds. `make test` passed
79 App tests and 452 ApplicationFoundation tests on iPhone 17; the canonical
iPad invocation passed the sentinel-occlusion test with both compact and
regular fixture parameters. `make test-snapshots` passed 5 App and 34
ApplicationFoundation snapshots on iPad Pro 11-inch (M5). Snapshot recording
was disabled and every comparison remained exact.

`VaultFeatureTests.globalLockFencesPendingBrowserProfileTransition` failed
against the pre-correction implementation: the lock state stayed at generation
1 and the adapter retired the existing context. It passed 1/1 after the
correction and again in `make test`. The
`BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testSettingsLockReturnsToCalculatorFromTopLevelAndBrowserSettings`
selector passed 1/1 on iPhone 17 and 1/1 on iPad Pro 11-inch (M5). It exercises
both Settings destinations on each device, asserts one visible Lock control,
activates it, and checks that the locked calculator replaces Settings.

The correction changed no snapshot references. CI run `42774304680` applies to
the pre-correction SHA `636bf7687f9fca95fa3dce94b23e874144f4a1b7`; it does not
qualify this correction. Corrective logs and result bundles are preserved in
the Qwizlab corrective-review evidence directory.

## Download continuation across privacy lock

Download transfer authority begins at an authenticated WebKit navigation-action or
navigation-response decision accepting a download. The single-use capability belongs
to the exact policy association, originating WebView, tab lifetime, and browsing profile.
An ordinary navigation or user tap does not grant this authority. A matching native
handoff may arrive after Lock without gaining content-access authority.

Privacy transitions synchronously conceal metadata and native presentations, revoke
content grants, and deny new admission. Pending and active admitted transfers continue
within their original authority. Reauthentication can reconcile retained work through
fresh verified grants; it cannot replay a stale presentation or resurrect a cancelled
transfer. Explicit cancellation, tab closure, confirmed profile replacement, and genuine
failures remain terminal boundaries.

Production scratch and ingestion staging retain Complete file protection and backup
exclusion. Completion verification waits when protected data is unavailable. The
[owner-approved protection boundary](https://github.com/danielbyon/media-vault/pull/111#issuecomment-6908629367)
permits durable acceptance while the app is privacy-locked and protected data remains
available. Actual device-lock protection may prevent native writing, verification, or
acceptance. Completion and acceptance are not guaranteed during that interval.

Only verified, durably accepted content receives a restart-recovery guarantee. A native
completion callback retained only in memory, an admission reservation, and a partial file
do not establish durable acceptance. Recovery must preserve accepted staging and resume
processing after authentication. A fresh process starts with an empty Downloads list.
Issue #123 owns any later investigation of Complete Unless Open protection; it is outside
this contract and is not a merge blocker under the approved protection boundary.

Supported ordinary downloads enter the shared ingestion pipeline automatically. Actual
content validation, exact-duplicate comparison, quota decisions, and final commit require
authentication. Duplicate downloads default to the existing canonical asset. Lock and an
operation-specific final commit claim have one atomic ordering: Lock prevents an unclaimed
commit, while a transaction claimed before Lock may finish its authorized disk work.

Capacity accounting separates four pending/active/cancelling writers, eight temporary
operations, and lightweight session Downloads rows. Accepted pending storage is limited to
2 GiB in total and 512 MiB per item, with a 512 MiB free-space admission floor. Native
cancellation is best effort, so qualification records any temporary write overshoot.
Imported rows release temporary-byte capacity and reference the canonical asset; discarding
such a row must never delete Library content. Cleanup failures never restore access.

Native Preview and Share use a protected temporary export when the accepted resource's
opaque storage name cannot identify its type. The export retains a suitable filename
extension, uses Complete protection and backup exclusion, and consumes temporary storage
capacity. It is created only for a currently authorized presentation. The accepted or
canonical source stays unchanged; session-row retention does not retain an export copy.
Lock revokes the presentation URL immediately. An export acquired by UIKit remains private
until native absence is confirmed, then cleanup releases its capacity. Unacquired exports
can be removed without waiting for a native controller. Failed cleanup retains ownership
and capacity for retry.

Qualification must prove actual byte progress or completion after the privacy transition,
as well as the absence of application-requested cancellation. Deterministic capability
tests do not qualify physical WebKit execution. Finite UIKit assertions provide limited
execution time; they do not guarantee completion during suspension or after termination.
A separate finite-response fixture releases its remaining bytes after the real Root
background action locks the session. Its oracle correlates the policy capability, native
transfer, fixture connection, post-lock progress, finish, and hidden retained allocation.
The existing slow-known fixture keeps its original deadline and behavior.

`make test-browser-download-ui` selects 15 simulator-safe cases on the canonical
iPad: four `BrowserDownloadMultiSceneUITests` cases and eleven
`BrowserDownloadQualificationUITests` cases. The result checker requires all 15
exact identities to pass with no failures or skips. The physical continuation
selector and system-resize test are excluded. Simulator delayed-handoff coverage
uses a real accepted WebKit policy callback to Lock Root before native handoff;
it qualifies that callback ordering, not physical background execution.

Automatic-ingestion cases cover ordinary PNG completion, duplicate skip with a stable
canonical identity, PDF exclusion with native presentation, and accepted pending PNG
recovery after authenticated relaunch. A separate cold-authentication case checks the
DEBUG diagnostic readout's accessibility lifecycle without a download. Its subtree may
remount when credential visibility changes; the production Root and credential surfaces
keep their identities and concealment rules.

The earlier cancellation-based physical failures remain historical failures. Native
continuation, device-lock behavior, and protected-data recovery require source-bound
qualification on the revised implementation. A test-only Complete Unless Open experiment
cannot establish approval for a production protection change. Existing accessibility and
system-resize qualification dispositions remain separate.
