#!/usr/bin/env python3
"""Exercise destination selection and Make's execution boundary without simulators."""

import json
import io
import os
from functools import lru_cache
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
UDID = "11111111-1111-4111-8111-111111111111"
OTHER_UDID = "22222222-2222-4222-8222-222222222222"
FIXTURE_DEVELOPER_DIR = "/fixture/Xcode"
FIXTURE_SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
MAKE = str(Path(subprocess.check_output(
    ["/usr/bin/xcrun", "--find", "make"], text=True).strip()).with_name("gnumake"))


def _can_run_python_with_fixture_environment(executable):
    """Return whether an interpreter starts with the fixture's Xcode path."""
    path = Path(executable)
    if not path.is_absolute() or not path.is_file():
        return False
    environment = dict(os.environ, DEVELOPER_DIR=FIXTURE_DEVELOPER_DIR,
                       PATH=FIXTURE_SYSTEM_PATH)
    try:
        result = subprocess.run([str(path), "-c", "pass"], env=environment,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return False
    return result.returncode == 0


@lru_cache(maxsize=1)
def _select_fixture_python():
    """Choose an interpreter that remains usable under the fixture environment."""
    if _can_run_python_with_fixture_environment(sys.executable):
        return sys.executable

    result = subprocess.run(["/usr/bin/xcrun", "--find", "python3"],
                            check=True, text=True, capture_output=True)
    executable = result.stdout.strip()
    if not _can_run_python_with_fixture_environment(executable):
        raise RuntimeError("xcrun --find python3 did not return a usable interpreter")
    return executable


NAME = "iPhone 17"
DESTINATION = "platform=iOS Simulator,name=iPhone 17,OS=27.2"
HTTP_MATRIX_ID = "AppHostedUITests/BrowserDownloadHTTPTests/originatingMatrix(profile:row:)"
HTTP_CANCELLATION_ID = "AppHostedUITests/BrowserDownloadHTTPTests/slowCancellation(profile:knownLength:)"
HTTP_TEST_METHODS = (
    "activePollingBudgetChargesWorkAndDiscountsSleepOverrun",
    "slowPredicateCannotSatisfyActiveBudget",
    "activePollingPropagatesCancellation",
    "failureEvidenceIsSanitizedAndLossless",
    "failureEvidenceIsDeterministicallyCapped",
    "commandAndNativeErrorEvidenceIsDeterministicallyCapped",
    "requestEvidenceUsesPlainFixtureLabels",
    "adapterCommitEvidenceRequiresPostBaselineEvent",
    "navigationCommitEvidenceRequiresOperationIdentity",
    "dispatchReadinessRequiresExactNewGET",
    "nonRootAdapterCommitsFirstPageAtRootGeometry",
    "initialPageCommits",
    "originatingMatrix(profile:row:)",
    "priorPageHistorySurvivesNativeDownloadConversion(profile:)",
    "slowCancellation(profile:knownLength:)",
)
APP_HOSTED_EVIDENCE_TEST_IDENTITIES = (
    "BrowserDownloadSceneEvidenceTests/testResizeHandleNormalizesMeasuredRotatedFrame",
    "BrowserDownloadSceneEvidenceTests/testResizeHandleRejectsUnrelatedOffscreenFrame",
    "BrowserDownloadSceneEvidenceTests/testResizeHandleUsesScreenSpaceOriginWithOffsetCard",
    "BrowserDownloadSceneEvidenceTests/testResizeGestureDeltaMovesOutwardPerAvailableAxis",
    "BrowserDownloadSceneEvidenceTests/testResizeGestureDeltaShrinksFullScreenCardOnBothAxes",
    "BrowserDownloadSceneEvidenceTests/testResizeWindowSelectionAllowsVisibleNonKeyedAuxiliaryWindow",
    "BrowserDownloadSceneEvidenceTests/testResizeWindowSelectionRejectsVisibleCover",
    "BrowserDownloadSceneEvidenceTests/testResizeWindowSelectionRejectsZeroOrMultipleVisibleKeyedWindows",
    "BrowserDownloadSceneEvidenceTests/testResizeSceneRequiresUniqueNewActiveSession",
    "BrowserDownloadSceneEvidenceTests/testResizeTimeoutDiagnosticsReadOptionalValuesIndependently",
    "BrowserDownloadSceneEvidenceTests/testPassiveSceneCensusSelectsNewestWindowSnapshot",
    "BrowserDownloadSceneEvidenceTests/testPassiveSceneCensusRejectsConflictingSnapshotsAtSameTime",
    "BrowserDownloadSceneEvidenceTests/testLatestFreshSafeRootsRequiresEveryRegistrationAndUsesMonotonicTime",
    "BrowserDownloadSceneEvidenceTests/testReactivationOwnerSelectionAllowsSnapshotBetweenActivationAndCensus",
    "BrowserDownloadSceneEvidenceTests/testReactivationOwnerSelectionRejectsSnapshotBeforeActivation",
    "BrowserDownloadSceneEvidenceTests/testReactivationOwnerSelectionRejectsWrongRun",
    "BrowserDownloadSceneEvidenceTests/testReactivationOwnerSelectionRejectsWrongGeneration",
    "BrowserDownloadSceneEvidenceTests/testFinalCensusGenerationRejectsNewerUnsafeObservation",
    "BrowserDownloadSceneEvidenceTests/testFinalCensusGenerationRejectsNewerObservationWithoutGeneration",
    "BrowserDownloadSceneEvidenceTests/testReactivationOwnerSelectionRejectsSnapshotAfterCensus",
    "BrowserDownloadSceneEvidenceTests/testReactivationOwnerSelectionAcceptsInclusiveBoundaries",
    "BrowserDownloadSceneEvidenceTests/testReactivationOwnerSelectionRejectsNonFiniteTimestamps",
    "BrowserDownloadSceneEvidenceTests/testReactivationOwnerSelectionUsesLatestObservationWithinInterval",
    "BrowserDownloadSceneEvidenceTests/testReactivationAvailabilityRejectsMismatchWithFinalRegisteredScenes",
    "BrowserDownloadSceneEvidenceTests/testResizeGestureMarkerSelectsExactNewSceneRegistrationAndRun",
    "BrowserDownloadSceneEvidenceTests/testResizeWindowWitnessAcceptsMarkerOnlyLatestObservation",
    "BrowserDownloadSceneEvidenceTests/testResizeWindowWitnessRejectsCoverInCurrentCensus",
    "BrowserDownloadSceneEvidenceTests/testResizeWindowWitnessPreservesSelectedWindowGeometryAndPrivacy",
    "BrowserDownloadSceneEvidenceTests/testInitialMountedSceneWaitsForCoherentRegistrationsWhileProofIsPending",
    "BrowserDownloadSceneEvidenceTests/testReactivationRequiresMatchingLiveRevisionForEveryOriginalSceneRegistration",
    "BrowserDownloadSceneEvidenceTests/testPassiveRootAcceptsMatchingConfirmationAfterPendingCensus",
    "BrowserDownloadSceneEvidenceTests/testPassiveRootRejectsCachedConfirmationAfterLiveRevisionAdvances",
    "BrowserDownloadSceneEvidenceTests/testPassiveRootRejectsUnmatchedOrMalformedLiveRows",
    "BrowserDownloadSceneEvidenceTests/testPassiveRootRequiresCurrentRetainedDownloadCounts",
    "BrowserDownloadSceneEvidenceTests/testRetainedAllocationRejectsEveryRecordedRemovalOutcome",
    "BrowserDownloadSceneEvidenceTests/testRetainedAllocationRemovalAtCensusBoundaryPreventsAcceptance",
    "BrowserDownloadSceneEvidenceTests/testPassiveRootRejectsMissingOrMismatchedConfirmation",
    "BrowserDownloadSceneEvidenceTests/testPassiveRootRejectsSupersededOrUnpairedProof",
    "BrowserDownloadSceneEvidenceTests/testPassiveRootRequiresCoverAndNativeBarrierAbsence",
    "BrowserDownloadSceneEvidenceTests/testPassiveRootRequiresProofBeforeOriginalDeadline",
    "BrowserDownloadSceneEvidenceTests/testPendingLiveRootCannotQualifyAfterDeadline",
    "BrowserDownloadTransferWitnessTests/testDelayedHandoffParserRequiresNativeCallbacksAfterLock",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessAcceptsCorrelatedNativeProgress",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessRejectsMissingHandoffOrProgress",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessRejectsStaleRunOrUnrelatedOperation",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessRejectsServerEvidenceAfterReadiness",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessRejectsEarlyTerminalAndCleanupFailure",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessRejectsPrematureCleanupWithoutFixtureRequest",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessIgnoresPrematureCleanupForAnotherOperation",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessIgnoresPrematureCleanupFromAnotherRun",
    "BrowserDownloadTransferWitnessTests/testContinuationAcceptsFiniteResponseAndNativeFinish",
    "BrowserDownloadTransferWitnessTests/testContinuationRejectsMissingNativeOrTransportWitness",
    "BrowserDownloadTransferWitnessTests/testContinuationRejectsCancellationFailureAndPrematureCleanup",
    "BrowserDownloadTransferWitnessTests/testContinuationRejectsWrongCorrelationEarlyReleaseAndVisibleCompletion",
    "BrowserDownloadTransferWitnessTests/testSlowKnownWitnessDiagnosticsAreRedactedAndBounded",
    "BrowserDownloadObservationReceiptTests/passiveReaderAcceptsAvailableMilestoneBeforeWaiting",
    "BrowserDownloadObservationReceiptTests/passiveReaderPollsUntilMilestoneAppears",
    "BrowserDownloadObservationReceiptTests/passiveReaderRejectsUnchangedMilestone",
    "BrowserDownloadObservationReceiptTests/passiveReaderRejectsWrongProcessRunAndContext",
    "BrowserDownloadObservationReceiptTests/passiveReaderPreservesInvalidatedMalformedAndMissing",
    "BrowserDownloadObservationReceiptTests/passiveReaderRejectsMilestoneAtAndAfterDeadline",
    "BrowserDownloadObservationReceiptTests/passiveReaderChecksDeadlineAfterWaiterCompletes",
    "BrowserDownloadObservationReceiptTests/passiveReaderPreservesInterruption",
    "BrowserDownloadObservationReceiptTests/passiveReaderMapsPendingTimeoutToOriginalDeadline",
)
MULTI_SCENE_TEST_IDENTITIES = (
    "BrowserDownloadMultiSceneUITests/testRequestCreatesNewMountedWindowGroupScene",
    "BrowserDownloadMultiSceneUITests/testSceneRequestRevokesCompletedDownloadAndKeepsActiveRootUsable",
    "BrowserDownloadMultiSceneUITests/testPassiveAccessibilityReadsRefreshCensusWithoutPublishingRootEvents",
    "BrowserDownloadMultiSceneUITests/testHostedRootUpdatePublishesCurrentRevisionWithoutReadFeedback",
)
QUALIFICATION_TEST_IDENTITIES = (
    "BrowserDownloadQualificationUITests/testAcceptedPolicyHandoffAfterLockCompletesHiddenUntilFreshAuthentication",
    "BrowserDownloadQualificationUITests/testQuickLookHomeRevokesAndFreshDownloadRecovers",
    "BrowserDownloadQualificationUITests/testShareHomeRevokesAndFreshDownloadRecovers",
    "BrowserDownloadQualificationUITests/testNormalQualificationModeReturnsToAuthenticatedBrowserAfterHome",
    "BrowserDownloadQualificationUITests/testActiveDownloadQualificationModeAutoLocksAfterRealHomeTransition",
    "BrowserDownloadQualificationUITests/testActiveDiscardFailureRetryAndAuthenticationLoss",
    "BrowserDownloadQualificationUITests/testOrdinaryPNGDownloadAutomaticallyCommitsCanonicalAsset",
    "BrowserDownloadQualificationUITests/testRepeatedPNGDownloadSkipsDuplicateAndRetainsCanonicalIdentity",
    "BrowserDownloadQualificationUITests/testPDFDownloadRemainsOutsideLibraryAndKeepsNativePresentation",
    "BrowserDownloadQualificationUITests/testAcceptedPNGWhileLockedReconcilesAfterAuthenticatedRelaunch",
    "BrowserDownloadQualificationUITests/testColdLockedAuthenticationKeepsDiagnosticReadoutAccessible",
)
AUTOMATED_DOWNLOAD_TEST_IDENTITIES = MULTI_SCENE_TEST_IDENTITIES + QUALIFICATION_TEST_IDENTITIES

# Only process boundaries are replaced. The resolver, shell entry point, and
# Make recipes run unchanged against these inventories and command recordings.
TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
tool = pathlib.Path(sys.argv[0]).name
if tool == "swift":
    print("Apple Swift version 6.3")
elif tool == "xcrun":
    if args == ["--find", "swift"]:
        print("/fixture/Xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    elif args[:3] == ["simctl", "list", "devices"]:
        count_file = root / "device-reads"
        count = int(count_file.read_text()) if count_file.exists() else 0
        count_file.write_text(str(count + 1))
        filename = "devices-after.json" if count and (root / "devices-after.json").exists() else "devices.json"
        print((root / filename).read_text())
    elif args[:3] == ["simctl", "list", "runtimes"]:
        if "--json" in args:
            print((root / "runtimes.json").read_text())
        else:
            print("iOS 27.2 (27.2 - 24B8117) - com.apple.CoreSimulator.SimRuntime.iOS-27-2")
    elif args[:3] == ["xcresulttool", "get", "test-results"]:
        bundle = pathlib.Path(args[args.index("--path") + 1])
        plan_path = root / "result-plan.json"
        plan = json.loads(plan_path.read_text()) if plan_path.exists() else {}
        if plan_path.exists() and not (bundle / "fixture-completed.json").exists():
            sys.exit("Incomplete fixture result bundle")
        method = args[3]
        if method == "summary" and (bundle / "summary.json").is_file():
            print((bundle / "summary.json").read_text())
        else:
            inventory = json.loads((root / "test-cases.json").read_text())
            cases = inventory[bundle.name]
            if bundle.name == "BrowserDownloadMultiScene.xcresult":
                if plan.get("omit_ui_identity"):
                    cases.pop()
                if plan.get("skip_ui_identity"):
                    cases[0]["result"] = "Skipped"
            if plan.get("omit_case"):
                cases = [case for case in cases if case["nodeIdentifier"] != plan["omit_case"]]
            for case in cases:
                if case["nodeIdentifier"] == plan.get("skip_case"):
                    case["result"] = "Skipped"
            if method == "tests":
                plan_name, bundle_target, bundle_type = {
                    "App.xcresult": ("App", "AppHostedTests", "Unit test bundle"),
                    "AppHTTP.xcresult": ("App", "AppHostedTests", "Unit test bundle"),
                    "ApplicationFoundation.xcresult": (
                        "ApplicationFoundation", "AppFeatureTests", "Unit test bundle"),
                    "App-iPadPrivacy.xcresult": ("App", "AppHostedTests", "Unit test bundle"),
                    "BrowserDownloadMultiScene.xcresult": (
                        "BrowserTabOverviewUITests", "BrowserTabOverviewUITests", "UI test bundle"),
                }[bundle.name]
                if plan.get("wrong_http_target") and bundle.name == "AppHTTP.xcresult":
                    bundle_target = "OtherHostedTests"
                bundle_url = f"test://com.apple.xcode/{plan_name}/{bundle_target}"
                bundle_node = {
                    "nodeType": bundle_type,
                    "name": bundle_target,
                    "nodeIdentifierURL": bundle_url,
                    "children": [],
                }
                plan_node = {
                    "nodeType": "Test Plan",
                    "name": plan_name,
                    "children": [bundle_node],
                }
                for case in cases:
                    identity_parts = case["nodeIdentifier"].split("/")
                    if len(identity_parts) < 2:
                        sys.exit("Fixture test identity must contain a suite and method")
                    current = bundle_node
                    prefix = []
                    for part in identity_parts[:-1]:
                        prefix.append(part)
                        suite_url = bundle_url + "/" + "/".join(prefix)
                        suite_node = next((child for child in current["children"]
                                           if child.get("nodeType") == "Test Suite" and
                                           child.get("nodeIdentifierURL") == suite_url), None)
                        if suite_node is None:
                            suite_node = {
                                "nodeType": "Test Suite",
                                "name": part,
                                "nodeIdentifierURL": suite_url,
                                "children": [],
                            }
                            current["children"].append(suite_node)
                        current = suite_node
                    case_node = dict(case)
                    case_node["nodeIdentifierURL"] = bundle_url + "/" + case["nodeIdentifier"]
                    current["children"].append(case_node)
                print(json.dumps({"testNodes": [plan_node]}))
            elif method == "summary":
                ipad = bundle.name in {"BrowserDownloadMultiScene.xcresult", "App-iPadPrivacy.xcresult"}
                device_id = ("22222222-2222-4222-8222-222222222222" if ipad else
                             "11111111-1111-4111-8111-111111111111")
                print(json.dumps({
                    "result": "Passed", "totalTestCount": len(cases),
                    "passedTests": sum(case["result"] == "Passed" for case in cases),
                    "failedTests": 0, "expectedFailures": 0,
                    "skippedTests": sum(case["result"] == "Skipped" for case in cases),
                    "devicesAndConfigurations": [{"device": {
                        "deviceId": device_id, "deviceName": "iPad Pro 11-inch (M5)" if ipad else "iPhone 17",
                        "osVersion": "27.2", "platform": "iOS Simulator",
                    }}],
                }))
            else:
                sys.exit("Unexpected result method: " + method)
        if method == "summary" and os.environ.get("SCENARIO") == "summary-error": sys.exit(2)
    elif args[:3] == ["xcresulttool", "export", "attachments"]:
        bundle = pathlib.Path(args[args.index("--path") + 1])
        output = pathlib.Path(args[args.index("--output-path") + 1])
        __import__("shutil").copytree(bundle / "exports", output, dirs_exist_ok=True)
        if os.environ.get("SCENARIO") == "export-error": sys.exit(2)
    else:
        sys.exit("Unexpected xcrun arguments: " + repr(args))
elif tool == "xcodebuild":
    if args == ["-version"]:
        print("Xcode 27.2\nBuild version 27B52")
    elif "-enumerate-tests" in args:
        if "-xctestrun" in args:
            xctestrun = pathlib.Path(args[args.index("-xctestrun") + 1])
            if not xctestrun.is_file():
                sys.exit("The requested xctestrun file does not exist")
        output_path = pathlib.Path(args[args.index("-test-enumeration-output-path") + 1])
        lane = output_path.stem.removesuffix("-enumeration")
        identities = json.loads((root / "enumeration-identities.json").read_text())[lane]
        output_path.write_text(json.dumps({
            "errors": [],
            "values": [{
                "testPlan": lane,
                "enabledTests": [{"identifier": identity} for identity in identities],
                "disabledTests": [],
            }],
        }))
        with (root / "enumerated.jsonl").open("a") as stream:
            stream.write(json.dumps(args) + "\n")
        if "-resultBundlePath" in args:
            bundle = pathlib.Path(args[args.index("-resultBundlePath") + 1])
            bundle.mkdir(parents=True)
            (bundle / "fixture-enumeration.json").write_text(json.dumps({"testRuns": 0}))
            (bundle / "fixture-completed.json").write_text(
                json.dumps({"result": "Passed", "testRuns": 0}))
        print("Command line invocation: enumeration output is written to the requested path")
    elif "-showdestinations" in args:
        scheme = args[args.index("-scheme") + 1]
        print('Destinations compatible with the "' + scheme + '" scheme:')
        print((root / "destinations.txt").read_text())
        print('Destinations incompatible with the "' + scheme + '" scheme:')
        print((root / "ineligible.txt").read_text())
    elif "build-for-testing" in args:
        with (root / "builds.jsonl").open("a") as stream:
            stream.write(json.dumps(args) + "\n")
        if args[args.index("-scheme") + 1] == "App":
            plan_path = root / "result-plan.json"
            plan = json.loads(plan_path.read_text()) if plan_path.exists() else {}
            products = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build" / "Products"
            products.mkdir(parents=True)
            mode = plan.get("xctestrun")
            if mode != "missing":
                (products / "App_iphonesimulator27.2-arm64.xctestrun").write_text("fixture specification")
            if mode == "ambiguous":
                (products / "App_iphonesimulator-extra.xctestrun").write_text("second fixture specification")
    else:
        with (root / "executed.jsonl").open("a") as stream:
            stream.write(json.dumps(args) + "\n")
        if "-resultBundlePath" in args:
            if os.environ.get("SCENARIO") == "missing-bundle": sys.exit(0)
            bundle = pathlib.Path(args[args.index("-resultBundlePath") + 1])
            plan_path = root / "result-plan.json"
            plan = json.loads(plan_path.read_text()) if plan_path.exists() else {}
            phase = len((root / "executed.jsonl").read_text().splitlines())
            if phase == plan.get("missing_on"):
                sys.exit(0)
            bundle.mkdir(parents=True)
            if os.environ.get("TEST_RUNNER_NATIVE_SNAPSHOT_QUALIFICATION") == "1":
                with (root / "environment.jsonl").open("a") as stream:
                    stream.write(json.dumps(dict(os.environ)) + "\n")
                hosted = "Hosted" in bundle.name
                scenario = os.environ.get("SCENARIO", "")
                summary = dict(totalTestCount=1 if hosted else 4, passedTests=1 if hosted else 4,
                               failedTests=0, skippedTests=0)
                if scenario == "zero": summary["totalTestCount"] = 0
                if scenario == "bad-summary": summary = "not a summary"
                if scenario == "boolean-count": summary["skippedTests"] = False
                if scenario == "skipped": summary["skippedTests"] = 1
                if scenario == "failed": summary["failedTests"] = 1
                if scenario == "extra": summary["totalTestCount"] += 1
                if scenario == "missing-count": del summary["skippedTests"]
                (bundle / "summary.json").write_text(json.dumps(summary))
                exports = bundle / "exports"
                exports.mkdir()
                captures = ([f"root-content-v1-{content}-{layout}" for content in ("calculator", "library")
                             for layout in ("compact-iphone", "regular-ipad")] * 2 if hosted else
                            ["compactPhoneSnapshot()", "largePhoneSnapshot()", "regularWidthIPadSnapshot()"])
                manifest = []
                for index, capture in enumerate(captures):
                    method = ("AppHostedUITests/ScenePrivacyCoverTests/"
                              "rootPresentationSnapshotsCoverPrimaryShellStates()" if hosted else
                              "RootSurfaceSnapshotTests/" + capture)
                    receipt = dict(schemaVersion=1, qualification="1",
                                   expectedScale=os.environ["TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE"],
                                   recordMode="never", nativeScale=int(os.environ["TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE"]),
                                   referenceScale=int(os.environ["TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE"]),
                                   capture=capture, target="AppHostedTests" if hosted else "AppTests",
                                   processID=123, processName="TestHost", validationError=None)
                    mutations = {"scale": ("nativeScale", 2 if receipt["nativeScale"] == 3 else 3),
                                 "reference": ("referenceScale", 1), "qualification": ("qualification", None),
                                 "expected": ("expectedScale", "2"), "record": ("recordMode", "all"),
                                 "validation": ("validationError", "bad environment"), "schema": ("schemaVersion", True),
                                 "pid": ("processID", 0), "process": ("processName", ""),
                                 "target": ("target", "Other"), "capture": ("capture", "Other")}
                    if scenario in mutations:
                        key, value = mutations[scenario]
                        receipt[key] = value
                    filename = (f"opaque-{index}.json" if scenario == "opaque-filenames" else
                                f"native-snapshot-environment-{index}.json")
                    (exports / filename).write_text("{" if scenario == "bad-json" else json.dumps(receipt))
                    attachment = dict(exportedFileName=filename, suggestedHumanReadableName=f"native-snapshot-environment_{index}.json")
                    if scenario == "missing-file": (exports / filename).unlink()
                    manifest.append(dict(testIdentifier="Wrong/method()" if scenario == "attribution" else method,
                                         attachments=[attachment]))
                if scenario == "missing": manifest.pop()
                if scenario == "duplicate": manifest.append(manifest[0])
                (exports / "manifest.json").write_text("{" if scenario == "bad-manifest" else json.dumps(manifest))
                if scenario == "no-manifest": (exports / "manifest.json").unlink()
                if scenario == "xcode-failure" and not hosted: sys.exit(65)
            else:
                (bundle / "fixture-partial").write_text("result writer started")
                if phase == plan.get("wait_on"):
                    pressure_bytes = int(os.environ.get("FIXTURE_PRE_BARRIER_OUTPUT_BYTES", "0"))
                    remaining = [pressure_bytes, pressure_bytes]
                    markers = (b"\x00", b"\x01")
                    streams = (sys.stdout.buffer, sys.stderr.buffer)
                    while remaining[0] or remaining[1]:
                        for index, stream in enumerate(streams):
                            if remaining[index]:
                                size = min(4096, remaining[index])
                                stream.write(markers[index] * size)
                                stream.flush()
                                remaining[index] -= size
                    if pressure_bytes:
                        (root / "pre-barrier-output.json").write_text(json.dumps({
                            "stdout_bytes": pressure_bytes,
                            "stderr_bytes": pressure_bytes,
                        }))
                    import signal
                    ignore = plan.get("ignore_signals", False)
                    for event in (signal.SIGINT, signal.SIGTERM):
                        signal.signal(event, signal.SIG_IGN if ignore else
                                      lambda number, frame: sys.exit(128 + number))
                    # Signal only after the partial result and handlers exist.
                    fd = int(os.environ["FIXTURE_READY_FD"])
                    os.write(fd, (json.dumps({"bundle": str(bundle)}) + "\n").encode())
                    os.close(fd)
                    while True:
                        signal.pause()
                if phase != plan.get("partial_on"):
                    (bundle / "fixture-completed.json").write_text(json.dumps({
                        "phase": phase,
                        "result": "Failed" if phase == plan.get("fail_on") else "Passed",
                    }))
                if phase == plan.get("fail_on"):
                    sys.exit(65)
else:
    sys.exit("Unexpected tool: " + tool)
'''


class DestinationFixture:
    def setUp(self):
        self.python = _select_fixture_python()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Apple's shim reads the fake developer path, so pin env-based shebangs.
        (self.bin / "python3").symlink_to(self.python)
        for name in ("xcrun", "xcodebuild", "swift"):
            path = self.bin / name
            path.write_text(TOOL)
            path.chmod(0o755)
        self.wrapper = self.bin / "wrapper"
        self.wrapper.write_text('#!/usr/bin/env bash\nexec "$@"\n')
        self.wrapper.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        DEVELOPER_DIR=FIXTURE_DEVELOPER_DIR, FIXTURE_ROOT=str(self.root),
                        GITHUB_OUTPUT=str(self.root / "outputs"), PYTHONDONTWRITEBYTECODE="1")
        self.devices = {"devices": {RUNTIME: [self.device()]}}
        self.runtimes = {"runtimes": [{"identifier": RUNTIME, "version": "27.2",
                                      "buildversion": "24B8117", "isAvailable": True}]}
        self.destinations = [self.destination()]
        (self.root / "ineligible.txt").write_text("")
        self.http_matrix_arguments = [
            {"nodeType": "Arguments", "name": f".{profile}, .{row}", "result": "Passed"}
            for profile in ("persistentPrivate", "ephemeral")
            for row in ("attachment", "inline", "octet", "redirect", "protected", "post", "blob", "attribute")
        ]
        self.http_cancellation_arguments = [
            {"nodeType": "Arguments", "name": f".{profile}, {known_length}", "result": "Passed"}
            for profile in ("persistentPrivate", "ephemeral")
            for known_length in ("true", "false")
        ]

    def device(self, name=NAME, udid=UDID, available=True):
        return {"name": name, "udid": udid, "isAvailable": available, "state": "Shutdown"}

    def destination(self, name=NAME, udid=UDID):
        return f"{{ platform:iOS Simulator, arch:arm64, id:{udid}, OS:27.2, name:{name} }}"

    def write_inventory(self):
        (self.root / "devices.json").write_text(json.dumps(self.devices))
        (self.root / "runtimes.json").write_text(json.dumps(self.runtimes))
        (self.root / "destinations.txt").write_text("\n".join(self.destinations))
        self.write_result_cases(AUTOMATED_DOWNLOAD_TEST_IDENTITIES)

    def write_result_cases(self, browser_identities):
        physical = ("AppHostedUITests/BrowserDownloadPersistenceIsolationTests/"
                    "completedFilesRetainProtectionAndBackupExclusion()")
        suites = {
            "App.xcresult": [
                physical,
                *(identity + "()" for identity in APP_HOSTED_EVIDENCE_TEST_IDENTITIES),
            ],
            "AppHTTP.xcresult": [
                "AppHostedUITests/BrowserDownloadHTTPTests/" +
                (method if "(" in method else method + "()")
                for method in HTTP_TEST_METHODS
            ],
            "ApplicationFoundation.xcresult": [
                "VaultFeatureTests/globalLockFencesPendingBrowserProfileTransition()",
                "RootFeatureTests/backgroundReturnCancelsPendingHiddenVerification()",
            ],
            "App-iPadPrivacy.xcresult": [
                "AppHostedUITests/ScenePrivacyCoverTests/rootPrivacyCoverSynchronouslyOccludesPrivateSentinel(_:)",
            ],
            "BrowserDownloadMultiScene.xcresult": [identity + "()" for identity in browser_identities],
        }
        cases = {
            name: [{"nodeType": "Test Case", "nodeIdentifier": identity,
                    "result": "Skipped" if identity == physical else "Passed"} for identity in identities]
            for name, identities in suites.items()
        }
        matrix_case = next(case for case in cases["AppHTTP.xcresult"] if case["nodeIdentifier"] == HTTP_MATRIX_ID)
        matrix_case["name"] = "Native HTTP classification and request ownership"
        matrix_case["children"] = self.http_matrix_arguments
        cancellation_case = next(case for case in cases["AppHTTP.xcresult"] if case["nodeIdentifier"] == HTTP_CANCELLATION_ID)
        cancellation_case["children"] = self.http_cancellation_arguments
        (self.root / "enumeration-identities.json").write_text(json.dumps({
            "App": ["AppHostedTests/" + case["nodeIdentifier"]
                    for case in cases["App.xcresult"]],
            "AppHTTP": ["AppHostedTests/" + case["nodeIdentifier"]
                        for case in cases["AppHTTP.xcresult"]],
            "ApplicationFoundation": [
                "AppFeatureTests/" + case["nodeIdentifier"]
                for case in cases["ApplicationFoundation.xcresult"]
            ],
        }))
        (self.root / "test-cases.json").write_text(json.dumps(cases))

    def verify(self, expected="", destination=NAME, execute=False):
        self.write_inventory()
        command = ["bash", str(ROOT / "Scripts/verify-xcode-27.2-destination.sh"), destination, expected]
        if execute:
            command += ["--", "xcodebuild", "-workspace", "App.xcworkspace", "-scheme", "App", "test"]
        return subprocess.run(command, env=self.env, cwd=ROOT, text=True, capture_output=True)

    def executions(self):
        path = self.root / "executed.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def run_multi_scene_result_check(self, observed_identities):
        self.write_inventory()
        self.write_result_cases(observed_identities)
        command = [
            self.python,
            str(ROOT / "Scripts/assert-xcresult-tests.py"),
            "--bundle",
            str(self.root / "BrowserDownloadMultiScene.xcresult"),
            "--expected-device-id",
            OTHER_UDID,
            "--expected-device-name",
            "iPad Pro 11-inch (M5)",
            "--expected-os-version",
            "27.2",
        ]
        for identity in AUTOMATED_DOWNLOAD_TEST_IDENTITIES:
            command.extend(("--expected-test", identity))
        return subprocess.run(command, cwd=ROOT, env=self.env, text=True, capture_output=True)

    def assert_rejected(self, **kwargs):
        result = self.verify(**kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.executions(), [])


class DestinationTests(DestinationFixture, unittest.TestCase):
    def test_exact_valid_device_returns_verified_udid(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], UDID)
        self.assertIn(f"simulator_udid={UDID}", (self.root / "outputs").read_text())

    def test_minimal_path_uses_verified_python_for_resolver_and_tools(self):
        self.env["PATH"] = f"{self.bin}:{FIXTURE_SYSTEM_PATH}"
        result = self.verify(execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        executed = self.executions()
        self.assertEqual(len(executed), 1)
        self.assertEqual(
            executed[0][executed[0].index("-destination") + 1],
            f"platform=iOS Simulator,id={UDID}",
        )

    def test_similar_name_suffix_is_rejected(self):
        self.devices["devices"][RUNTIME] = [self.device(name="iPhone 17 Pro")]
        self.destinations = [self.destination(name="iPhone 17 Pro")]
        self.assert_rejected()

    def test_similar_name_prefix_is_rejected(self):
        self.devices["devices"][RUNTIME] = [self.device(name="Test iPhone 17")]
        self.destinations = [self.destination(name="Test iPhone 17")]
        self.assert_rejected()

    def test_exact_name_under_wrong_runtime_is_rejected(self):
        self.devices["devices"] = {"com.apple.CoreSimulator.SimRuntime.iOS-27-1": [self.device()]}
        self.assert_rejected()

    def test_wrong_runtime_build_is_rejected(self):
        self.runtimes["runtimes"][0]["buildversion"] = "24B9999"
        self.assert_rejected()

    def test_unavailable_device_is_rejected(self):
        self.devices["devices"][RUNTIME][0]["isAvailable"] = False
        self.assert_rejected()

    def test_ambiguous_exact_names_are_rejected(self):
        self.devices["devices"][RUNTIME].append(self.device(udid=OTHER_UDID))
        self.destinations.append(self.destination(udid=OTHER_UDID))
        self.assert_rejected()

    def test_explicit_udid_disambiguates_exact_names(self):
        self.devices["devices"][RUNTIME].append(self.device(udid=OTHER_UDID))
        self.destinations.append(self.destination(udid=OTHER_UDID))
        result = self.verify(expected=OTHER_UDID)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1], OTHER_UDID)

    def test_explicit_mismatching_udid_is_rejected(self):
        self.assert_rejected(expected=OTHER_UDID)

    def test_device_absent_from_scheme_destinations_is_rejected(self):
        self.destinations = [self.destination(udid=OTHER_UDID)]
        self.assert_rejected()

    def test_ineligible_destination_is_rejected(self):
        self.destinations = []
        (self.root / "ineligible.txt").write_text(self.destination())
        self.assert_rejected()

    def test_bracketed_macos_variant_does_not_hide_valid_simulator(self):
        self.destinations.insert(0, "{ platform:macOS, arch:arm64, "
                                 "variant:Designed for [iPad,iPhone], "
                                 "id:00006040-000A298921A0801C, name:My Mac }")
        result = self.verify(expected=UDID, execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        executed, = self.executions()
        self.assertEqual(executed[executed.index("-destination") + 1],
                         "platform=iOS Simulator,id=11111111-1111-4111-8111-111111111111")

    def test_unbalanced_destination_brackets_are_rejected(self):
        for variant in ("Designed for [iPad,iPhone", "Designed for iPad,iPhone]"):
            with self.subTest(variant=variant):
                self.destinations = [f"{{ platform:macOS, variant:{variant}, name:My Mac }}",
                                     self.destination()]
                self.assert_rejected(execute=True)

    def test_malformed_destination_field_is_rejected(self):
        self.destinations.insert(0, "{ platform:macOS, invalid field, name:My Mac }")
        self.assert_rejected(execute=True)

    def test_duplicate_destination_field_is_rejected(self):
        self.destinations.insert(0, "{ platform:macOS, name:My Mac, name:Other Mac }")
        self.assert_rejected(execute=True)

    def test_unsupported_destination_is_rejected(self):
        self.assert_rejected(destination="platform=macOS,name=iPhone 17,OS=27.2")

    def test_verified_device_unavailable_before_execution_is_rejected(self):
        (self.root / "devices-after.json").write_text(json.dumps({"devices": {RUNTIME: [self.device(available=False)]}}))
        self.assert_rejected(expected=UDID, execute=True)

    def test_verified_udid_reaches_actual_xcodebuild_arguments(self):
        result = self.verify(expected=UDID, execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        executed, = self.executions()
        self.assertEqual(executed[executed.index("-destination") + 1],
                         "platform=iOS Simulator,id=11111111-1111-4111-8111-111111111111")

    def test_test_destination_preflight_exports_both_verified_devices(self):
        ipad_name = "iPad Pro 11-inch (M5)"
        self.devices = {"devices": {RUNTIME: [
            self.device(name=NAME, udid=UDID),
            self.device(name=ipad_name, udid=OTHER_UDID),
        ]}}
        self.destinations = [
            self.destination(name=NAME, udid=UDID),
            self.destination(name=ipad_name, udid=OTHER_UDID),
        ]
        self.write_inventory()

        result = subprocess.run(
            [MAKE, "verify-test-destination", f"XCODE_WRAPPER={self.wrapper}",
             f"VERIFIED_SIMULATOR_UDID={UDID}",
             f"VERIFIED_IPAD_SIMULATOR_UDID={OTHER_UDID}",
             f"PATH={self.env['PATH']}"],
            cwd=ROOT,
            env=self.env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        outputs = (self.root / "outputs").read_text().splitlines()
        self.assertIn(f"simulator_udid={UDID}", outputs)
        self.assertIn(f"ipad_simulator_udid={OTHER_UDID}", outputs)

    def test_xcresult_assertion_rejects_inexact_multi_scene_test_identities(self):
        missing_identity = AUTOMATED_DOWNLOAD_TEST_IDENTITIES[:-1]
        unexpected_identity = AUTOMATED_DOWNLOAD_TEST_IDENTITIES + (
            "BrowserDownloadMultiSceneUITests/testUnexpectedFixtureIdentity",
        )
        mismatched_identity = (
            "BrowserDownloadMultiSceneUITests/testMismatchedFixtureIdentity",
            *AUTOMATED_DOWNLOAD_TEST_IDENTITIES[1:],
        )

        for label, observed in (
            ("missing", missing_identity),
            ("unexpected", unexpected_identity),
            ("mismatched", mismatched_identity),
        ):
            with self.subTest(label=label):
                result = self.run_multi_scene_result_check(observed)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("test identities differ", result.stderr)

    def test_make_binds_each_invocation_to_its_expected_destination(self):
        checkout = self.root / "checkout"
        checkout.mkdir()
        shutil.copy2(ROOT / "Makefile", checkout / "Makefile")
        (checkout / "Scripts").symlink_to(ROOT / "Scripts", target_is_directory=True)
        ipad_name = "iPad Pro 11-inch (M5)"
        for target in ("test", "test-snapshots"):
            with self.subTest(target=target):
                if target == "test":
                    ipad_udid = OTHER_UDID
                    self.devices = {"devices": {RUNTIME: [
                        self.device(name=NAME, udid=UDID),
                        self.device(name=ipad_name, udid=ipad_udid),
                    ]}}
                    self.destinations = [
                        self.destination(name=NAME, udid=UDID),
                        self.destination(name=ipad_name, udid=ipad_udid),
                    ]
                    expected_schemes = ["App", "App", "ApplicationFoundation-Package", "App",
                                        "BrowserTabOverviewUITests"]
                    expected_udids = [UDID, UDID, UDID, ipad_udid, ipad_udid]
                else:
                    self.devices = {"devices": {RUNTIME: [self.device(name=ipad_name)]}}
                    self.destinations = [self.destination(name=ipad_name)]
                    expected_schemes = ["App", "ApplicationFoundation-Package"]
                    expected_udids = [UDID, UDID]
                self.write_inventory()
                (self.root / "executed.jsonl").unlink(missing_ok=True)
                result = subprocess.run([MAKE, target, f"XCODE_WRAPPER={self.wrapper}",
                                         f"VERIFIED_SIMULATOR_UDID={UDID}",
                                         f"VERIFIED_IPAD_SIMULATOR_UDID={ipad_udid if target == 'test' else ''}",
                                         f"PATH={self.env['PATH']}"],
                                        cwd=checkout, env=self.env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                commands = self.executions()
                self.assertEqual([args[args.index("-scheme") + 1] for args in commands],
                                 expected_schemes)
                self.assertEqual([args[args.index("-destination") + 1].rsplit("=", 1)[-1]
                                  for args in commands], expected_udids)
                if target == "test":
                    multi_scene_command = commands[-1]
                    self.assertEqual(
                        [argument for argument in multi_scene_command
                         if argument.startswith("-only-testing:")],
                        [
                            "-only-testing:BrowserTabOverviewUITests/" + identity
                            for identity in AUTOMATED_DOWNLOAD_TEST_IDENTITIES
                        ],
                    )


    def test_xcode_wrapper_keeps_xcresulttool_json_stdout_clean_and_fails_closed(self):
        script_directory = self.root / "wrapper"
        script_directory.mkdir()
        wrapper = script_directory / "with-xcode-27.2.sh"
        shutil.copy2(ROOT / "Scripts/with-xcode-27.2.sh", wrapper)
        selector = script_directory / "select-xcode-27.2.sh"
        shutil.copy2(ROOT / "Scripts/select-xcode-27.2.sh", selector)
        preflight = script_directory / "ensure-ios-27.2-runtime.sh"
        preflight.write_text(
            "#!/usr/bin/env bash\n"
            "printf 'Verified simulator runtime: fixture\\n'\n"
            "if [[ \"${FIXTURE_FAIL_RUNTIME_PREFLIGHT:-0}\" == 1 ]]; then\n"
            "  printf 'fixture preflight failure\\n' >&2\n"
            "  exit 19\n"
            "fi\n"
        )
        preflight.chmod(0o755)

        marker = self.root / "wrapped-xcresulttool-ran"
        command_tool = self.bin / "xcresulttool"
        command_tool.write_text(
            "#!/usr/bin/env python3\n"
            "import json, pathlib\n"
            "pathlib.Path('" + str(marker) + "').write_text('ran')\n"
            "print(json.dumps({'fixture': 'xcresulttool'}))\n"
        )
        command_tool.chmod(0o755)
        command = [str(wrapper), str(command_tool), "get", "test-results", "summary"]
        env = dict(__import__('os').environ)
        result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '{"fixture": "xcresulttool"}\n')
        self.assertEqual(json.loads(result.stdout), {"fixture": "xcresulttool"})
        self.assertIn("Verified simulator runtime: fixture", result.stderr)
        self.assertTrue(marker.is_file())

        marker.unlink()
        failure_env = dict(env, FIXTURE_FAIL_RUNTIME_PREFLIGHT="1")
        result = subprocess.run(command, cwd=ROOT, env=failure_env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture preflight failure", result.stderr)
        self.assertFalse(marker.exists())


class ResultRetentionTests(unittest.TestCase):
    """Run real Make recipes; replace only native process and result-reader boundaries."""

    def setUp(self):
        self.fixture = DestinationTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.checkout = self.fixture.root / "checkout with spaces"
        self.checkout.mkdir()
        shutil.copy2(ROOT / "Makefile", self.checkout / "Makefile")
        (self.checkout / "Scripts").symlink_to(ROOT / "Scripts", target_is_directory=True)
        self.build_root = self.fixture.root / "build products"
        self.results_root = self.fixture.root / "retained results"
        self.invocation_roots = []
        for directory in (self.build_root, self.results_root, self.checkout / ".build"):
            directory.mkdir(exist_ok=True)
            (directory / "unrelated-sentinel").write_text("owner data")

    def invocation_roots_for(self, name):
        build_root = self.fixture.root / f"{name} build products"
        results_root = self.fixture.root / f"{name} retained results"
        for directory in (build_root, results_root):
            directory.mkdir()
            (directory / "unrelated-sentinel").write_text("owner data")
        self.invocation_roots.append((build_root, results_root))
        return build_root, results_root

    def command(self, target, plan, retained=True, build_root=None, results_root=None):
        build_root = build_root or self.build_root
        results_root = results_root or self.results_root
        ipad = "iPad Pro 11-inch (M5)"
        self.fixture.devices = {"devices": {RUNTIME: [
            self.fixture.device(name=NAME, udid=UDID),
            self.fixture.device(name=ipad, udid=OTHER_UDID),
        ]}}
        self.fixture.destinations = [
            self.fixture.destination(name=NAME, udid=UDID),
            self.fixture.destination(name=ipad, udid=OTHER_UDID),
        ]
        self.fixture.write_inventory()
        (self.fixture.root / "result-plan.json").write_text(json.dumps(plan))
        (self.fixture.root / "executed.jsonl").unlink(missing_ok=True)
        return [MAKE, target, f"XCODE_WRAPPER={self.fixture.wrapper}",
                f"VERIFIED_SIMULATOR_UDID={OTHER_UDID if target == 'test-snapshots' else UDID}",
                f"VERIFIED_IPAD_SIMULATOR_UDID={OTHER_UDID}",
                f"XCODE_BUILD_ROOT={build_root}",
                f"TEST_RESULTS_DIRECTORY={results_root if retained else ''}",
                f"PATH={self.fixture.env['PATH']}"]

    def run_make(self, target, plan=None, retained=True):
        return subprocess.run(self.command(target, plan or {}, retained),
                              cwd=self.checkout, env=self.fixture.env,
                              text=True, capture_output=True, timeout=30)

    def bundles(self):
        return sorted(self.results_root.glob("*/*.xcresult"))

    def assert_owner_data_intact(self):
        directories = [self.build_root, self.results_root, self.checkout / ".build"]
        for build_root, results_root in self.invocation_roots:
            directories.extend((build_root, results_root))
        for directory in directories:
            self.assertEqual((directory / "unrelated-sentinel").read_text(), "owner data")

    def assert_builds_cleaned(self, build_root=None):
        build_root = build_root or self.build_root
        self.assertEqual(list(build_root.glob("xcodebuild-*")), [])
        self.assert_owner_data_intact()

    def stop_during_phase(self, target, abrupt, output_pressure_bytes=0,
                          build_root=None, results_root=None):
        """Keep readiness on its own FD and write command output to temporary files."""

        def log_tail(stream):
            size = os.fstat(stream.fileno()).st_size
            tail = os.pread(stream.fileno(), 2048, max(0, size - 2048))
            return f"{size} bytes; tail={tail.decode(errors='replace')}"

        with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
            read_fd, write_fd = os.pipe()
            process = None
            stopped = False
            try:
                env = dict(self.fixture.env, FIXTURE_READY_FD=str(write_fd),
                           FIXTURE_PRE_BARRIER_OUTPUT_BYTES=str(output_pressure_bytes))
                process = subprocess.Popen(
                    self.command(target, {"wait_on": 2, "ignore_signals": abrupt},
                                 build_root=build_root, results_root=results_root),
                    cwd=self.checkout, env=env, stdout=stdout_file, stderr=stderr_file,
                    start_new_session=True, pass_fds=(write_fd,),
                )
                os.close(write_fd)
                write_fd = None
                ready, _, _ = select.select([read_fd], [], [], 10)
                if not ready:
                    status = process.poll()
                    state = f"exited with status {status}" if status is not None else "still running"
                    self.fail(
                        f"Fixture did not reach its partial-result barrier within 10 seconds; "
                        f"process {state}; stdout {log_tail(stdout_file)}; "
                        f"stderr {log_tail(stderr_file)}"
                    )
                message = os.read(read_fd, 4096)
                if not message:
                    self.fail(
                        f"Fixture exited before its partial-result barrier "
                        f"with status {process.poll()}; stdout {log_tail(stdout_file)}; "
                        f"stderr {log_tail(stderr_file)}"
                    )
                partial = Path(json.loads(message)["bundle"])
                self.assertTrue((partial / "fixture-partial").is_file())
                shutdown_deadline = time.monotonic() + 10
                os.killpg(process.pid, signal.SIGKILL if abrupt else signal.SIGTERM)
                process.wait(timeout=max(0, shutdown_deadline - time.monotonic()))
                while True:
                    try:
                        os.killpg(process.pid, 0)
                    except ProcessLookupError:
                        break
                    remaining = shutdown_deadline - time.monotonic()
                    if remaining <= 0:
                        self.fail("Fixture process group did not exit within 10 seconds")
                    time.sleep(min(0.05, remaining))
                stopped = True
                diagnostic = f"stdout {log_tail(stdout_file)}; stderr {log_tail(stderr_file)}"
                self.assertNotEqual(process.returncode, 0, diagnostic)
            finally:
                if write_fd is not None:
                    os.close(write_fd)
                os.close(read_fd)
                if process is not None and not stopped:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=10)

    def test_success_preserves_all_bundles_at_native_result_paths_with_spaces(self):
        for target, names in (
            ("test", ("App.xcresult", "AppHTTP.xcresult", "ApplicationFoundation.xcresult",
                      "App-iPadPrivacy.xcresult", "BrowserDownloadMultiScene.xcresult")),
            ("test-snapshots", ("App.xcresult", "ApplicationFoundation.xcresult")),
        ):
            with self.subTest(target=target):
                result = self.run_make(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                current = [Path(args[args.index("-resultBundlePath") + 1])
                           for args in self.fixture.executions()]
                self.assertEqual({bundle.name for bundle in current}, set(names))
                self.assertEqual(len({bundle.parent for bundle in current}),
                                 4 if target == "test" else 1)
                for bundle in current:
                    self.assertTrue(bundle.is_relative_to(self.results_root))
                    self.assertEqual(json.loads((bundle / "fixture-completed.json").read_text())
                                     ["result"], "Passed")
                if target == "test":
                    evidence_roots = [Path(path) for path in re.findall(
                        r"(?m)^functional test evidence: (.+)$", result.stdout)]
                    self.assertEqual(len(evidence_roots), 4)
                    self.assertTrue((evidence_roots[0] / "App-enumeration.json").is_file())
                    self.assertTrue((evidence_roots[0] / "AppHTTP-enumeration.json").is_file())
                    self.assertTrue((evidence_roots[1] / "ApplicationFoundation-enumeration.json").is_file())
                    self.assertTrue(all(any(evidence_root.glob("*.log")) for evidence_root in evidence_roots))
                    http_enumeration = json.loads(
                        (evidence_roots[0] / "AppHTTP-enumeration.json").read_text())
                    http_identities = [entry["identifier"]
                                       for value in http_enumeration["values"]
                                       for entry in value["enabledTests"]]
                    self.assertEqual(len(http_identities), 15)
                    self.assertIn(
                        "AppHostedTests/AppHostedUITests/BrowserDownloadHTTPTests/"
                        "priorPageHistorySurvivesNativeDownloadConversion(profile:)",
                        http_identities,
                    )
                    self.assertIn("HTTP matrix rows for originatingMatrix(profile:row:): 16",
                                  result.stdout)
                    self.assertIn("HTTP matrix rows for slowCancellation(profile:knownLength:): 4",
                                  result.stdout)
                    for row in (
                        ".persistentPrivate, .attachment", ".persistentPrivate, .inline",
                        ".persistentPrivate, .octet", ".persistentPrivate, .redirect",
                        ".persistentPrivate, .protected", ".persistentPrivate, .post",
                        ".persistentPrivate, .blob", ".persistentPrivate, .attribute",
                        ".ephemeral, .attachment", ".ephemeral, .inline", ".ephemeral, .octet",
                        ".ephemeral, .redirect", ".ephemeral, .protected", ".ephemeral, .post",
                        ".ephemeral, .blob", ".ephemeral, .attribute",
                        ".persistentPrivate, true", ".persistentPrivate, false",
                        ".ephemeral, true", ".ephemeral, false",
                    ):
                        self.assertIn(
                            f"HTTP matrix row: arguments='{row}' result=Passed",
                            result.stdout,
                        )
                self.assert_builds_cleaned()

    def test_app_enumeration_uses_the_built_spec_and_records_zero_test_runs(self):
        result = self.run_make("test-app")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        enumerations_path = self.fixture.root / "enumerated.jsonl"
        enumerations = [json.loads(line) for line in enumerations_path.read_text().splitlines()]
        app_enumerations = [args for args in enumerations
                            if Path(args[args.index("-test-enumeration-output-path") + 1]).name
                            == "App-enumeration.json"]
        self.assertEqual(len(app_enumerations), 1)
        app = app_enumerations[0]
        builds_path = self.fixture.root / "builds.jsonl"
        builds = [json.loads(line) for line in builds_path.read_text().splitlines()]
        app_builds = [args for args in builds if "build-for-testing" in args and
                      args[args.index("-scheme") + 1] == "App"]
        self.assertEqual(len(app_builds), 1)
        app_derived_data = Path(app_builds[0][app_builds[0].index("-derivedDataPath") + 1])
        expected_xctestrun = (app_derived_data / "Build" / "Products" /
                              "App_iphonesimulator27.2-arm64.xctestrun")
        self.assertEqual(app[app.index("-xctestrun") + 1], str(expected_xctestrun))
        self.assertEqual(app[app.index("-destination") + 1],
                         f"platform=iOS Simulator,id={UDID}")
        for build_option in ("-workspace", "-scheme", "-configuration",
                             "-clonedSourcePackagesDirPath", "-derivedDataPath",
                             "-skipMacroValidation"):
            self.assertNotIn(build_option, app)
        self.assertEqual([arg for arg in app if arg.startswith("-skip-testing:")], [
            "-skip-testing:AppTests/RootSurfaceSnapshotTests",
            "-skip-testing:AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/"
            "rootPresentationSnapshotsCoverPrimaryShellStates()",
            "-skip-testing:AppHostedTests/AppHostedUITests/BrowserDownloadHTTPTests",
        ])
        enumeration_flags = [
            "-enumerate-tests", "-test-enumeration-style", "flat",
            "-test-enumeration-format", "json", "-test-enumeration-output-path",
            str(Path(app[app.index("-test-enumeration-output-path") + 1])),
        ]
        app_without_destination = app[app.index("-enumerate-tests"):]
        self.assertEqual(app_without_destination[:len(enumeration_flags)], enumeration_flags)
        self.assertEqual(app[-1], "test-without-building")
        evidence_root = Path(re.search(
            r"(?m)^functional test evidence: (.+)$", result.stdout).group(1))
        enumeration_bundle = Path(app[app.index("-resultBundlePath") + 1])
        self.assertEqual(enumeration_bundle, evidence_root / "App-enumeration.xcresult")
        self.assertEqual(json.loads(
            (enumeration_bundle / "fixture-enumeration.json").read_text()), {"testRuns": 0})

        http_enumeration = next(args for args in enumerations
                                if Path(args[args.index("-test-enumeration-output-path") + 1]).name
                                == "AppHTTP-enumeration.json")
        self.assertNotIn("-xctestrun", http_enumeration)
        self.assertEqual(http_enumeration[http_enumeration.index("-destination") + 1],
                         f"platform=iOS Simulator,id={UDID}")
        self.assertEqual(http_enumeration[-1], "test")
        executions = self.fixture.executions()
        self.assertEqual(len(executions), 2)
        self.assertTrue(all("-enumerate-tests" not in args for args in executions))

    def test_app_enumeration_rejects_missing_or_ambiguous_specs_and_runs_http(self):
        for mode, count in (("missing", 0), ("ambiguous", 2)):
            with self.subTest(mode=mode):
                (self.fixture.root / "enumerated.jsonl").unlink(missing_ok=True)
                result = self.run_make("test-app", {"xctestrun": mode})
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                combined_output = result.stdout + result.stderr
                self.assertIn(f"Expected exactly one App_iphonesimulator*.xctestrun; found {count}",
                              combined_output)
                self.assertIn("App-enumeration=1", combined_output)
                self.assertNotIn("AppHTTP-exact-identities=", combined_output)

                enumerations_path = self.fixture.root / "enumerated.jsonl"
                enumerations = [json.loads(line) for line in enumerations_path.read_text().splitlines()]
                self.assertEqual(
                    [Path(args[args.index("-test-enumeration-output-path") + 1]).name
                     for args in enumerations], ["AppHTTP-enumeration.json"])
                executions = self.fixture.executions()
                self.assertEqual(len(executions), 2)
                self.assertTrue(any(args[-1] == "test-without-building" and
                                    "-only-testing:AppHostedTests/AppHostedUITests/BrowserDownloadHTTPTests"
                                    in args for args in executions))
                evidence_root = Path(re.search(
                    r"(?m)^functional test evidence: (.+)$", result.stdout).group(1))
                self.assertFalse((evidence_root / "App-enumeration.xcresult").exists())
                self.assertTrue((evidence_root / "AppHTTP.xcresult" /
                                 "fixture-completed.json").is_file())
                self.assert_builds_cleaned()

    def test_later_failure_retains_earlier_completed_bundle_and_failure_status(self):
        for target in ("test", "test-snapshots"):
            with self.subTest(target=target):
                result = self.run_make(target, {"fail_on": 2})
                self.assertNotEqual(result.returncode, 0)
                paths = [Path(args[args.index("-resultBundlePath") + 1])
                         for args in self.fixture.executions()]
                expected_names = ["App.xcresult", "AppHTTP.xcresult", "ApplicationFoundation.xcresult"]
                expected_results = ["Passed", "Failed"]
                if target == "test":
                    expected_results = ["Passed", "Failed", "Passed"]
                    expected_names += ["App-iPadPrivacy.xcresult", "BrowserDownloadMultiScene.xcresult"]
                    expected_results += ["Passed", "Passed"]
                else:
                    expected_names = ["App.xcresult", "ApplicationFoundation.xcresult"]
                    expected_results = ["Passed", "Failed"]
                self.assertEqual([path.name for path in paths], expected_names)
                for path in paths:
                    self.assertTrue(path.is_dir(), f"Native result path was removed: {path}")
                self.assertEqual([json.loads((path / "fixture-completed.json").read_text())
                                  ["result"] for path in paths], expected_results)
                self.assert_builds_cleaned()

    def test_functional_failure_collects_command_and_validation_errors_and_runs_later_lanes(self):
        result = self.run_make("test", {"fail_on": 1, "partial_on": 1, "missing_on": 2})
        self.assertNotEqual(result.returncode, 0)
        paths = [Path(args[args.index("-resultBundlePath") + 1])
                 for args in self.fixture.executions()]
        self.assertEqual([path.name for path in paths], [
            "App.xcresult", "AppHTTP.xcresult", "ApplicationFoundation.xcresult",
            "App-iPadPrivacy.xcresult", "BrowserDownloadMultiScene.xcresult",
        ])
        self.assertTrue((paths[0] / "fixture-partial").is_file())
        self.assertFalse(paths[1].exists())
        self.assertTrue(all((path / "fixture-completed.json").is_file() for path in paths[2:]))
        self.assertIn("App-xcodebuild=65", result.stderr)
        self.assertIn("AppHTTP-exact-identities=1", result.stderr)
        self.assertIn("Error 65", result.stderr)
        self.assert_builds_cleaned()

    def test_functional_identity_validation_rejects_missing_and_skipped_required_ui_tests(self):
        for plan, reason in (({"omit_ui_identity": True}, "test identities differ"),
                             ({"skip_ui_identity": True}, "skipped")):
            with self.subTest(plan=plan):
                result = self.run_make("test", plan)
                self.assertNotEqual(result.returncode, 0)
                combined_output = result.stdout + result.stderr
                self.assertIn(reason, combined_output)
                self.assertIn("BrowserDownloadMultiScene-validation=1", combined_output)
                self.assertEqual(len(self.fixture.executions()), 5)
                self.assert_builds_cleaned()

    def test_functional_suites_reject_missing_required_cases_and_unexpected_skips(self):
        privacy = "AppHostedUITests/ScenePrivacyCoverTests/rootPrivacyCoverSynchronouslyOccludesPrivateSentinel(_:)"
        for mutation, identity, label in (
            ("omit_case", HTTP_MATRIX_ID, "AppHTTP-exact-identities"),
            ("omit_case", "BrowserDownloadSceneEvidenceTests/testPassiveRootRejectsCachedConfirmationAfterLiveRevisionAdvances()", "App-exact-identities"),
            ("skip_case", "RootFeatureTests/backgroundReturnCancelsPendingHiddenVerification()", "ApplicationFoundation-exact-identities"),
            ("skip_case", privacy, "App-iPadPrivacy-validation"),
        ):
            with self.subTest(mutation=mutation, identity=identity):
                result = self.run_make("test", {mutation: identity})
                self.assertNotEqual(result.returncode, 0)
                combined_output = result.stdout + result.stderr
                self.assertIn(label + "=1", combined_output)
                self.assertEqual(len(self.fixture.executions()), 5)
                self.assert_builds_cleaned()

    def test_passing_http_parent_requires_each_argument_pair_to_pass_once(self):
        passing = self.fixture.http_matrix_arguments
        attachment = next(row for row in passing if row["name"] == ".persistentPrivate, .attachment")
        other_rows = [row for row in passing if row != attachment]
        skipped = dict(attachment, result="Skipped")
        unknown = dict(attachment, name=".persistentPrivate, .unknown")
        for scenario, rows, diagnostic in (
            ("parent only", [], attachment["name"]),
            ("missing attachment", other_rows, attachment["name"]),
            ("skipped attachment", [*other_rows, skipped], "Skipped"),
            ("substituted row", [*other_rows, unknown], unknown["name"]),
            ("duplicate instead of attachment", [*other_rows, other_rows[0]], other_rows[0]["name"]),
            ("extra copy of attachment", [*passing, attachment], attachment["name"]),
        ):
            with self.subTest(scenario=scenario):
                self.fixture.http_matrix_arguments = rows
                result = self.run_make("test")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                combined_output = result.stdout + result.stderr
                self.assertIn("App HTTP parameter rows differ for originatingMatrix(profile:row:)", combined_output)
                self.assertIn(diagnostic, combined_output)
                self.assertIn("AppHTTP-exact-identities=1", combined_output)
                paths = [Path(args[args.index("-resultBundlePath") + 1])
                         for args in self.fixture.executions()]
                self.assertEqual([path.name for path in paths], [
                    "App.xcresult", "AppHTTP.xcresult", "ApplicationFoundation.xcresult",
                    "App-iPadPrivacy.xcresult", "BrowserDownloadMultiScene.xcresult",
                ])
                self.assertEqual([json.loads((path / "fixture-completed.json").read_text())["result"]
                                  for path in paths], ["Passed"] * 5)
                self.assert_builds_cleaned()

    def test_http_matrix_rejects_rows_from_another_test_bundle_target(self):
        result = self.run_make("test-app", {"wrong_http_target": True})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "App HTTP matrix parent target identity is missing or duplicated: "
            "AppHostedTests/AppHostedUITests/BrowserDownloadHTTPTests/"
            "originatingMatrix(profile:row:) (count 0)",
            result.stdout + result.stderr,
        )

    def test_snapshot_app_failure_still_runs_package_and_remains_failed(self):
        result = self.run_make("test-snapshots", {"fail_on": 1})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.fixture.executions()), 2)
        self.assertEqual({path.name for path in self.bundles()},
                         {"App.xcresult", "ApplicationFoundation.xcresult"})
        self.assert_builds_cleaned()

    def test_readiness_barrier_survives_large_mock_output(self):
        output_pressure_bytes = 256 * 1024
        build_root, results_root = self.invocation_roots_for("readiness pressure")
        self.stop_during_phase(
            "test", abrupt=False, output_pressure_bytes=output_pressure_bytes,
            build_root=build_root, results_root=results_root,
        )
        pressure = json.loads((self.fixture.root / "pre-barrier-output.json").read_text())
        self.assertEqual(pressure, {
            "stdout_bytes": output_pressure_bytes,
            "stderr_bytes": output_pressure_bytes,
        })

    def test_graceful_termination_preserves_completed_and_partial_bundles(self):
        for target in ("test", "test-snapshots"):
            with self.subTest(target=target):
                build_root, results_root = self.invocation_roots_for(f"graceful {target}")
                self.stop_during_phase(target, abrupt=False, build_root=build_root,
                                       results_root=results_root)
                current = [Path(args[args.index("-resultBundlePath") + 1])
                           for args in self.fixture.executions()]
                self.assertEqual(len(current), 2)
                self.assertTrue((current[0] / "fixture-completed.json").is_file())
                self.assertTrue((current[1] / "fixture-partial").is_file())
                self.assertFalse((current[1] / "fixture-completed.json").exists())
                self.assert_builds_cleaned(build_root)

    def test_abrupt_termination_retains_evidence_without_exit_traps(self):
        for target in ("test", "test-snapshots"):
            with self.subTest(target=target):
                build_root, results_root = self.invocation_roots_for(f"abrupt {target}")
                self.stop_during_phase(target, abrupt=True, build_root=build_root,
                                       results_root=results_root)
                current = [Path(args[args.index("-resultBundlePath") + 1])
                           for args in self.fixture.executions()]
                self.assertEqual(len(current), 2)
                for bundle in current:
                    self.assertTrue(bundle.is_relative_to(results_root))
                    self.assertTrue((bundle / "fixture-partial").is_file())
                self.assertTrue((current[0] / "fixture-completed.json").is_file())
                self.assertFalse((current[1] / "fixture-completed.json").exists())
        self.assert_owner_data_intact()

    def test_partial_bundle_is_retained_but_never_qualifies_as_complete(self):
        for target in ("test", "test-snapshots"):
            with self.subTest(target=target):
                result = self.run_make(target, {"partial_on": 1})
                self.assertNotEqual(result.returncode, 0)
                first = Path(self.fixture.executions()[0][
                    self.fixture.executions()[0].index("-resultBundlePath") + 1])
                self.assertTrue((first / "fixture-partial").is_file())
                self.assertFalse((first / "fixture-completed.json").exists())
                self.assert_builds_cleaned()

    def test_repeated_invocations_leave_separate_evidence_unchanged(self):
        for target in ("test", "test-snapshots"):
            with self.subTest(target=target):
                result = self.run_make(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                old = {path: (path / "fixture-completed.json").read_bytes()
                       for path in self.bundles()}
                previous_directories = {path.parent for path in self.bundles()}
                result = self.run_make(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                current = [Path(args[args.index("-resultBundlePath") + 1])
                           for args in self.fixture.executions()]
                self.assertFalse(previous_directories.intersection(path.parent for path in current))
                for path, content in old.items():
                    self.assertEqual((path / "fixture-completed.json").read_bytes(), content)
                self.assert_builds_cleaned()

    def test_partial_required_ui_bundle_cannot_pass_the_identity_checker(self):
        result = self.run_make("test", {"partial_on": 5})
        self.assertNotEqual(result.returncode, 0)
        commands = self.fixture.executions()
        self.assertEqual(len(commands), 5)
        bundle = Path(commands[-1][commands[-1].index("-resultBundlePath") + 1])
        self.assertEqual(bundle.name, "BrowserDownloadMultiScene.xcresult")
        self.assertTrue((bundle / "fixture-partial").is_file())
        self.assertFalse((bundle / "fixture-completed.json").exists())
        self.assert_builds_cleaned()

    def test_functional_default_results_are_retained_after_failure(self):
        result = self.run_make("test-app", {"fail_on": 1}, retained=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        evidence_line = re.search(r"(?m)^functional test evidence: (.+)$", result.stdout)
        self.assertIsNotNone(evidence_line, result.stdout)
        evidence_root = Path(evidence_line[1])
        self.assertTrue(evidence_root.resolve().is_relative_to(
            (self.checkout / ".build" / "TestResults").resolve()))
        self.assertTrue(evidence_root.is_dir())
        self.assertNotEqual(evidence_root, self.build_root)
        paths = [Path(args[args.index("-resultBundlePath") + 1])
                 for args in self.fixture.executions()]
        self.assertEqual([path.name for path in paths], ["App.xcresult", "AppHTTP.xcresult"])
        self.assertTrue(all(path.parent == evidence_root and path.is_dir() for path in paths))
        self.assertEqual(json.loads((paths[0] / "fixture-completed.json").read_text())["result"], "Failed")
        self.assertEqual(json.loads((paths[1] / "fixture-completed.json").read_text())["result"], "Passed")
        self.assertTrue((evidence_root / "App-xcodebuild.log").is_file())
        self.assertTrue((evidence_root / "AppHTTP-xcodebuild.log").is_file())
        self.assertTrue((evidence_root / "App-enumeration.json").is_file())
        self.assertTrue((evidence_root / "AppHTTP-enumeration.json").is_file())
        self.assert_builds_cleaned()

    def test_unconfigured_snapshot_results_keep_temporary_cleanup_behavior(self):
        for failure in (False, True):
            with self.subTest(failure=failure):
                result = self.run_make("test-snapshots", {"fail_on": 2} if failure else {},
                                       retained=False)
                self.assertEqual(result.returncode == 0, not failure,
                                 result.stdout + result.stderr)
                self.assertEqual(self.bundles(), [])
                for args in self.fixture.executions():
                    bundle = Path(args[args.index("-resultBundlePath") + 1])
                    self.assertTrue(bundle.is_relative_to(self.build_root))
                    self.assertFalse(bundle.exists())
                self.assert_builds_cleaned()


class WorkflowEvidenceTests(unittest.TestCase):
    @staticmethod
    def steps():
        source = (ROOT / ".github/workflows/tests.yml").read_text()
        return re.split(r"(?m)^(?:      - name: |  [\w-]+:\s*$)", source)[1:]

    @staticmethod
    def render(source, run_id, attempt, lane=None):
        values = {"run_id": run_id, "run_attempt": attempt}
        rendered = re.sub(r"\$\{\{\s*github\.(run_id|run_attempt)\s*\}\}",
                          lambda match: values[match[1]], source)
        if lane is not None:
            rendered = re.sub(r"\$\{\{\s*matrix\.lane\s*\}\}", lane, rendered)
        return rendered

    def test_upload_names_preserve_every_gate_and_run_attempt(self):
        uploads = [step for step in self.steps() if "uses: actions/upload-artifact@" in step]
        self.assertEqual(len(uploads), 3)
        names = []
        for step in uploads:
            self.assertRegex(step, r"(?m)^        if: always\(\)$")
            self.assertNotRegex(step, r"(?m)^          overwrite: true$")
            match = re.search(r"(?m)^          name: (.+)$", step)
            self.assertIsNotNone(match)
            lanes = ("app", "application-foundation", "ipad-privacy", "browser-download-ui") \
                if "${{ matrix.lane }}" in match[1] else (None,)
            for lane in lanes:
                for run_id in ("7001", "7002"):
                    for attempt in ("1", "2"):
                        name = self.render(match[1], run_id, attempt, lane)
                        self.assertIn(run_id, name)
                        self.assertIn(attempt, name.rsplit(run_id, 1)[-1])
                        self.assertNotIn("${{", name)
                        names.append(name)
        self.assertEqual(len(set(names)), 24)

    def test_snapshot_failure_reporting_names_the_attempt_without_claiming_pass(self):
        report = next(step for step in self.steps()
                      if step.startswith("Report snapshot qualification status\n"))
        script = textwrap.dedent(report.split("        run: |\n", 1)[1])
        artifact_step = next(step for step in self.steps()
                             if step.startswith("Upload 2x iPad snapshot evidence\n"))
        artifact = re.search(r"(?m)^          name: (.+)$", artifact_step)[1]
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            executable = directory / "make"
            executable.write_text('#!/bin/sh\nprintf unexpected > "$FIXTURE_MAKE_MARKER"\nexit 99\n')
            executable.chmod(0o755)
            marker = directory / "unexpected-command"
            for outcome in ("failure", "cancelled"):
                with self.subTest(outcome=outcome):
                    summary = Path(temporary) / outcome
                    result = subprocess.run(
                        ["bash", "-e", "-o", "pipefail", "-c", self.render(script, "7001", "2")],
                        env=dict(os.environ, SNAPSHOT_OUTCOME=outcome, UPLOAD_OUTCOME="success",
                                 GITHUB_STEP_SUMMARY=str(summary), FIXTURE_MAKE_MARKER=str(marker),
                                 PATH=str(directory) + os.pathsep + os.environ["PATH"]),
                        cwd=directory, text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    text = summary.read_text()
                    self.assertFalse(marker.exists(), "Markdown command must remain literal")
                    self.assertIn("| Command | `make test-snapshots` |", text)
                    self.assertIn(self.render(artifact, "7001", "2"), text)
                    self.assertIn("| Snapshot step outcome | " + outcome + " |", text)
                    status = "failed" if outcome == "failure" else "did not complete"
                    self.assertIn("| Qualification status | " + status + " |", text)
                    self.assertNotIn("| Qualification status | automated snapshot success", text)


class NativeSnapshotRecipeTests(DestinationFixture, unittest.TestCase):
    def native_run(self, scenario="", scale="3", **overrides):
        checkout = self.root / "native-checkout"
        checkout.mkdir(exist_ok=True)
        shutil.copy2(ROOT / "Makefile", checkout / "Makefile")
        scripts = checkout / "Scripts"
        if not scripts.exists():
            scripts.symlink_to(ROOT / "Scripts", target_is_directory=True)
        self.write_inventory()
        self.env.update(SCENARIO=scenario, NATIVE_SNAPSHOT_QUALIFICATION="ambient",
                        NATIVE_SNAPSHOT_EXPECTED_SCALE="ambient", SNAPSHOT_TESTING_RECORD="all")
        command = [MAKE, "test-native-snapshots", f"XCODE_WRAPPER={self.wrapper}",
                   f"PATH={self.env['PATH']}", f"NATIVE_SNAPSHOT_EXPECTED_SCALE={scale}",
                   f"NATIVE_SNAPSHOT_BUILD_DIRECTORY={self.root / 'external build'}",
                   f"TEST_RESULTS_DIRECTORY={self.root / 'evidence'}",
                   f"SOURCE_PACKAGES_DIRECTORY={self.root / 'package cache'}"]
        command += [f"{key}={value}" for key, value in overrides.items()]
        return subprocess.run(command, cwd=checkout, env=self.env, text=True, capture_output=True)

    def test_native_recipe_validates_and_preserves_both_bundles(self):
        result = self.native_run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = self.executions()
        self.assertEqual(len(commands), 2)
        selectors = [next(arg for arg in args if arg.startswith("-only-testing:")) for args in commands]
        self.assertEqual(selectors, ["-only-testing:AppTests/RootSurfaceSnapshotTests",
                                    "-only-testing:AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/"
                                    "rootPresentationSnapshotsCoverPrimaryShellStates()"])
        for args in commands:
            self.assertEqual(args[args.index("-scheme") + 1], "App")
            self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "NO")
            self.assertEqual(args[args.index("-collect-test-diagnostics") + 1], "never")
            self.assertTrue(args[args.index("-derivedDataPath") + 1].startswith(str(self.root / "external build")))
            self.assertEqual(args[args.index("-clonedSourcePackagesDirPath") + 1], str(self.root / "package cache"))
        self.assertEqual(commands[0][commands[0].index("-derivedDataPath") + 1],
                         commands[1][commands[1].index("-derivedDataPath") + 1])
        environments = [json.loads(line) for line in (self.root / "environment.jsonl").read_text().splitlines()]
        for env in environments:
            for key in ("NATIVE_SNAPSHOT_QUALIFICATION", "NATIVE_SNAPSHOT_EXPECTED_SCALE", "SNAPSHOT_TESTING_RECORD"):
                self.assertNotIn(key, env)
            self.assertEqual(env["TEST_RUNNER_NATIVE_SNAPSHOT_QUALIFICATION"], "1")
            self.assertEqual(env["TEST_RUNNER_NATIVE_SNAPSHOT_EXPECTED_SCALE"], "3")
            self.assertEqual(env["TEST_RUNNER_SNAPSHOT_TESTING_RECORD"], "never")
        self.assertEqual(len(list((self.root / "evidence").glob("*/*.xcresult"))), 2)
        self.assertEqual(len(list((self.root / "evidence").glob("*/*-attachments/manifest.json"))), 2)

    def test_native_recipe_accepts_explicit_2x_destination(self):
        name = "iPad Pro 11-inch (M5)"
        self.devices = {"devices": {RUNTIME: [self.device(name=name)]}}
        self.destinations = [self.destination(name=name)]
        result = self.native_run(scale="2", NATIVE_SNAPSHOT_DESTINATION=f"platform=iOS Simulator,name={name},OS=27.2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_native_recipe_keeps_wrapper_chatter_out_of_summary_json(self):
        self.wrapper.write_text('#!/usr/bin/env bash\n'
                                'printf "Verified simulator runtime: fixture\\n"\n'
                                'exec "$@"\n')
        result = self.native_run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        evidence, = (self.root / "evidence").iterdir()
        for target, count in (("AppTests", 4), ("AppHostedTests", 1)):
            summary = json.loads((evidence / f"{target}-summary.json").read_text())
            self.assertEqual(summary["totalTestCount"], count)
            self.assertIn("Verified simulator runtime: fixture",
                          (evidence / f"{target}-summary.log").read_text())
        self.assertEqual(len(self.executions()), 2)

    def test_native_recipe_uses_suggested_name_for_opaque_exports(self):
        result = self.native_run("opaque-filenames")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_native_recipe_keeps_fresh_evidence_for_each_run(self):
        for _ in range(2):
            result = self.native_run()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(list((self.root / "evidence").glob("*/*.xcresult"))), 4)

    def test_native_recipe_checks_evidence_with_python_optimization_enabled(self):
        self.env["PYTHONOPTIMIZE"] = "1"
        result = self.native_run("validation")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.executions()), 2)

    def test_native_recipe_retains_default_evidence_after_build_cleanup(self):
        result = self.native_run(TEST_RESULTS_DIRECTORY="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build = self.root / "external build"
        self.assertEqual(len(list((build / "TestResults").glob("*/*.xcresult"))), 2)
        self.assertEqual(list(build.glob("xcodebuild-native-snapshot.*")), [])

    def test_native_recipe_rejects_bad_evidence_and_attempts_both(self):
        for scenario in ("zero", "extra", "skipped", "failed", "missing-count", "bad-summary", "boolean-count", "scale", "reference",
                         "qualification", "expected", "record", "validation", "schema", "pid", "process",
                         "target", "capture", "missing", "duplicate", "attribution", "bad-json",
                         "missing-file", "bad-manifest", "no-manifest", "xcode-failure",
                         "missing-bundle", "summary-error", "export-error"):
            with self.subTest(scenario=scenario):
                (self.root / "executed.jsonl").unlink(missing_ok=True)
                result = self.native_run(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(self.executions()), 2, result.stdout + result.stderr)

    def test_native_recipe_rejects_unsupported_scale_before_execution(self):
        result = self.native_run(scale="4")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.executions(), [])


class XcodeEnumerationTests(unittest.TestCase):
    def validator_namespace(self):
        path = ROOT / "Scripts/assert-xcresult-tests.py"
        namespace = {"__name__": "xcresult_validator_test"}
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), namespace)
        return namespace

    def test_flat_json_reads_only_enabled_identifier_records(self):
        validator = self.validator_namespace()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "enumeration.json"
            enabled = "AppHostedTests/AppHostedUITests/BrowserDownloadHTTPTests/originatingMatrix(profile:row:)"
            disabled = "AppHostedTests/AppHostedUITests/BrowserDownloadHTTPTests/disabledTest()"
            path.write_text(json.dumps({
                "errors": [],
                "values": [{
                    "testPlan": "App",
                    "enabledTests": [{"identifier": enabled}],
                    "disabledTests": [{"identifier": disabled}],
                }],
            }))
            self.assertEqual(validator["enumerated_test_identifiers"](path), [enabled])

    def test_flat_json_rejects_reported_errors_and_malformed_values(self):
        validator = self.validator_namespace()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "enumeration.json"
            for document in (
                {"errors": ["scheme unavailable"], "values": []},
                {"errors": [], "values": [{"enabledTests": [], "disabledTests": []}]},
            ):
                with self.subTest(document=document):
                    path.write_text(json.dumps(document))
                    with self.assertRaises(ValueError):
                        validator["enumerated_test_identifiers"](path)

    def test_duplicate_full_identities_reject_terminal_parenthesis_aliases(self):
        validator = self.validator_namespace()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "enumeration.json"
            identity = "TargetOne/Namespace/Suite/testExample"
            path.write_text(json.dumps({
                "errors": [],
                "values": [{
                    "testPlan": "App",
                    "enabledTests": [
                        {"identifier": identity + "()"},
                        {"identifier": identity},
                    ],
                    "disabledTests": [],
                }],
            }))
            arguments = [
                "assert-xcresult-tests.py", "--bundle", str(Path(directory) / "unused.xcresult"),
                "--expected-device-id", UDID, "--expected-device-name", NAME,
                "--expected-os-version", "27.2", "--expected-tests-file", str(path),
            ]
            with patch.object(sys, "argv", arguments), patch("sys.stderr", io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    validator["main"]()
            self.assertEqual(raised.exception.code, 2)

    def test_enumerated_identity_rejects_same_method_from_another_target(self):
        validator = self.validator_namespace()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "enumeration.json"
            path.write_text(json.dumps({
                "errors": [],
                "values": [{
                    "testPlan": "TestPlan",
                    "enabledTests": [{
                        "identifier": "TargetOne/Namespace/Suite/testExample()",
                    }],
                    "disabledTests": [],
                }],
            }))
            target_url = "test://com.apple.xcode/TestPlan/TargetTwo"
            case_url = target_url + "/Namespace/Suite/testExample()"
            report = {"testNodes": [{
                "nodeType": "Test Plan",
                "name": "TestPlan",
                "children": [{
                    "nodeType": "Unit test bundle",
                    "name": "TargetTwo",
                    "nodeIdentifierURL": target_url,
                    "children": [{
                        "nodeType": "Test Suite",
                        "name": "Namespace",
                        "nodeIdentifierURL": target_url + "/Namespace",
                        "children": [{
                            "nodeType": "Test Suite",
                            "name": "Suite",
                            "nodeIdentifierURL": target_url + "/Namespace/Suite",
                            "children": [{
                                "nodeType": "Test Case",
                                "name": "testExample()",
                                "nodeIdentifier": "Namespace/Suite/testExample()",
                                "nodeIdentifierURL": case_url,
                                "result": "Passed",
                            }],
                        }],
                    }],
                }],
            }]}
            summary = {
                "result": "Passed", "totalTestCount": 1, "passedTests": 1,
                "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                "devicesAndConfigurations": [{"device": {
                    "deviceId": UDID, "deviceName": NAME, "osVersion": "27.2",
                    "platform": "iOS Simulator",
                }}],
            }
            validator["xcresult_json"] = lambda _bundle, command: (
                summary if command == "summary" else report)
            arguments = [
                "assert-xcresult-tests.py", "--bundle", str(Path(directory) / "unused.xcresult"),
                "--expected-device-id", UDID, "--expected-device-name", NAME,
                "--expected-os-version", "27.2", "--expected-tests-file", str(path),
            ]
            with patch.object(sys, "argv", arguments), patch("sys.stdout", io.StringIO()), \
                    patch("sys.stderr", io.StringIO()):
                self.assertEqual(validator["main"](), 1)


if __name__ == "__main__":
    unittest.main()
