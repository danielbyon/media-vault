# Test Gates

Local and CI test gates require Xcode 27.2 release build `27B52` and the iOS
27.2 simulator runtime build `24B8117`. The toolchain wrapper checks both before
running a command and stops if either is missing. It does not download simulator
runtimes. CI also records the runner image, source revision, and selected
simulator UDID.

This repository has two test commands with different jobs. The iPhone command
checks functional behavior. The iPad command compares visual snapshots against
the committed 2x baseline. In CI, both commands are required gates.

## Privacy test layers

Privacy coverage uses three layers so UIKit protection does not depend on
pixel-perfect full-window images.

| Layer | Purpose and coverage | Command |
| --- | --- | --- |
| A. Policy and session state | `ScenePrivacyCoverPolicyTests`, `RootFeatureTests`, and `VaultShellFeatureTests.navigationStateTracksTabsAndSettings` cover policy transitions, lock timing, cancellation, verification ordering, expired returns, tab selection, and Settings state transitions with deterministic state and clocks. | `make test` |
| B. UIKit protection behavior | App-hosted `ScenePrivacyCoverTests` exercise the real `RootView`, TCA store, scene, primary window, calculator decoy, and separate cover window. The hosted suites check attachment, occlusion, hit-test and accessibility isolation, reveal ordering, expiry, and cleanup in compact and regular layouts without image comparisons. They inspect hit-test routing and interaction properties; they do not execute touch delivery through the cover. `BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testAuthenticatedShellTabsAreAccessibleAndChangeDestinations` checks Collections, Browser, and Library navigation; it runs separately and does not establish the two-layout privacy fixture matrix. | `make test` for hosted behavior; separate `BrowserTabOverviewUITests` selectors below |
| C. Native presentation snapshots | SnapshotTesting compares production calculator and Library content at compact and regular sizes. Locked and expired states share calculator references; authenticated and resumed states share Library references. The shell's rendered controls are covered by Layer B. Separate calculator snapshots cover the overlay's glyphs, keys, colors, and layout. Comparisons are exact. | `make test-snapshots` |

`make test` runs Layer A and the hosted UIKit tests in Layer B, and skips image
snapshot methods. The shell navigation and Lock-control UI tests run in the
separate `BrowserTabOverviewUITests` scheme. `make test-snapshots` runs Layer C
with the repository's other visual suites. The legacy full-window lifecycle
snapshot method stays selected until replacement coverage passes.

The hosted privacy behavior tests cover compact and regular fixtures in make test. Shell-control UI tests run in the separate BrowserTabOverviewUITests scheme.

Layer B privacy fixtures use 320x568 compact and 1024x1366 regular dimensions.
BrowserTabOverviewUITests use simulator-default geometry and do not assert a compact/regular trait pair. Layer C regular content snapshots use the 834x1194 iPad Pro fixture.
These regular-width layouts are distinct dimensions for separate test layers.

### Legacy privacy coverage migration

The legacy privacy tests and 16 lifecycle references remain selected. The new
content references add coverage without replacing those identities. The tables
map every legacy assertion group and snapshot group to Layers A, B, or C.
`Source present` means the candidate contains the named test. It does not mean
that test ran.
The evidence-status column records whether the test ran and whether its
required negative controls completed.

The retirement gates are:

- `A/B gate`: focused Layer A and B runs pass in compact and regular fixtures;
  assertions cover cover-window visibility, accessibility, same-scene level
  above the primary window, direct hit-testing into visible interactive cover
  content, and protected-sentinel occlusion; the alpha-zero decoy mutation
  fails; and the full ApplicationFoundation and App functional gates report
  positive executed counts.
- `C gate`: the four hosted content references and two calculator reference
  images are present and reviewed; strict replay then passes on the canonical
  2x iPad destination; mutation checks fail when calculator or Library content
  changes; and the full snapshot gate reports positive executed counts.

