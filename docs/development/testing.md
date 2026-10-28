# Test Gates

This repository has two test commands with different jobs. The iPhone command
checks functional behavior. The iPad command captures visual snapshot evidence.
A green iPhone run does not qualify visual snapshots, and a failing snapshot run
is expected while the approved references still use a different rendering scale.

## 1. iPhone functional gate

Run `make test`. The command uses `IPHONE_DESTINATION`, which defaults to
`platform=iOS Simulator,name=iPhone 17,OS=27.0`.

The App scheme includes both the `AppTests` and `AppHostedTests` test bundles.
`make test` passes `-skip-testing:AppTests/RootSurfaceSnapshotTests`, so the
root surface snapshot suite does not run and the App scheme executes the 66
`AppHostedTests` methods. The ApplicationFoundation package scheme runs every
test target except these four snapshot suites:

1. `AppFeatureTests/VaultFeatureViewSnapshotTests`
2. `CalculatorFeatureTests/CalculatorViewSnapshotTests`
3. `MediaLibraryTests/MediaLibrarySnapshotTests`
4. `BrowserFeatureTests/BrowserViewSnapshotTests`

The current selection is expected to execute 464 non-snapshot methods: 66 in
`AppHostedTests` and 398 in the package. Verify the count from the generated
`xcresult` bundle rather than relying on a zero exit status. A selection mistake
can omit tests while the command still succeeds.

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

The command runs only these five suites, across both the App and
ApplicationFoundation schemes:

1. `AppTests/RootSurfaceSnapshotTests`
2. `AppFeatureTests/VaultFeatureViewSnapshotTests`
3. `CalculatorFeatureTests/CalculatorViewSnapshotTests`
4. `MediaLibraryTests/MediaLibrarySnapshotTests`
5. `BrowserFeatureTests/BrowserViewSnapshotTests`

The current inventory is 35 snapshot methods and 48 reference files: 44 PNG
files and 4 text files.

| Suite | Methods | PNG references | Text references |
| --- | ---: | ---: | ---: |
| `RootSurfaceSnapshotTests` | 4 | 3 | 1 |
| `VaultFeatureViewSnapshotTests` | 6 | 6 | 0 |
| `CalculatorViewSnapshotTests` | 8 | 8 | 0 |
| `MediaLibrarySnapshotTests` | 6 | 3 | 3 |
| `BrowserViewSnapshotTests` | 11 | 24 | 0 |

The approved PNG references were captured at 3x, so a 2x run on the canonical
destination makes a PNG mismatch plausible: the reference images encode a
different rendering scale. Plausibility is not proof. A build error, an
unavailable simulator destination, or a timeout fails the same command, so a
given run's failures must be read from its `xcresult` bundle or log before
they are attributed to reference mismatch.

A 2x run executed on 2026-10-27 on the canonical destination, an iPad Pro
11-inch (M5) running iOS 27.0 build `24A434`, ran 35 snapshot methods and
recorded 44 PNG assertion mismatches while the 4 text snapshots passed. This
describes that run only: it does not predict the outcome of any later run, does
not attribute a cause to the mismatches, and is not a qualified visual baseline.
It identifies the references that need owner approval before candidate 2x
images can replace them. That run used Makefile `01d3d8…` and workflow
`de39…`.

The final source freeze (Makefile `5f7fbb…`, workflow `6697cd3…`) was rerun on
2026-10-28 with
`XCODEBUILD_OPTIONS='-skipMacroValidation -collect-test-diagnostics never'`.
That value overrides the Makefile default `-skipMacroValidation`. That rerun
used the same selector and destination, again executed 35 snapshot
methods, and recorded 44 PNG assertion mismatches, with the same SnapshotTesting
image attachments. The override suppresses XCTest sysdiagnostics, not
SnapshotTesting mismatch attachments. CI runs `make test-snapshots` without
setting `XCODEBUILD_OPTIONS`, so it uses the default `-skipMacroValidation`; the
CI default remains unqualified.

Do not record or replace approved reference files from a failing run. Candidate
actual, reference, and difference images belong in external comparison evidence,
not in the tracked snapshot directories.

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
   `Snapshot qualification (2x iPad, non-blocking)`, runs `make test-snapshots`
   on the 2x iPad destination. It is marked `continue-on-error: true`, so its
   result cannot fail the workflow run or the blocking iPhone job.

The blocking job passes `TEST_RESULTS_DIRECTORY` so both iPhone bundles survive
the run, and an `if: always()` step uploads them as the `iphone-test-evidence`
artifact. A missing bundle is reported as a warning, and an upload failure does
not change the test step outcome or the blocking gate.

The two jobs are separate so their time budgets are independent. The snapshot
job has a 60-minute job timeout and a 45-minute timeout on the test step, so a
hung snapshot run cannot consume the iPhone job's time budget, and the snapshot
outcome is visible on its own job. Because the approved references are still
the 3x set, a PNG reference mismatch is a plausible outcome of the snapshot job,
and the 2026-10-27 run described in section 2 recorded 44 PNG assertion
mismatches. Neither observation predicts a later run: a build error, an
unavailable simulator destination, or a timeout fails the same step, so each
snapshot job result requires inspection of its artifact or job log before a
failure is attributed to reference mismatch.
The job name states that it is non-blocking, and its final step reports the
observed step outcomes to the workflow run summary. That summary deliberately
stays cause-neutral: it does not label a generic failure as a reference
mismatch or attribute a cause to any failure.

A passing snapshot command means only that the command exited zero and recorded
positive test counts; it does not qualify the snapshots. Visual review of the
recorded images and owner approval of a 2x reference set remain pending.

The snapshot job preserves evidence on failure. The test step passes
`TEST_RESULTS_DIRECTORY` so each `xcresult` bundle is copied out of the
temporary test root, and the upload step runs with `if: always()` to publish the
`2x-ipad-snapshot-evidence` artifact. The step timeout is shorter than the job
timeout so a hung test run still reaches that upload step. A missing artifact is
reported as a warning, and a skipped job or missing artifact must not be read as
snapshot qualification.

If the `xcode-27` runner does not have the iPad Pro 11-inch (M5) iOS 27.0
destination, the snapshot job fails without blocking the iPhone gate. Its logs
and result bundle are preserved for diagnosis.

## 5. Changing the selection

The suite selectors and canonical destination are defined once near the top of
the Makefile. When adding or removing a snapshot suite, update both the Makefile
selector and this document, then verify executed and skipped counts from a fresh
`xcresult` bundle.
