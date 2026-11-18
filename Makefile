SHELL := /bin/bash

XCODE_WRAPPER := ./Scripts/with-xcode-27.2.sh
DESTINATION_VERIFIER := ./Scripts/verify-xcode-27.2-destination.sh
# CI may supply verified device IDs; local runs resolve one per destination.
VERIFIED_SIMULATOR_UDID ?=
VERIFIED_IPAD_SIMULATOR_UDID ?=
# xcodebuild cannot present first-use trust prompts in this noninteractive gate.
XCODEBUILD_OPTIONS := -skipMacroValidation
IPHONE_DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=27.2
IPAD_DESTINATION ?= platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.2
# Canonical snapshot destination. The iPad mini was considered, but its
# availability on the xcode-27 CI runner is unverified. Local and CI runs use
# one model consistently: iPad Pro 11-inch (M5), iOS 27.2, at 2x scale.
SNAPSHOT_DESTINATION ?= $(IPAD_DESTINATION)
# Focused native-scale qualification keeps its own destination and build root.
NATIVE_SNAPSHOT_DESTINATION ?= $(IPHONE_DESTINATION)
NATIVE_SNAPSHOT_EXPECTED_SCALE ?= 3
NATIVE_SNAPSHOT_BUILD_DIRECTORY ?= $(CURDIR)/.build
# Snapshot suites are kept out of the iPhone gate. The App scheme owns the root
# surface and hosted privacy-presentation snapshots; the package scheme owns five snapshot suites.
APP_SNAPSHOT_SUITE := AppTests/RootSurfaceSnapshotTests
APP_HOSTED_ROOT_PRESENTATION_SNAPSHOT_TEST := AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPresentationSnapshotsCoverPrimaryShellStates
APP_HOSTED_PRIVACY_OCCLUSION_TEST := AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/rootPrivacyCoverSynchronouslyOccludesPrivateSentinel(_:)
BROWSER_DOWNLOAD_MULTI_SCENE_TESTS := \
	BrowserDownloadMultiSceneUITests/testRequestCreatesNewMountedWindowGroupScene \
	BrowserDownloadMultiSceneUITests/testSceneRequestRevokesCompletedDownloadAndKeepsActiveRootUsable \
	BrowserDownloadMultiSceneUITests/testResizeHandleNormalizesMeasuredRotatedFrame \
	BrowserDownloadMultiSceneUITests/testResizeHandleRejectsUnrelatedOffscreenFrame \
	BrowserDownloadMultiSceneUITests/testResizeHandleUsesScreenSpaceOriginWithOffsetCard \
	BrowserDownloadMultiSceneUITests/testResizeGestureDeltaMovesOutwardPerAvailableAxis \
	BrowserDownloadMultiSceneUITests/testResizeGestureDeltaShrinksFullScreenCardOnBothAxes \
	BrowserDownloadMultiSceneUITests/testResizeWindowSelectionAllowsVisibleNonKeyedAuxiliaryWindow \
	BrowserDownloadMultiSceneUITests/testResizeWindowSelectionRejectsVisibleCover \
	BrowserDownloadMultiSceneUITests/testResizeWindowSelectionRejectsZeroOrMultipleVisibleKeyedWindows \
	BrowserDownloadMultiSceneUITests/testResizeSceneRequiresUniqueNewActiveSession \
	BrowserDownloadMultiSceneUITests/testResizeTimeoutDiagnosticsReadOptionalValuesIndependently \
	BrowserDownloadMultiSceneUITests/testPassiveSceneCensusSelectsNewestWindowSnapshot \
	BrowserDownloadMultiSceneUITests/testPassiveSceneCensusRejectsConflictingSnapshotsAtSameTime \
	BrowserDownloadMultiSceneUITests/testLatestFreshSafeRootsRequiresEveryRegistrationAndUsesMonotonicTime \
	BrowserDownloadMultiSceneUITests/testReactivationOwnerSelectionAllowsSnapshotBetweenActivationAndCensus \
	BrowserDownloadMultiSceneUITests/testReactivationOwnerSelectionRejectsSnapshotBeforeActivation \
	BrowserDownloadMultiSceneUITests/testReactivationOwnerSelectionRejectsWrongRun \
	BrowserDownloadMultiSceneUITests/testReactivationOwnerSelectionRejectsWrongGeneration \
	BrowserDownloadMultiSceneUITests/testFinalCensusGenerationRejectsNewerUnsafeObservation \
	BrowserDownloadMultiSceneUITests/testFinalCensusGenerationRejectsNewerObservationWithoutGeneration \
	BrowserDownloadMultiSceneUITests/testReactivationOwnerSelectionRejectsSnapshotAfterCensus \
	BrowserDownloadMultiSceneUITests/testReactivationOwnerSelectionAcceptsInclusiveBoundaries \
	BrowserDownloadMultiSceneUITests/testReactivationOwnerSelectionRejectsNonFiniteTimestamps \
	BrowserDownloadMultiSceneUITests/testReactivationOwnerSelectionUsesLatestObservationWithinInterval \
	BrowserDownloadMultiSceneUITests/testReactivationAvailabilityRejectsMismatchWithFinalRegisteredScenes \
	BrowserDownloadMultiSceneUITests/testResizeGestureMarkerSelectsExactNewSceneRegistrationAndRun \
	BrowserDownloadMultiSceneUITests/testResizeWindowWitnessAcceptsMarkerOnlyLatestObservation \
	BrowserDownloadMultiSceneUITests/testResizeWindowWitnessRejectsCoverInCurrentCensus \
	BrowserDownloadMultiSceneUITests/testResizeWindowWitnessPreservesSelectedWindowGeometryAndPrivacy