| Legacy assertion group | Layer | Replacement test or identity | Coverage | Evidence status | Retirement gate |
| --- | --- | --- | --- | --- | --- |
| `coveredSceneInstallsSceneBoundBarrier` | A, B | `ScenePrivacyCoverPolicyTests.activeSceneFollowsCallerCoverageUpdates`; `coveredSceneInstallsSceneBoundBarrier`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel`; `BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testAuthenticatedShellTabsAreAccessibleAndChangeDestinations` | Policy state, cover-window contract, modal accessibility, same-scene cover level above the primary window, direct hit-testing to visible interactive cover content, and shell actions in the UI-test simulator's default layout. The touch-delivery path is not executed. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `hiddenCoverIsLaidOutBeforeFirstDeactivation` | B | `hiddenCoverIsLaidOutBeforeFirstDeactivation`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel`; `rootPrivacyReturnAndExpiryOrdering` through `expectRootPrivacyCoverAttached` | Initial cover attachment, hidden state, loaded controller, nonzero bounds and frames, accessibility traits, and layout before deactivation in both layouts. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `sceneWillDeactivateImmediatelyShowsPrimaryDecoy` | B | `sceneWillDeactivateImmediatelyShowsPrimaryDecoy`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Library and Browser decoy behavior, real-root Library coverage, cover visibility, and key-event capture of the fully covering decoy in both layouts. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `sceneDidEnterBackgroundImmediatelyShowsPrimaryDecoy` | B | `sceneDidEnterBackgroundImmediatelyShowsPrimaryDecoy`; `rootPrivacyReturnAndExpiryOrdering`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Background notification, cover visibility, sentinel occlusion, and return ordering for the real Library root in both layouts. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `calculatorFaceFitsCompactPhoneAndWideIPadLayouts` | B, C | `calculatorFaceFitsCompactPhoneAndWideIPadLayouts`; `ScenePrivacyCoverCalculatorSnapshotTests.compactPhoneSnapshot`; `ScenePrivacyCoverCalculatorSnapshotTests.regularIPadSnapshot` | Production calculator layout at compact and regular sizes. | Exact snapshots passed; the key-geometry mutation failed all 8 snapshots as expected. | `A/B gate` and `C gate` |
| `validatedCallerUpdateRevealsAfterInactiveCoverage` | A, B | `ScenePrivacyCoverPolicyTests.validatedUpdateAfterActivationRevealsScene`; `validatedCallerUpdateRevealsAfterInactiveCoverage`; `rootPrivacyReturnAndExpiryOrdering` | Validation ordering, cover presence before reveal, and post-activation reveal. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `coveredCallerUpdateBeforeWillDeactivateRemainsAcknowledged` | A, B | `ScenePrivacyCoverPolicyTests.coverageBeforeDeactivationAcknowledgesTransition`; `coveredCallerUpdateBeforeWillDeactivateRemainsAcknowledged` | Coverage acknowledged before deactivation and retained through the transition. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `staleUncoveredUpdateDoesNotRevealAfterActivation` | A, B | `ScenePrivacyCoverPolicyTests.staleUncoveredUpdateNeedsCoverageAcknowledgement`; `staleUncoveredUpdateDoesNotRevealAfterActivation` | A stale uncovered result cannot reveal without the required acknowledgement. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `validatedCallerUpdateBeforeActivationRevealsAfterActivation` | A, B | `ScenePrivacyCoverPolicyTests.validatedUpdateBeforeActivationWaitsForActivation`; `validatedCallerUpdateBeforeActivationRevealsAfterActivation` | A validated update remains covered until scene activation. | Passed in final local Layer A/B qualification. | `A/B gate` |
| `initiallyCoveredInactiveSceneWaitsForActivation` | A, B | `ScenePrivacyCoverPolicyTests.initiallyInactiveSceneWaitsForActivation`; `initiallyCoveredInactiveSceneWaitsForActivation` | Initial inactive coverage remains closed until activation and validation. | Passed in final local Layer A/B qualification. | `A/B gate` |

The eight rows below are the reference groups produced by
`rootPrivacySnapshotsCoverLifecycleStates`.

