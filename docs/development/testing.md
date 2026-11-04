# Test Gates

This repository has two test commands with different jobs. The iPhone command
checks functional behavior. The iPad command compares visual snapshots against
the committed 2x baseline. In CI, both commands are required gates.

## 1. iPhone functional gate

Run `make test`. The command uses `IPHONE_DESTINATION`, which defaults to
`platform=iOS Simulator,name=iPhone 17,OS=27.0`.

The App scheme includes both the `AppTests` and `AppHostedTests` test bundles.
`make test` skips the root surface snapshot suite and the hosted privacy snapshot
method with these selectors:

- `-skip-testing:AppTests/RootSurfaceSnapshotTests`
- `-skip-testing:'AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPrivacySnapshotsCoverLifecycleStates()'`

The ApplicationFoundation package scheme runs every test target except these
four snapshot suites:

1. `AppFeatureTests/VaultFeatureViewSnapshotTests`
2. `CalculatorFeatureTests/CalculatorViewSnapshotTests`
3. `MediaLibraryTests/MediaLibrarySnapshotTests`
4. `BrowserFeatureTests/BrowserViewSnapshotTests`

For the recorded candidate, the App `xcresult` reports 77 passed tests and the
ApplicationFoundation `xcresult` reports 446 passed tests. Check each generated
`xcresult` rather than relying on a zero exit status. A selection mistake can
omit tests while the command still succeeds.

`make all` runs `lint`, `build`, and `test`, so it includes the iPhone functional
gate. It does not run the snapshot suite. Snapshot evidence comes only from
`make test-snapshots`.

## 2. Two-times iPad snapshot gate

Run `make test-snapshots`. The command uses `SNAPSHOT_DESTINATION`, which
defaults to `IPAD_DESTINATION`:
`platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0`.

The canonical model is the iPad Pro 11-inch (M5) on iOS 27.0. The iPad mini
(A17 Pro) is available locally, but its availability on the `xcode-27` CI
runner is unverified. The implementation keeps one model for local and CI use
and does not switch models automatically.

The selected simulator reports:

- Runtime build: `24A434`
- Main-screen scale: `2.000000`
- Main-screen size: `1668` by `2420` pixels
- Model identifier: `iPad17,2`

The App scheme runs these selections:

1. `AppTests/RootSurfaceSnapshotTests`
2. One hosted privacy snapshot method.

The hosted privacy method is selected with:

`-only-testing:'AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPrivacySnapshotsCoverLifecycleStates()'`

The ApplicationFoundation scheme runs these four package snapshot suites:

1. `AppFeatureTests/VaultFeatureViewSnapshotTests`
2. `CalculatorFeatureTests/CalculatorViewSnapshotTests`
3. `MediaLibraryTests/MediaLibrarySnapshotTests`
4. `BrowserFeatureTests/BrowserViewSnapshotTests`

For the recorded candidate, the App `xcresult` reports 5 passed tests and the
ApplicationFoundation `xcresult` reports 32 passed tests. The App result
includes four root surface snapshots and the hosted privacy snapshot. The
privacy test is excluded from the iPhone functional gate and runs on the
canonical iPad destination.

The current inventory has 36 snapshot methods and 64 reference files: 60 PNG
files and 4 text files.

| Suite | Methods | PNG references | Text references |
| --- | ---: | ---: | ---: |
| `RootSurfaceSnapshotTests` | 4 | 3 | 1 |
| `VaultFeatureViewSnapshotTests` | 6 | 6 | 0 |
| `CalculatorViewSnapshotTests` | 8 | 8 | 0 |
| `MediaLibrarySnapshotTests` | 6 | 3 | 3 |
| `BrowserViewSnapshotTests` | 11 | 24 | 0 |
| `ScenePrivacyCoverTests` | 1 | 16 | 0 |

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

Source qualification records, original reference hashes, and comparison
manifests remain external evidence and are not test inputs. The 2x baseline
migration did not change snapshot precision, tolerance, or rendering
configuration.

The hosted test checks the privacy state and renders the attached UIKit window
hierarchies, including the primary decoy and scene cover. It posts
`UIScene` lifecycle notifications through `NotificationCenter` and uses an
injected clock for expiry cases. The window presentation runs in process, while
the lifecycle notifications are synthetic. These captures do not exercise the
operating system's background and suspension path or qualify physical-device
lifecycle behavior. TAC-3 and TAC-4 still require separate device evidence. A
background notification or observed process identifier does not establish OS
suspension. Accessibility qualification is tracked separately under Issue #59.

Snapshot recording remains disabled by
`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never`, so a missing reference fails instead
of being created. The hosted privacy test uses the same exact snapshot
comparison policy. Do not record or replace references from a failing run;
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

If the `xcode-27` runner does not have the iPad Pro 11-inch (M5) iOS 27.0
destination, the snapshot job fails and therefore the `Tests` workflow fails.
Its logs and result bundle are preserved for diagnosis.

## 5. Changing the selection

The suite selectors and canonical destination are defined once near the top of
the Makefile. When adding or removing a snapshot suite, update both the Makefile
selector and this document, then verify executed and skipped counts from a fresh
`xcresult` bundle.