# Simulator-safe single-scene continuation, presentation, and witness regressions.
# Physical Home continuation remains a separately authorized device qualification.
BROWSER_DOWNLOAD_QUALIFICATION_TESTS := \
BrowserDownloadQualificationUITests/testAcceptedPolicyHandoffAfterLockCompletesHiddenUntilFreshAuthentication \
BrowserDownloadQualificationUITests/testDelayedHandoffParserRequiresNativeCallbacksAfterLock \
BrowserDownloadQualificationUITests/testQuickLookHomeRevokesAndFreshDownloadRecovers \
BrowserDownloadQualificationUITests/testShareHomeRevokesAndFreshDownloadRecovers \
BrowserDownloadQualificationUITests/testNormalQualificationModeReturnsToAuthenticatedBrowserAfterHome \
BrowserDownloadQualificationUITests/testActiveDownloadQualificationModeAutoLocksAfterRealHomeTransition \
BrowserDownloadQualificationUITests/testSlowKnownWitnessAcceptsCorrelatedNativeProgress \
BrowserDownloadQualificationUITests/testSlowKnownWitnessRejectsMissingHandoffOrProgress \
BrowserDownloadQualificationUITests/testSlowKnownWitnessRejectsStaleRunOrUnrelatedOperation \
BrowserDownloadQualificationUITests/testSlowKnownWitnessRejectsServerEvidenceAfterReadiness \
BrowserDownloadQualificationUITests/testSlowKnownWitnessRejectsEarlyTerminalAndCleanupFailure \
BrowserDownloadQualificationUITests/testSlowKnownWitnessRejectsPrematureCleanupWithoutFixtureRequest \
BrowserDownloadQualificationUITests/testSlowKnownWitnessIgnoresPrematureCleanupForAnotherOperation \
BrowserDownloadQualificationUITests/testSlowKnownWitnessIgnoresPrematureCleanupFromAnotherRun \
BrowserDownloadQualificationUITests/testContinuationAcceptsFiniteResponseAndNativeFinish \
BrowserDownloadQualificationUITests/testContinuationRejectsMissingNativeOrTransportWitness \
BrowserDownloadQualificationUITests/testContinuationRejectsCancellationFailureAndPrematureCleanup \
BrowserDownloadQualificationUITests/testContinuationRejectsWrongCorrelationEarlyReleaseAndVisibleCompletion \
BrowserDownloadQualificationUITests/testSlowKnownWitnessDiagnosticsAreRedactedAndBounded \
BrowserDownloadQualificationUITests/testSlowKnownDownloadControlIsAccessibleOnMountedBrowser \
BrowserDownloadQualificationUITests/testActiveDiscardFailureRetryAndAuthenticationLoss \
BrowserDownloadQualificationUITests/testOrdinaryPNGDownloadAutomaticallyCommitsCanonicalAsset \
BrowserDownloadQualificationUITests/testRepeatedPNGDownloadSkipsDuplicateAndRetainsCanonicalIdentity \
BrowserDownloadQualificationUITests/testPDFDownloadRemainsOutsideLibraryAndKeepsNativePresentation \
BrowserDownloadQualificationUITests/testAcceptedPNGWhileLockedReconcilesAfterAuthenticatedRelaunch \
BrowserDownloadQualificationUITests/testColdLockedAuthenticationKeepsDiagnosticReadoutAccessible
PACKAGE_SNAPSHOT_SUITES := \
	AppFeatureTests/VaultFeatureViewSnapshotTests \
	CalculatorFeatureTests/CalculatorViewSnapshotTests \
	MediaLibraryTests/MediaLibrarySnapshotTests \
	BrowserFeatureTests/BrowserViewSnapshotTests \
	PresentationSupportTests/ScenePrivacyCoverCalculatorSnapshotTests