| Legacy lifecycle reference group | Layer | Replacement test or identity | Coverage | Evidence status | Retirement gate |
| --- | --- | --- | --- | --- | --- |
| Authenticated active primary window | B, C | `BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testAuthenticatedShellTabsAreAccessibleAndChangeDestinations`; `BrowserTabOverviewUITests/BrowserTabOverviewScrollUITests.testPersistentLockControlIsAccessibleAcrossAuthenticatedDestinations`; `root-content-v1-library-compact-iphone`; `root-content-v1-library-regular-ipad` | Root-content captures show authenticated Library content at compact and regular widths; separate UI tests exercise tab navigation and Lock control. | Strict root-content snapshots passed; the Library-control mutation failed the new root-presentation snapshot. The two focused UI tests passed separately. | `A/B gate` and `C gate` |
| Inactive protected primary window | B, C | `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel`; `root-content-v1-calculator-compact-iphone`; `root-content-v1-calculator-regular-ipad` | Pixel occlusion, same-scene cover level above the primary window, hit-test routing to a visible interactive cover descendant, and calculator content at both layouts. | The alpha-zero privacy mutation failed the alpha and private-pixel occlusion assertions; exact snapshots passed after restoration. | `A/B gate` and `C gate` |
| Inactive protected scene cover | B | `coveredSceneInstallsSceneBoundBarrier`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Cover visibility, key status, modal accessibility, cover level above the primary window, and direct hit-test routing in both layouts. | Layer B passed; the test checks cover level above the primary window and direct cover hit testing, not scene-wide ordering. | `A/B gate` |
| Background protected primary window | B | `rootPrivacyReturnAndExpiryOrdering`; `rootPrivacyCoverSynchronouslyOccludesPrivateSentinel` | Background grace, cover retention, sentinel occlusion, and primary-window state at both layouts. | Layer B and strict lifecycle snapshots passed; all 16 tracked lifecycle references are unchanged. | `A/B gate` |
| Background protected scene cover | B | `rootPrivacyReturnAndExpiryOrdering` | Cover remains visible and key during background grace and expiry at both layouts. | Layer B and strict lifecycle snapshots passed; all 16 tracked lifecycle references are unchanged. | `A/B gate` |
| Locked calculator decoy primary window | B, C | Calculator face checks; `root-content-v1-calculator-compact-iphone`; `root-content-v1-calculator-regular-ipad` | Production calculator content at both layouts. | The new native calculator snapshots failed 2/2 under the key-height mutation; the legacy calculator suite failed 8/8. | `A/B gate` and `C gate` |
| Resumed authenticated primary window | B, C | `rootPrivacyReturnAndExpiryOrdering`; `root-content-v1-library-compact-iphone`; `root-content-v1-library-regular-ipad` | Validated return ordering and Library content at both layouts. | The Import-control style mutation failed the root-presentation snapshot test; strict snapshots passed after restoration. | `A/B gate` and `C gate` |
| Expired return before authentication | B, C | `rootPrivacyReturnAndExpiryOrdering`; `root-content-v1-calculator-compact-iphone`; `root-content-v1-calculator-regular-ipad` | Expiry during cover, reveal ordering, and calculator content at both layouts. | Expiry and decoy behavior passed in Layer B; exact snapshots passed after restoration. | `A/B gate` and `C gate` |

The four new Layer C content identities are
`root-content-v1-calculator-compact-iphone`,
`root-content-v1-calculator-regular-ipad`,
`root-content-v1-library-compact-iphone`, and
`root-content-v1-library-regular-ipad`. Locked and expired states share the
calculator identity. Authenticated and resumed states share the Library
identity. Xcode 27.2 build 27B52 and iOS 27.2 build 24B8117 recorded the four
root-presentation references on the canonical 2x iPad Pro 11-inch (M5). Three
standalone strict replays passed before this final gate; the current full
snapshot gate also passed. The references and two calculator PNGs remain
untracked until candidate review. Layer A/B runs and the controlled mutation
checks passed. `make lint`, `make build`, `make test` (App 79/79;
ApplicationFoundation 450/450), and `make test-snapshots` (App 6/6;
ApplicationFoundation 34/34) passed on Xcode 27.2 and iOS 27.2, with snapshot
recording disabled. The separate focused BrowserTabOverviewUITests run passed
2/2. Controlled negatives detected a 48-to-56 point key-height change in both
native calculator snapshots (2/2 failed) and the legacy calculator suite (8/8
failed), alpha-zero decoy exposure through alpha and private-pixel assertions,
and an Import-control style change in the root-presentation snapshot. All
mutations were restored before these final gates. CI qualification and
publication remain pending.

## 1. iPhone functional gate

Run `make test`. The command uses `IPHONE_DESTINATION`, which defaults to
`platform=iOS Simulator,name=iPhone 17,OS=27.2`.

The App scheme includes both the `AppTests` and `AppHostedTests` test bundles.
`make test` skips the root surface snapshot suite and both hosted snapshot
methods. Their selectors are:

- `-skip-testing:AppTests/RootSurfaceSnapshotTests`
- `-skip-testing:'AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPrivacySnapshotsCoverLifecycleStates()'`
- `-skip-testing:'AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPresentationSnapshotsCoverPrimaryShellStates()'`

The ApplicationFoundation package scheme runs every test target except these
five snapshot suites:

1. `AppFeatureTests/VaultFeatureViewSnapshotTests`
2. `CalculatorFeatureTests/CalculatorViewSnapshotTests`
3. `MediaLibraryTests/MediaLibrarySnapshotTests`
4. `BrowserFeatureTests/BrowserViewSnapshotTests`
5. `PresentationSupportTests/ScenePrivacyCoverCalculatorSnapshotTests`

The original functional-gate baseline recorded 77 passing App tests and 446
passing ApplicationFoundation tests. These are baseline counts, not results
for the current candidate. Check each generated `xcresult` for a positive test
count; a selector that matches no tests can still exit successfully.

`make all` runs `lint`, `build`, and `test`, so it is the iPhone functional
gate. It does not run snapshot suites. Snapshot evidence comes from
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
2. The hosted privacy lifecycle snapshot method.
3. The hosted root presentation snapshot method.

The hosted privacy method is selected with:

`-only-testing:'AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPrivacySnapshotsCoverLifecycleStates()'`

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
which navigates among Collections, Browser, and Library. Its Lock-control test
checks accessibility across selected authenticated destinations. These UI
tests are outside `make test`; they do not prove the two-layout fixture matrix
or PAC-1/TAC-5, which remain deferred to Issue #59.
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
  test