# Optional directory for xcresult bundles. Configured bundles are written here
# directly so preservation does not depend on an exit-time copy. DerivedData
# stays in its separate temporary root.
TEST_RESULTS_DIRECTORY ?=
# Temporary Xcode build and test roots; use task-specific storage when needed.
XCODE_BUILD_ROOT ?= $(CURDIR)/.build
# Xcode generates this aggregate scheme and its test action from Package.swift.
PACKAGE_WORKSPACE := Packages/ApplicationFoundation/.swiftpm/xcode/package.xcworkspace
PACKAGE_SCHEME := ApplicationFoundation-Package
# Share one package checkout cache across runs so isolated DerivedData
# directories do not clone dependencies again. Only package sources are
# shared; build products stay in the per-run temporary DerivedData directory.
SOURCE_PACKAGES_DIRECTORY := $(CURDIR)/.build/SourcePackages
# Recipes resolve helper paths from the Makefile selected by make. This
# top-level Makefile has no included files, so MAKEFILE_LIST contains one path;
# preserving it as quoted text supports checkout paths containing spaces. The
# cleanup helper rejects invocation outside its owning checkout before
# inspecting any artifact.

.PHONY: all build clean clean-test destination-test format lint lint-analyze test test-snapshots test-native-snapshots tools verify-test-destination verify-snapshot-destination

all: lint build test

tools:
	bash ./Scripts/swift-tools.sh bootstrap

format: tools
	bash ./Scripts/swift-tools.sh format

# Build and test run against a temporary DerivedData directory that the recipe
# removes on exit. A later run receives a fresh path. A directory left behind by
# a killed run is preserved for inspection and is not inferred to be Make-owned.
build:
	@set -euo pipefail; \
	mkdir -p "$(CURDIR)/.build" "$(XCODE_BUILD_ROOT)"; \
	derived_data=$$(mktemp -d "$(XCODE_BUILD_ROOT)/xcodebuild-build.XXXXXX"); \
	trap 'rm -rf -- "$$derived_data"' EXIT; \
	trap 'exit 143' TERM INT; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Release -destination '$(IPHONE_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build; \
	$(XCODE_WRAPPER) xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -destination '$(IPAD_DESTINATION)' -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$derived_data" build