```

The ApplicationFoundation scheme runs these five package snapshot suites:

1. `AppFeatureTests/VaultFeatureViewSnapshotTests`
2. `CalculatorFeatureTests/CalculatorViewSnapshotTests`
3. `MediaLibraryTests/MediaLibrarySnapshotTests`
4. `BrowserFeatureTests/BrowserViewSnapshotTests`
5. `PresentationSupportTests/ScenePrivacyCoverCalculatorSnapshotTests`

The prior snapshot baseline reported 5 App snapshot tests and 32
ApplicationFoundation snapshot tests. The hosted root method and calculator
suite add three selected test cases. Check `totalTestCount` in each result
bundle; a successful command with zero discovered tests is not snapshot
evidence.

Baseline HEAD contains 37 snapshot methods and 65 reference files: 61 PNG
files and 4 text files. The candidate adds one hosted root-presentation
method, a two-case calculator suite, four hosted content references, and two
calculator references. Its inventory is 40 methods and 71 reference files:
67 PNG files and 4 text files. The six added PNGs are in the candidate and
remain subject to owner review.

| Suite | Snapshot methods | PNG references | Text references |
| --- | ---: | ---: | ---: |
| `RootSurfaceSnapshotTests` | 4 | 3 | 1 |
| `VaultFeatureViewSnapshotTests` | 7 | 7 | 0 |
| `CalculatorViewSnapshotTests` | 8 | 8 | 0 |
| `MediaLibrarySnapshotTests` | 6 | 3 | 3 |
| `BrowserViewSnapshotTests` | 11 | 24 | 0 |
| `ScenePrivacyCoverCalculatorSnapshotTests` | 2 | 2 | 0 |
| `ScenePrivacyCoverTests` | 2 | 20 | 0 |

The 44 PNG references from the original baseline migration use the 2x rendering
scale for the canonical destination. That migration replaced all 44 PNG
references with suite-and-method paths and preserved the four text references.
The 44 migrated images were checked against the prior 3x references for the
expected 1.5x pixel-scale relationship and layout-equivalent content. The 16 hosted
privacy references cover these states and windows at compact and regular-width
layouts. The compact-phone references are captured as compact-layout fixtures
by the canonical iPad snapshot run:

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
authenticated and resumed states share Library references. Keep the original
16 lifecycle references unchanged while replacement coverage is qualified.
Retire them only after that coverage passes.

Reference ownership follows the test target: hosted root images belong under
`AppHostedTests/__Snapshots__/ScenePrivacyCoverTests/`, and calculator view
images belong under
`Packages/ApplicationFoundation/Tests/PresentationSupportTests/__Snapshots__/ScenePrivacyCoverCalculatorSnapshotTests/`.
The original 16 hosted lifecycle images remain owned by the legacy method until
replacement coverage passes.

Source qualification records, original reference hashes, and comparison
manifests remain external evidence and are not test inputs. The 2x baseline
migration did not change snapshot precision, tolerance, or rendering
configuration.

The `rootPrivacySnapshotsCoverLifecycleStates` method remains selected and
compares attached UIKit window captures with the 16 original lifecycle
references. Those references remain unchanged. Layer B's occlusion sentinel,
hit-test routing, and reveal-ordering tests verify real UIKit cover behavior
in both layouts. Layer C
snapshots production calculator and Library content through SnapshotTesting's
native SwiftUI strategy. The separate calculator suite tests the production
UIKit calculator view; it does not substitute a SwiftUI mock. Snapshot
comparisons remain exact.

The tests post `UIScene` lifecycle notifications through `NotificationCenter`
and use an injected clock for expiry cases. These notifications are synthetic:
they do not exercise the operating system's background and suspension path or
qualify physical-device lifecycle behavior. TAC-3 and TAC-4 still require
separate device evidence. A background notification or observed process
identifier does not establish OS suspension. Accessibility qualification is
tracked separately under Issue #59.

Snapshot recording remains disabled by
`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never`, so a missing reference fails instead
of being created. Both hosted snapshot methods use this exact comparison
policy.
Do not record or replace references from a failing run;
candidate actual, reference, and difference images belong in external
comparison evidence.

## 3. Result bundles and failure handling

`TEST_RESULTS_DIRECTORY` is optional. When set, each test invocation writes an
`xcresult` bundle below the temporary test root and copies it into the external
directory before the temporary root is removed. When unset, result bundles stay
inside the temporary root and are deleted with the rest of the build artifacts.

After each `xcodebuild test` invocation, the Makefile reads that scheme's own
bundle with `xcresulttool get test-results summary --path <bundle> --compact`.
A missing or unreadable bundle, a summary without `totalTestCount`, and a zero
count each produce a distinct explicit diagnostic and mark the command as
failed. `make test` stops at its first failure.

`make test-snapshots` runs both schemes even when the first scheme fails. It
records each scheme's `xcodebuild` status and result-bundle validation status
independently, attempts validation for both bundles regardless of either
`xcodebuild` result, and reports every failure category it observed. The target
exits nonzero when any status fails; a later passing scheme cannot clear an
earlier failure. Preserved `xcresult` bundles remain the source for the
per-scheme executed counts.

`make test` validates each bundle immediately after that scheme's test
command, so a validation failure stops the target before the second scheme
starts. `make test-snapshots` also validates each bundle immediately after its
scheme's test command, but a validation failure does not stop the second scheme;
it records the failure and continues. The target reports every failure it
observed.

Both snapshot `xcodebuild test` commands set
`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never`. `TEST_RUNNER_` is Xcode's
test-runner environment propagation prefix, and the test process receives the
suffix as `SNAPSHOT_TESTING_RECORD=never`. SnapshotTesting therefore fails when
an expected reference is missing instead of creating one. A comparison failure
against an existing reference still fails and still attaches its actual,
reference, and difference artifacts to the result bundle. Neither behavior
replaces a tracked reference.

## 4. Continuous integration

`.github/workflows/tests.yml` defines two jobs.

1. `test`, named `iOS tests`, is the blocking gate. It runs `make test` on the
   iPhone destination and has no `continue-on-error` setting.
2. `snapshot-qualification`, named
   `Snapshot qualification (2x iPad)`, runs `make test-snapshots` on the 2x iPad
   destination. It has no `continue-on-error` setting, so a snapshot mismatch,
   build failure, simulator failure, or timeout fails the job and the `Tests`
   workflow.

The blocking job passes `TEST_RESULTS_DIRECTORY` so both iPhone bundles survive
the run, and an `if: always()` step uploads them as the `iphone-test-evidence`
artifact. A missing bundle is reported as a warning, and an upload failure does
not change the test step outcome or the blocking gate.

The two jobs are separate so their time budgets are independent. The snapshot
job has a 60-minute job timeout and a 45-minute timeout on the test step, so a
hung snapshot run cannot consume the iPhone job's time budget, and the snapshot
outcome is visible on its own job. The snapshot job is also a required gate. A
failed command can mean a reference mismatch, a build error, an unavailable
simulator destination, or a timeout; inspect its artifact or job log before
attributing a cause. The job's final step reports the observed step outcomes to
the workflow run summary and deliberately stays cause-neutral.

A passing snapshot command confirms that the committed 2x references match in
the automated run and that both schemes recorded positive test counts. It does
not constitute final owner visual approval; that approval is a separate
acceptance decision.

The snapshot job preserves evidence on failure. The test step passes
`TEST_RESULTS_DIRECTORY` so each `xcresult` bundle is copied out of the
temporary test root, and the upload step runs with `if: always()` to publish the
`2x-ipad-snapshot-evidence` artifact. The step timeout is shorter than the job
timeout so a hung test run still reaches that upload step. A missing artifact is
reported as a warning, and a skipped job or missing artifact must not be read as
snapshot qualification.

If the `xcode-27` runner does not have the iPad Pro 11-inch (M5) iOS 27.2
destination, the snapshot job fails and therefore the `Tests` workflow fails.
The preflight also requires Xcode 27.2 build `27B52` and runtime build
`24B8117`. Its logs and result bundle are preserved for diagnosis.

Each CI job resolves its own simulator UDID through `make verify-test-destination`
or `make verify-snapshot-destination`. The Makefile owns the expected device names
and OS versions. The resolver reads structured simulator inventories, requires an
available device with the complete expected name in the pinned runtime and build,
and checks that the App scheme lists its UDID as an available destination. Duplicate
names fail unless `VERIFIED_SIMULATOR_UDID` selects one valid device explicitly.

CI passes the preflight step's `simulator_udid` output to the test Make target as
`VERIFIED_SIMULATOR_UDID`. Local runs resolve once at the start of the target. Both
schemes reuse that identity. Before each test invocation, the helper checks the
intended scheme's destinations and rechecks simulator availability, then executes
`xcodebuild -destination 'platform=iOS Simulator,id=<verified-UDID>'`. Its log records
the expected and resolved names, runtime identifier and build, UDID, and executed
command. A device that becomes unavailable causes that invocation to fail.

Run `make destination-test` for the host regression suite. It uses synthetic
inventories and records the commands received at the execution boundary, including
both Make test targets. It does not create, erase, or modify simulators.

## 5. Changing the selection

The suite selectors and canonical destination are defined once near the top of
the Makefile. When adding or removing a snapshot suite, update both the Makefile
selector and this document, then verify executed and skipped counts from a fresh
`xcresult` bundle.