test:
	@set -euo pipefail; \
	simulator_udid=$$($(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPHONE_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)' | tail -n 1); \
	ipad_simulator_udid=$$($(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPAD_DESTINATION)' '$(VERIFIED_IPAD_SIMULATOR_UDID)' | tail -n 1); \
	mkdir -p "$(CURDIR)/.build" "$(XCODE_BUILD_ROOT)"; \
	test_root=$$(mktemp -d "$(XCODE_BUILD_ROOT)/xcodebuild-test.XXXXXX"); \
	result_root="$$test_root"; \
	if [[ -n "$(TEST_RESULTS_DIRECTORY)" ]]; then \
		mkdir -p "$(TEST_RESULTS_DIRECTORY)"; \
		result_root=$$(mktemp -d "$(TEST_RESULTS_DIRECTORY)/xcodebuild-test.XXXXXX"); \
	fi; \
	cleanup_test_build() { \
		status=$$?; \
		rm -rf -- "$$test_root"; \
		trap - EXIT; \
		exit "$$status"; \
	}; \
	trap cleanup_test_build EXIT; \
	trap 'exit 143' TERM INT; \
	assert_tests_ran() { \
		label="$$1"; bundle="$$2"; \
		if [[ ! -d "$$bundle" ]]; then \
			printf 'test results bundle missing for %s: %s\n' "$$label" "$$bundle" >&2; \
			return 1; \
		fi; \
		if ! summary=$$($(XCODE_WRAPPER) xcrun xcresulttool get test-results summary --path "$$bundle" --compact 2>&1); then \
			printf 'test results summary unreadable for %s: %s\n' "$$label" "$$bundle" >&2; \
			printf '%s\n' "$$summary" >&2; \
			return 1; \
		fi; \
		count=$$(printf '%s\n' "$$summary" | sed -n 's/.*"totalTestCount"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1); \
		if [[ -z "$$count" ]]; then \
			printf 'test results summary missing totalTestCount for %s: %s\n' "$$label" "$$bundle" >&2; \
			return 1; \
		fi; \
		if [[ ! "$$count" =~ ^[1-9][0-9]*$$ ]]; then \
			printf 'zero tests recorded for %s: %s totalTestCount=%s\n' "$$label" "$$bundle" "$$count" >&2; \
			return 1; \
		fi; \
		printf '%s: %s tests\n' "$$label" "$$count"; \
	}; \
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPHONE_DESTINATION)' "$$simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/App" -resultBundlePath "$$result_root/App.xcresult" -skip-testing:$(APP_SNAPSHOT_SUITE) -skip-testing:'$(APP_HOSTED_ROOT_PRESENTATION_SNAPSHOT_TEST)()' test; \
	assert_tests_ran App "$$result_root/App.xcresult"; \
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPHONE_DESTINATION)' "$$simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace $(PACKAGE_WORKSPACE) -scheme $(PACKAGE_SCHEME) -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/ApplicationFoundation" -resultBundlePath "$$result_root/ApplicationFoundation.xcresult" $(foreach suite,$(PACKAGE_SNAPSHOT_SUITES),-skip-testing:$(suite)) test; \
	assert_tests_ran ApplicationFoundation "$$result_root/ApplicationFoundation.xcresult"; \
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPAD_DESTINATION)' "$$ipad_simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/App-iPadPrivacy" -resultBundlePath "$$result_root/App-iPadPrivacy.xcresult" -parallel-testing-enabled NO -only-testing:'$(APP_HOSTED_PRIVACY_OCCLUSION_TEST)' test; \
	assert_tests_ran App-iPad-privacy "$$result_root/App-iPadPrivacy.xcresult"; \
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPAD_DESTINATION)' "$$ipad_simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme BrowserTabOverviewUITests -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/BrowserDownloadMultiScene" -resultBundlePath "$$result_root/BrowserDownloadMultiScene.xcresult" -parallel-testing-enabled NO $(foreach test,$(BROWSER_DOWNLOAD_MULTI_SCENE_TESTS) $(BROWSER_DOWNLOAD_QUALIFICATION_TESTS),-only-testing:BrowserTabOverviewUITests/$(test)) test; \
	$(XCODE_WRAPPER) python3 ./Scripts/assert-xcresult-tests.py --bundle "$$result_root/BrowserDownloadMultiScene.xcresult" --expected-device-id "$$ipad_simulator_udid" --expected-device-name 'iPad Pro 11-inch (M5)' --expected-os-version 27.2 $(foreach test,$(BROWSER_DOWNLOAD_MULTI_SCENE_TESTS) $(BROWSER_DOWNLOAD_QUALIFICATION_TESTS),--expected-test $(test))

# Exercise the native presentation snapshot suites on the canonical 2x iPad.
# UIKit lifecycle protection remains covered by behavioral tests in `make test`.
# Both schemes run even when the first suite fails so the complete failure
# inventory is available. The canonical 2x reference baseline is required, and
# exact snapshot comparisons must pass.
test-snapshots:
	@set -euo pipefail; \
	simulator_udid=$$($(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(SNAPSHOT_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)' | tail -n 1); \
	mkdir -p "$(CURDIR)/.build" "$(XCODE_BUILD_ROOT)"; \
	test_root=$$(mktemp -d "$(XCODE_BUILD_ROOT)/xcodebuild-snapshot-test.XXXXXX"); \
	result_root="$$test_root"; \
	if [[ -n "$(TEST_RESULTS_DIRECTORY)" ]]; then \
		mkdir -p "$(TEST_RESULTS_DIRECTORY)"; \
		result_root=$$(mktemp -d "$(TEST_RESULTS_DIRECTORY)/xcodebuild-snapshot-test.XXXXXX"); \
	fi; \
	cleanup_test_build() { \
		status=$$?; \
		rm -rf -- "$$test_root"; \
		trap - EXIT; \
		exit "$$status"; \
	}; \
	trap cleanup_test_build EXIT; \
	trap 'exit 143' TERM INT; \
	status=0; \
	failure_summary=""; \
	remember_failure() { \
		label="$$1"; \
		failure_status="$$2"; \
		if (( failure_status != 0 )); then \
			failure_summary+="$${label}=$${failure_status} "; \
			if (( status == 0 )); then \
				status=$$failure_status; \
			fi; \
		fi; \
		return 0; \
	}; \
	assert_tests_ran() { \
		label="$$1"; bundle="$$2"; \
		if [[ ! -d "$$bundle" ]]; then \
			printf 'test results bundle missing %s: %s\n' "$$label" "$$bundle" >&2; \
			return 1; \
		fi; \
		if ! summary=$$($(XCODE_WRAPPER) xcrun xcresulttool get test-results summary --path "$$bundle" --compact 2>&1); then \
			printf 'test results summary unreadable %s: %s\n' "$$label" "$$bundle" >&2; \
			printf '%s\n' "$$summary" >&2; \
			return 1; \
		fi; \
		count=""; \
		if [[ "$$summary" =~ \"totalTestCount\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then \
			count="$${BASH_REMATCH[1]}"; \
		fi; \
		if [[ -z "$$count" ]]; then \
			printf 'test results summary missing totalTestCount %s: %s\n' "$$label" "$$bundle" >&2; \
			return 1; \
		fi; \
		if [[ ! "$$count" =~ ^[1-9][0-9]*$$ ]]; then \
			printf 'zero tests recorded %s: %s totalTestCount=%s\n' "$$label" "$$bundle" "$$count" >&2; \
			return 1; \
		fi; \
		printf '%s: %s tests\n' "$$label" "$$count"; \
	}; \
	app_xcode_status=0; \
	TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never $(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(SNAPSHOT_DESTINATION)' "$$simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/App" -resultBundlePath "$$result_root/App.xcresult" -only-testing:$(APP_SNAPSHOT_SUITE) -only-testing:'$(APP_HOSTED_ROOT_PRESENTATION_SNAPSHOT_TEST)()' test || app_xcode_status=$$?; \
	app_count_status=0; \
	assert_tests_ran App "$$result_root/App.xcresult" || app_count_status=$$?; \
	remember_failure App-xcodebuild "$$app_xcode_status"; \
	remember_failure App-test-count "$$app_count_status"; \
	package_xcode_status=0; \
	TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never $(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(SNAPSHOT_DESTINATION)' "$$simulator_udid" -- xcodebuild $(XCODEBUILD_OPTIONS) -workspace $(PACKAGE_WORKSPACE) -scheme $(PACKAGE_SCHEME) -configuration Debug -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/ApplicationFoundation" -resultBundlePath "$$result_root/ApplicationFoundation.xcresult" $(foreach suite,$(PACKAGE_SNAPSHOT_SUITES),-only-testing:$(suite)) test || package_xcode_status=$$?; \
	package_count_status=0; \
	assert_tests_ran ApplicationFoundation "$$result_root/ApplicationFoundation.xcresult" || package_count_status=$$?; \
	remember_failure ApplicationFoundation-xcodebuild "$$package_xcode_status"; \
	remember_failure ApplicationFoundation-test-count "$$package_count_status"; \
	if [[ -n "$$failure_summary" ]]; then \
		printf 'test-snapshots failures: %s\n' "$$failure_summary" >&2; \
	fi; \
	exit "$$status"

# Validate exported evidence with the standard library. Export this helper only
# for the native target, so the Python source stays readable inside the Makefile.
define native_snapshot_validate
import collections
import json
from pathlib import Path
import sys

def require(condition, message):
    if not condition:
        raise ValueError(message)

summary_path, export_path, requested, target = sys.argv[1:]
try:
    scale = int(requested)
    summary = json.loads(Path(summary_path).read_text())
    count = 4 if target == "AppTests" else 1
    for key, expected in (("totalTestCount", count), ("passedTests", count),
                          ("failedTests", 0), ("skippedTests", 0)):
        require(type(summary[key]) is int and summary[key] == expected, "unexpected " + key)
    directory = Path(export_path).resolve()
    manifest = json.loads((directory / "manifest.json").read_text())
    require(isinstance(manifest, list), "manifest must be an array")
    hosted_method = "AppHostedUITests/ScenePrivacyCoverTests/rootPresentationSnapshotsCoverPrimaryShellStates()"
    captures = (["root-content-v1-" + content + "-" + layout
                 for content in ("calculator", "library")
                 for layout in ("compact-iphone", "regular-ipad")] if target == "AppHostedTests" else
                ["compactPhoneSnapshot()", "largePhoneSnapshot()", "regularWidthIPadSnapshot()"])
    expected_counts = collections.Counter({capture: 2 if target == "AppHostedTests" else 1 for capture in captures})
    observed = collections.Counter()
    seen_files = set()
    for test in manifest:
        require(isinstance(test, dict) and isinstance(test["attachments"], list), "malformed manifest entry")
        for attachment in test["attachments"]:
            require(isinstance(attachment, dict), "malformed attachment")
            names = [attachment.get(key) for key in ("exportedFileName", "suggestedHumanReadableName")]
            if not any(isinstance(name, str) and name.startswith("native-snapshot-environment") for name in names):
                continue
            filename = attachment["exportedFileName"]
            require(isinstance(filename, str) and filename, "missing exported filename")
            path = (directory / filename).resolve()
            require(path.parent == directory and path not in seen_files, "invalid or duplicate receipt file")
            seen_files.add(path)
            receipt = json.loads(path.read_text())
            require(isinstance(receipt, dict), "receipt must be an object")
            require(type(receipt["schemaVersion"]) is int and receipt["schemaVersion"] == 1, "unsupported schemaVersion")
            for key, value in (("qualification", "1"), ("expectedScale", requested), ("recordMode", "never"),
                               ("target", target), ("validationError", None)):
                require(key in receipt and receipt[key] == value, "unexpected " + key)
            for key in ("nativeScale", "referenceScale"):
                require(type(receipt[key]) in (int, float) and receipt[key] == scale, "unexpected " + key)
            require(type(receipt["processID"]) is int and receipt["processID"] > 0, "invalid processID")
            require(isinstance(receipt["processName"], str) and receipt["processName"].strip(), "invalid processName")
            capture = receipt["capture"]
            require(isinstance(capture, str) and capture in expected_counts, "unexpected capture")
            method = hosted_method if target == "AppHostedTests" else "RootSurfaceSnapshotTests/" + capture
            require(test["testIdentifier"] == method, "receipt attributed to wrong test")
            observed[capture] += 1
    require(observed == expected_counts, "receipt counts differ: " + repr(observed))
    print(target + ": exact test counts and native " + requested + "x receipts verified")
except (KeyError, ValueError, TypeError, OSError) as error:
    sys.exit(target + ": native snapshot evidence invalid: " + str(error))
endef

test-native-snapshots: export NATIVE_SNAPSHOT_VALIDATE = $(value native_snapshot_validate)
test-native-snapshots:
	@set -euo pipefail; \
	case "$(NATIVE_SNAPSHOT_EXPECTED_SCALE)" in 2|3) ;; *) echo "native snapshot expected scale must be 2 or 3" >&2; exit 1 ;; esac; \
	simulator_udid=$$($(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(NATIVE_SNAPSHOT_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)' | tail -n 1); \
	mkdir -p "$(NATIVE_SNAPSHOT_BUILD_DIRECTORY)"; \
	test_root=$$(mktemp -d "$(NATIVE_SNAPSHOT_BUILD_DIRECTORY)/xcodebuild-native-snapshot.XXXXXX"); \
	results_parent="$(TEST_RESULTS_DIRECTORY)"; \
	if [[ -z "$$results_parent" ]]; then results_parent="$(NATIVE_SNAPSHOT_BUILD_DIRECTORY)/TestResults"; fi; \
	mkdir -p "$$results_parent"; \
	evidence=$$(mktemp -d "$$results_parent/native-snapshots.XXXXXX"); \
	trap 'rm -rf -- "$$test_root"' EXIT; \
	trap 'exit 143' TERM INT; \
	printf 'native snapshot evidence: %s\n' "$$evidence"; \
	status=0; \
	for target in AppTests AppHostedTests; do \
		selector='$(APP_SNAPSHOT_SUITE)'; \
		if [[ "$$target" == AppHostedTests ]]; then selector='$(APP_HOSTED_ROOT_PRESENTATION_SNAPSHOT_TEST)()'; fi; \
		bundle="$$evidence/$$target.xcresult"; \
		attachments="$$evidence/$$target-attachments"; \
		run_status=0; \
		env -u NATIVE_SNAPSHOT_QUALIFICATION -u NATIVE_SNAPSHOT_EXPECTED_SCALE -u SNAPSHOT_TESTING_RECORD \
			TEST_RUNNER_NATIVE_SNAPSHOT_QUALIFICATION=1 \
			TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE="$(NATIVE_SNAPSHOT_EXPECTED_SCALE)" \
			TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never \
			$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(NATIVE_SNAPSHOT_DESTINATION)' "$$simulator_udid" -- \
			xcodebuild $(XCODEBUILD_OPTIONS) -workspace App.xcworkspace -scheme App -configuration Debug \
			-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIRECTORY)" -derivedDataPath "$$test_root/App" \
			-resultBundlePath "$$bundle" -parallel-testing-enabled NO -collect-test-diagnostics never \
			-only-testing:"$$selector" test > "$$evidence/$$target-xcodebuild.log" 2>&1 || run_status=$$?; \
		cat "$$evidence/$$target-xcodebuild.log"; \
		if (( run_status != 0 )); then printf '%s xcodebuild failed: %s\n' "$$target" "$$run_status" >&2; status=1; fi; \
		$(XCODE_WRAPPER) bash -c 'exec xcrun xcresulttool get test-results summary --path "$$1" --compact > "$$2"' \
			_ "$$bundle" "$$evidence/$$target-summary.json" > "$$evidence/$$target-summary.log" 2>&1 || status=1; \
		$(XCODE_WRAPPER) xcrun xcresulttool export attachments --path "$$bundle" --output-path "$$attachments" \
			> "$$evidence/$$target-export.log" 2>&1 || status=1; \
		python3 -c "$$NATIVE_SNAPSHOT_VALIDATE" "$$evidence/$$target-summary.json" "$$attachments" \
			"$(NATIVE_SNAPSHOT_EXPECTED_SCALE)" "$$target" > "$$evidence/$$target-validation.log" 2>&1 || status=1; \
		cat "$$evidence/$$target-validation.log"; \
	done; \
	exit "$$status"

lint: tools
	./Scripts/validate-release-identity.sh
	./Scripts/validate-whitespace.sh
	git diff --check
	bash ./Scripts/swift-tools.sh lint
	bash ./Scripts/run-swiftlint-analysis.sh

lint-analyze: tools
	bash ./Scripts/run-swiftlint-analysis.sh

# Remove repository-local build products through the guarded cleanup helper.
# The helper deletes only paths emitted by this Makefile below .build. It keeps
# the .build parent and unknown contents, and preserves package-local build
# directories because no supported target establishes their ownership.
clean:
	@set -euo pipefail; \
	makefile_path="$(MAKEFILE_LIST)"; \
	makefile_path="$${makefile_path# }"; \
	makefile_path="$${makefile_path% }"; \
	script_directory=$$(dirname -- "$$makefile_path"); \
	bash "$$script_directory/Scripts/clean-build-artifacts.sh"

# Exercise the cleanup helper in disposable Git checkouts. These tests use no
# Xcode, SwiftPM, network access, or previously completed build.
clean-test:
	@set -euo pipefail; \
	makefile_path="$(MAKEFILE_LIST)"; \
	makefile_path="$${makefile_path# }"; \
	makefile_path="$${makefile_path% }"; \
	script_directory=$$(dirname -- "$$makefile_path"); \
	bash "$$script_directory/Scripts/tests/test-clean-build-artifacts.sh"

# Read canonical destinations from Make for both CI preflight and local checks.
verify-test-destination:
	@set -euo pipefail; \
	simulator_udid=$$(GITHUB_OUTPUT= $(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPHONE_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)' | tail -n 1); \
	ipad_simulator_udid=$$(GITHUB_OUTPUT= $(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(IPAD_DESTINATION)' '$(VERIFIED_IPAD_SIMULATOR_UDID)' | tail -n 1); \
	printf 'Verified iPhone simulator: %s\n' "$$simulator_udid"; \
	printf 'Verified iPad simulator: %s\n' "$$ipad_simulator_udid"; \
	if [[ -n "$${GITHUB_OUTPUT:-}" ]]; then \
		printf 'simulator_udid=%s\nipad_simulator_udid=%s\n' "$$simulator_udid" "$$ipad_simulator_udid" >> "$$GITHUB_OUTPUT"; \
	fi

verify-snapshot-destination:
	$(XCODE_WRAPPER) $(DESTINATION_VERIFIER) '$(SNAPSHOT_DESTINATION)' '$(VERIFIED_SIMULATOR_UDID)'

# Synthetic inventories exercise the resolver and actual Make execution arguments.
destination-test:
	python3 ./Scripts/tests/test-xcode-27.2-destination.py
