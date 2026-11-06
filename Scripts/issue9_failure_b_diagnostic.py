#!/usr/bin/env python3
"""Run the hosted privacy snapshot case ten times on the canonical iPad simulator."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable
from urllib.parse import unquote, urlparse

BASELINE_SHA = "a20d5e1bc94e0c7305bebd91ad2d4ab35a81412e"
DIAGNOSTIC_TAG_PREFIX = "issue9-failure-b-20261105-"
XCODEBUILD_SELECTOR = (
    "AppHostedTests/AppHostedUITests/ScenePrivacyCoverTests/"
    "rootPrivacySnapshotsCoverLifecycleStates()"
)
TEST_CASE_IDENTIFIER = (
    "AppHostedUITests/ScenePrivacyCoverTests/"
    "rootPrivacySnapshotsCoverLifecycleStates()"
)
TEST_CASE_IDENTIFIER_URL = (
    "test://com.apple.xcode/App/AppHostedTests/"
    "AppHostedUITests/ScenePrivacyCoverTests/"
    "rootPrivacySnapshotsCoverLifecycleStates()"
)
SIMULATOR_NAME = "iPad Pro 11-inch (M5)"
SIMULATOR_TYPE_IDENTIFIER = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"
EXPECTED_DEVELOPER_DIR = "/Applications/Xcode_27.1.app/Contents/Developer"
SYSTEM_XCODE_SELECT = "/usr/bin/xcode-select"
SYSTEM_XCRUN = "/usr/bin/xcrun"
EXPECTED_RUNTIME_VERSION = "27.0"
EXPECTED_RUNTIME_BUILD = "24A434"
EXPECTED_XCODE_VERSION = "27.1"
EXPECTED_XCODE_BUILD = "27A9275"
ITERATIONS = 10
PER_ITERATION_TIMEOUT_SECONDS = 540
DIAGNOSTIC_FILES = (
    ".github/workflows/issue9-failure-b-diagnostic.yml",
    "Scripts/issue9_failure_b_diagnostic.py",
    "Scripts/measure_snapshot_pngs.swift",
)
IMAGE_PAIR = re.compile(r'@[-−]\s*"([^"]+)"\s*@\+\s*"([^"]+)"', re.DOTALL)
SNAPSHOT_NAME = re.compile(r'Snapshot "([^"]+)" does not match reference')


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def capture(command: list[str], env: dict[str, str]) -> tuple[int, str]:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            check=False,
        )
    except OSError as error:
        return 127, str(error)
    return result.returncode, result.stdout + result.stderr


def source_git(source: Path, *args: str, env: dict[str, str]) -> tuple[int, str]:
    return capture(["git", "-C", str(source), *args], env)


def parse_json(text: str) -> dict[str, Any]:
    value = json.loads(text)
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def path_is_within(path: str, directory: str) -> bool:
    try:
        candidate = Path(os.path.abspath(path))
        parent = Path(os.path.abspath(directory))
    except (OSError, ValueError):
        return False
    # Keep containment lexical so an Xcode tool symlink remains attached to its selected bundle.
    return candidate == parent or parent in candidate.parents


def find_test_case(node: object) -> dict[str, Any] | None:
    if isinstance(node, dict):
        if node.get("nodeIdentifier") == TEST_CASE_IDENTIFIER:
            return node
        for child in node.values():
            if isinstance(child, (dict, list)):
                found = find_test_case(child)
                if found is not None:
                    return found
    elif isinstance(node, list):
        for child in node:
            found = find_test_case(child)
            if found is not None:
                return found
    return None


def path_from_file_uri(value: str) -> Path | None:
    parsed = urlparse(value)
    if parsed.scheme != "file":
        return None
    return Path(unquote(parsed.path))


def copy_failure_images(
    attachments: Path,
    run_dir: Path,
    simulator: str,
    iteration: int,
) -> list[dict[str, object]]:
    pairs: list[dict[str, object]] = []
    if not attachments.is_dir():
        return pairs

    for issue_file in sorted(attachments.rglob("*.txt")):
        issue = issue_file.read_text(encoding="utf-8", errors="replace")
        name_match = SNAPSHOT_NAME.search(issue)
        snapshot_name = name_match.group(1) if name_match else issue_file.stem
        for index, (reference_uri, actual_uri) in enumerate(IMAGE_PAIR.findall(issue), start=1):
            pair_number = len(pairs) + 1
            pair_dir = run_dir / "snapshot-images" / f"{iteration:02d}-{pair_number:02d}"
            pair_dir.mkdir(parents=True, exist_ok=True)
            pair: dict[str, object] = {
                "simulator": simulator,
                "iteration": iteration,
                "snapshot": snapshot_name,
                "issueAttachment": str(issue_file),
                "referenceURI": reference_uri,
                "actualURI": actual_uri,
            }

            for key, uri, filename in (
                ("reference_path", reference_uri, "reference.png"),
                ("actual_path", actual_uri, "actual.png"),
            ):
                source_path = path_from_file_uri(uri)
                destination = pair_dir / filename
                exists = bool(source_path and source_path.is_file())
                pair[key] = str(destination) if exists else None
                pair[key.replace("_path", "_exists")] = exists
                if exists and source_path is not None:
                    shutil.copy2(source_path, destination)

            pair["difference_path"] = str(pair_dir / "difference.png")
            pairs.append(pair)
    return pairs


def collect_environment(
    source: Path,
    diagnostic: Path,
    env: dict[str, str],
) -> dict[str, Any]:
    developer_dir = env.get("DEVELOPER_DIR", "")
    xcodebuild = str(Path(developer_dir) / "usr/bin/xcodebuild") if developer_dir else ""

    def check(command: list[str]) -> dict[str, Any]:
        exit_code, output = capture(command, env)
        return {
            "command": command,
            "exit": exit_code,
            "output": output,
            "developerDirectory": env.get("DEVELOPER_DIR", ""),
        }

    def skipped(reason: str) -> dict[str, Any]:
        return {"command": [], "exit": None, "output": f"Skipped: {reason}"}

    checks: dict[str, dict[str, Any]] = {
        "xcodeSelect": check([SYSTEM_XCODE_SELECT, "-p"]),
        "xcode": check([xcodebuild, "-version"]) if xcodebuild else {
            "command": [], "exit": 127, "output": "DEVELOPER_DIR is not set"
        },
        "sdks": skipped("selected Xcode did not pass qualification"),
        "swiftPath": skipped("selected Xcode did not pass qualification"),
        "runtimes": skipped("system xcrun has not been validated"),
        "devices": skipped("system xcrun or runtime inventory has not been validated"),
        "macos": check(["sw_vers"]),
        "uname": check(["uname", "-a"]),
    }

    xcode_lines = checks["xcode"]["output"].splitlines()
    xcode_version = next((line for line in xcode_lines if line.startswith("Xcode ")), "")
    xcode_build = next(
        (line.removeprefix("Build version ") for line in xcode_lines if line.startswith("Build version ")),
        "",
    )
    exact_xcode = (
        developer_dir == EXPECTED_DEVELOPER_DIR
        and checks["xcode"]["exit"] == 0
        and xcode_version == f"Xcode {EXPECTED_XCODE_VERSION}"
        and xcode_build == EXPECTED_XCODE_BUILD
    )

    swift_path = ""
    swift_path_matches_developer_directory = False
    runtime: dict[str, Any] | None = None
    runtime_candidates: list[dict[str, Any]] = []
    matching_devices: list[dict[str, Any]] = []
    simulator_candidates: list[dict[str, Any]] = []
    parse_error = ""
    parse_error_source = ""

    if exact_xcode:
        checks["sdks"] = check([xcodebuild, "-showsdks"])
        checks["swiftPath"] = check([SYSTEM_XCRUN, "--find", "swift"])
        swift_path = checks["swiftPath"]["output"].strip()
        swift_path_matches_developer_directory = (
            checks["swiftPath"]["exit"] == 0
            and bool(swift_path)
            and path_is_within(swift_path, EXPECTED_DEVELOPER_DIR)
            and checks["swiftPath"].get("developerDirectory") == EXPECTED_DEVELOPER_DIR
        )
        if swift_path_matches_developer_directory:
            checks["runtimes"] = check([SYSTEM_XCRUN, "simctl", "list", "-j", "runtimes"])
            if checks["runtimes"]["exit"] == 0:
                try:
                    runtimes_data = parse_json(checks["runtimes"]["output"])
                    if not isinstance(runtimes_data, dict):
                        raise ValueError("runtime inventory root must be a JSON object")
                    if not isinstance(runtimes_data.get("runtimes"), list):
                        raise ValueError("runtime inventory must contain a runtimes list")
                    if any(not isinstance(item, dict) for item in runtimes_data["runtimes"]):
                        raise ValueError("runtime inventory entries must be JSON objects")
                except (ValueError, json.JSONDecodeError) as error:
                    parse_error = str(error)
                    parse_error_source = "runtime inventory"
                else:
                    runtime_candidates = [
                        {
                            "version": item.get("version"),
                            "buildversion": item.get("buildversion"),
                            "identifier": item.get("identifier"),
                            "isAvailable": item.get("isAvailable"),
                        }
                        for item in runtimes_data["runtimes"]
                    ]
                    runtime = next(
                        (
                            item for item in runtimes_data["runtimes"]
                            if item.get("version") == EXPECTED_RUNTIME_VERSION
                            and item.get("buildversion") == EXPECTED_RUNTIME_BUILD
                            and item.get("isAvailable") is True
                        ),
                        None,
                    )
                    checks["devices"] = check(
                        [SYSTEM_XCRUN, "simctl", "list", "-j", "devices", "available"]
                    )
                    if checks["devices"]["exit"] == 0:
                        try:
                            devices_data = parse_json(checks["devices"]["output"])
                            if not isinstance(devices_data, dict):
                                raise ValueError("device inventory root must be a JSON object")
                            if not isinstance(devices_data.get("devices"), dict):
                                raise ValueError("device inventory must contain a devices object")
                            if any(
                                not isinstance(devices, list)
                                or any(not isinstance(device, dict) for device in devices)
                                for devices in devices_data["devices"].values()
                            ):
                                raise ValueError(
                                    "device inventory entries must be lists of JSON objects"
                                )
                        except (ValueError, json.JSONDecodeError) as error:
                            parse_error = str(error)
                            parse_error_source = "device inventory"
                        else:
                            simulator_candidates = [
                                {**device, "runtimeIdentifier": runtime_key}
                                for runtime_key, devices in devices_data["devices"].items()
                                for device in devices
                                if device.get("name") == SIMULATOR_NAME
                            ]
                            if runtime is not None:
                                runtime_id = runtime.get("identifier")
                                matching_devices = [
                                    device
                                    for runtime_key, devices in devices_data["devices"].items()
                                    if runtime_key == runtime_id
                                    for device in devices
                                    if device.get("name") == SIMULATOR_NAME
                                ]

    git_env = dict(env, GIT_OPTIONAL_LOCKS="0")
    source_sha_rc, source_sha = source_git(source, "rev-parse", "HEAD", env=git_env)
    source_status_rc, source_status = source_git(
        source, "status", "--porcelain", "--untracked-files=all", env=git_env
    )
    diagnostic_sha_rc, diagnostic_sha = source_git(diagnostic, "rev-parse", "HEAD", env=git_env)
    diagnostic_status_rc, diagnostic_status = source_git(
        diagnostic, "status", "--porcelain", "--untracked-files=no", env=git_env
    )
    tracked_paths_rc, tracked_paths = source_git(
        diagnostic, "ls-files", "--error-unmatch", *DIAGNOSTIC_FILES, env=git_env
    )
    diagnostic_diff_rc, diagnostic_diff_output = source_git(
        diagnostic, "diff", "--quiet", "HEAD", "--", *DIAGNOSTIC_FILES, env=git_env
    )
    cached_diff_rc, cached_diff_output = source_git(
        diagnostic, "diff", "--cached", "--quiet", "HEAD", "--", *DIAGNOSTIC_FILES, env=git_env
    )
    destination_id = matching_devices[0].get("udid") if len(matching_devices) == 1 else None

    return {
        "event": {
            "name": env.get("GITHUB_EVENT_NAME", ""),
            "refType": env.get("GITHUB_REF_TYPE", ""),
            "refName": env.get("GITHUB_REF_NAME", ""),
            "sha": env.get("GITHUB_SHA", ""),
        },
        "runner": {
            "name": env.get("RUNNER_NAME", "unavailable"),
            "architecture": env.get("RUNNER_ARCH", "unavailable"),
            "imageOS": env.get("ImageOS", "unavailable"),
            "imageVersion": env.get("ImageVersion", "unavailable"),
        },
        "expected": {
            "baselineSHA": BASELINE_SHA,
            "diagnosticSHA": env.get("GITHUB_SHA", ""),
            "developerDirectory": EXPECTED_DEVELOPER_DIR,
            "xcodeVersion": EXPECTED_XCODE_VERSION,
            "xcodeBuild": EXPECTED_XCODE_BUILD,
            "simulatorName": SIMULATOR_NAME,
            "simulatorTypeIdentifier": SIMULATOR_TYPE_IDENTIFIER,
            "simulatorScale": "2x canonical snapshot destination",
            "runtimeVersion": EXPECTED_RUNTIME_VERSION,
            "runtimeBuild": EXPECTED_RUNTIME_BUILD,
            "testSelector": XCODEBUILD_SELECTOR,
            "iterations": ITERATIONS,
        },
        "observed": {
            "baselineSHA": source_sha.strip(),
            "baselineStatus": source_status,
            "diagnosticSHA": diagnostic_sha.strip(),
            "diagnosticStatus": diagnostic_status,
            "trackedDiagnosticFiles": tracked_paths.strip().splitlines(),
            "developerDirectory": developer_dir,
            "developerDirectoryMatchesExpected": developer_dir == EXPECTED_DEVELOPER_DIR,
            "xcodeSelectPath": checks["xcodeSelect"]["output"].strip(),
            "xcodeVersion": xcode_version,
            "xcodeBuild": xcode_build,
            "swiftPath": swift_path,
            "swiftPathMatchesDeveloperDirectory": swift_path_matches_developer_directory,
            "runtime": runtime,
            "runtimeCandidates": runtime_candidates,
            "simulator": matching_devices[0] if len(matching_devices) == 1 else None,
            "simulatorCandidates": simulator_candidates,
            "destinationID": destination_id,
            "baselineWorkspacePresent": (source / "App.xcworkspace").is_dir(),
        },
        "exitCodes": {
            "baselineRevision": source_sha_rc,
            "baselineStatus": source_status_rc,
            "diagnosticRevision": diagnostic_sha_rc,
            "diagnosticStatus": diagnostic_status_rc,
            "diagnosticTrackedFiles": tracked_paths_rc,
            "diagnosticDiff": diagnostic_diff_rc,
            "diagnosticCachedDiff": cached_diff_rc,
            "diagnosticDiffOutput": diagnostic_diff_output,
            "diagnosticCachedDiffOutput": cached_diff_output,
        },
        "checks": checks,
        "commandFailures": [
            {
                "check": name,
                "command": check.get("command", []),
                "exit": check.get("exit"),
                "output": check.get("output", ""),
            }
            for name, check in checks.items()
            if check.get("exit") not in (0, None)
        ],
        "parseError": parse_error,
        "parseErrorSource": parse_error_source,
    }

def qualify_environment(info: dict[str, Any]) -> list[str]:
    event = info["event"]
    expected = info["expected"]
    observed = info["observed"]
    exits = info["exitCodes"]
    checks = info["checks"]
    errors: list[str] = []

    if event["name"] != "push":
        errors.append("workflow event must be push")
    if event["refType"] != "tag":
        errors.append("workflow ref must be a tag")
    if not event["refName"].startswith(DIAGNOSTIC_TAG_PREFIX):
        errors.append("tag name is outside the approved diagnostic pattern")
    if not event["sha"]:
        errors.append("GITHUB_SHA is missing")
    if observed["baselineSHA"] != BASELINE_SHA or exits["baselineRevision"] != 0:
        errors.append("application source revision does not match the published baseline")
    if observed["baselineStatus"].strip() or exits["baselineStatus"] != 0:
        errors.append("application source checkout is not clean")
    if observed["diagnosticSHA"] != event["sha"] or exits["diagnosticRevision"] != 0:
        errors.append("diagnostic scripts are not checked out at the tag commit")
    if observed["diagnosticStatus"].strip() or exits["diagnosticStatus"] != 0:
        errors.append("diagnostic checkout has tracked changes")
    if set(observed["trackedDiagnosticFiles"]) != set(DIAGNOSTIC_FILES):
        errors.append("diagnostic workflow and helpers are not all tracked at tag commit")
    if exits["diagnosticTrackedFiles"] != 0:
        errors.append("could not verify diagnostic files in tag commit")
    diff_codes = (exits["diagnosticDiff"], exits["diagnosticCachedDiff"])
    if 1 in diff_codes:
        errors.append("diagnostic workflow or helper content differs from the tag commit")
    if any(code not in (0, 1) for code in diff_codes):
        errors.append(
            "could not inspect diagnostic content with Git: "
            f"exit codes {diff_codes}; outputs "
            f"{exits['diagnosticDiffOutput']!r} / {exits['diagnosticCachedDiffOutput']!r}"
        )
    if not observed["baselineWorkspacePresent"]:
        errors.append("baseline application workspace is missing")

    def command_details(check: dict[str, Any]) -> str:
        command = " ".join(check.get("command", [])) or "not run"
        return f"command={command!r} exit={check.get('exit')!r} output={check.get('output', '')!r}"

    xcode_check = checks["xcode"]
    xcode_path_matches = observed["developerDirectory"] == expected["developerDirectory"]
    xcode_build_matches = (
        observed["xcodeVersion"] == f"Xcode {expected['xcodeVersion']}"
        and observed["xcodeBuild"] == expected["xcodeBuild"]
    )
    if not xcode_path_matches or xcode_check["exit"] != 0 or not xcode_build_matches:
        errors.append(
            "Xcode prerequisite failed: "
            f"expected DEVELOPER_DIR={expected['developerDirectory']!r}, "
            f"Xcode {expected['xcodeVersion']} build {expected['xcodeBuild']}; "
            f"observed DEVELOPER_DIR={observed['developerDirectory']!r}, "
            f"xcode-select -p={observed['xcodeSelectPath']!r}, "
            f"Xcode={observed['xcodeVersion']!r} build={observed['xcodeBuild']!r}; "
            f"{command_details(xcode_check)}"
        )
    elif checks["swiftPath"]["exit"] != 0 or not observed["swiftPath"]:
        errors.append(
            "system xcrun could not locate Swift: "
            f"{command_details(checks['swiftPath'])}"
        )
    elif not observed["swiftPathMatchesDeveloperDirectory"]:
        errors.append(
            "system xcrun resolved Swift outside the validated Xcode: "
            f"expected DEVELOPER_DIR={expected['developerDirectory']!r}, "
            f"observed Swift={observed['swiftPath']!r}; "
            f"{command_details(checks['swiftPath'])}"
        )
    elif checks["runtimes"].get("developerDirectory") != expected["developerDirectory"]:
        errors.append(
            "system xcrun runtime inventory did not use the validated DEVELOPER_DIR: "
            f"{command_details(checks['runtimes'])}"
        )
    elif checks["runtimes"]["exit"] != 0:
        errors.append(
            "system xcrun runtime inventory command failed: "
            f"{command_details(checks['runtimes'])}"
        )
    elif info["parseErrorSource"] == "runtime inventory":
        errors.append(f"runtime inventory JSON is invalid: {info['parseError']}")
    elif observed["runtime"] is None:
        errors.append(
            "required iOS runtime was not found: "
            f"expected iOS {expected['runtimeVersion']} build {expected['runtimeBuild']}; "
            f"observed runtimes={observed['runtimeCandidates']!r}"
        )
    elif checks["devices"].get("developerDirectory") != expected["developerDirectory"]:
        errors.append(
            "system xcrun simulator inventory did not use the validated DEVELOPER_DIR: "
            f"{command_details(checks['devices'])}"
        )
    elif checks["devices"]["exit"] != 0:
        errors.append(
            "system xcrun simulator device inventory command failed: "
            f"{command_details(checks['devices'])}"
        )
    elif info["parseErrorSource"] == "device inventory":
        errors.append(f"simulator device inventory JSON is invalid: {info['parseError']}")
    elif observed["simulator"] is None:
        errors.append("canonical iPad simulator is missing or ambiguous for the required runtime")
    elif observed["simulator"].get("deviceTypeIdentifier") != expected["simulatorTypeIdentifier"]:
        errors.append(
            "selected simulator does not match the canonical iPad Pro 11-inch M5 device type"
        )
    elif observed["destinationID"] is None:
        errors.append("canonical iPad simulator UDID could not be resolved")

    return errors

def verify_environment(
    source: Path,
    output: Path,
    env: dict[str, str],
    diagnostic_root: Path | None = None,
) -> dict[str, Any]:
    diagnostic = (diagnostic_root or Path(__file__).resolve().parents[1]).resolve()
    info = collect_environment(source.resolve(), diagnostic, env)
    errors = qualify_environment(info)
    info["preflightErrors"] = errors
    write_json(output / "environment.json", info)
    if errors:
        raise RuntimeError("; ".join(errors))
    return info



def inspect_result(
    run_dir: Path,
    bundle: Path,
    simulator: str,
    iteration: int,
    env: dict[str, str],
) -> tuple[dict[str, Any], list[dict[str, object]]]:
    xcrun = SYSTEM_XCRUN
    row: dict[str, Any] = {"simulator": simulator, "iteration": iteration, "resultBundle": str(bundle)}
    if not bundle.is_dir():
        row["resultInspectionError"] = "xcresult bundle is missing"
        return row, []

    summary_rc, summary_text = capture(
        [xcrun, "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"],
        env,
    )
    (run_dir / "summary.json").write_text(summary_text, encoding="utf-8")
    row["summaryExit"] = summary_rc
    summary: dict[str, Any] = {}
    if summary_rc == 0:
        try:
            summary = parse_json(summary_text)
            for key in (
                "result", "totalTestCount", "passedTests", "failedTests",
                "skippedTests", "testFailures", "startTime", "finishTime",
            ):
                row[key] = summary.get(key)
        except (ValueError, json.JSONDecodeError) as error:
            row["summaryError"] = str(error)

    tests_rc, tests_text = capture(
        [xcrun, "xcresulttool", "get", "test-results", "tests", "--path", str(bundle), "--compact"],
        env,
    )
    (run_dir / "tests.json").write_text(tests_text, encoding="utf-8")
    row["testsExit"] = tests_rc
    test_node: dict[str, Any] | None = None
    if tests_rc == 0:
        try:
            test_node = find_test_case(parse_json(tests_text))
        except (ValueError, json.JSONDecodeError) as error:
            row["testsParseError"] = str(error)
    if test_node:
        row["selectedTestIdentifier"] = test_node.get("nodeIdentifier")
        row["testCaseDurationSeconds"] = test_node.get("durationInSeconds")

    activities_id = (
        (test_node.get("nodeIdentifierURL") if test_node else None)
        or TEST_CASE_IDENTIFIER_URL
    )
    activities_rc, activities_text = capture(
        [
            xcrun, "xcresulttool", "get", "test-results", "activities",
            "--path", str(bundle), "--test-id", str(activities_id), "--compact",
        ],
        env,
    )
    (run_dir / "activities.json").write_text(activities_text, encoding="utf-8")
    row["activitiesExit"] = activities_rc

    attachment_dir = run_dir / "attachments"
    attachment_dir.mkdir(parents=True, exist_ok=True)
    export_rc, export_text = capture(
        [
            xcrun, "xcresulttool", "export", "attachments",
            "--path", str(bundle), "--output-path", str(attachment_dir), "--only-failures",
        ],
        env,
    )
    (run_dir / "attachment-export.log").write_text(export_text, encoding="utf-8")
    row["attachmentExportExit"] = export_rc
    pairs = copy_failure_images(attachment_dir, run_dir, simulator, iteration)
    row["failureAttachmentCount"] = sum(
        1 for path in attachment_dir.rglob("*") if path.is_file()
    )
    row["failureImagePairs"] = len(pairs)
    row["snapshotFailures"] = snapshot_failure_names(summary, attachment_dir)
    row["snapshotFailureCount"] = len(row["snapshotFailures"])
    return row, pairs


def snapshot_failure_names(
    summary: dict[str, Any],
    attachments: Path,
) -> list[str]:
    names: set[str] = set()
    for failure in summary.get("testFailures") or []:
        if isinstance(failure, dict):
            names.update(SNAPSHOT_NAME.findall(str(failure.get("failureText", ""))))
    if attachments.is_dir():
        for issue_file in attachments.rglob("*.txt"):
            issue = issue_file.read_text(encoding="utf-8", errors="replace")
            names.update(SNAPSHOT_NAME.findall(issue))
    return sorted(names)


def snapshot_image_evidence_complete(
    failure_names: list[str],
    pairs: list[dict[str, object]],
    metrics: list[dict[str, Any]],
) -> bool:
    if not failure_names:
        return True
    pair_names = {str(pair.get("snapshot", "")) for pair in pairs}
    if not set(failure_names).issubset(pair_names):
        return False
    if len(metrics) != len(pairs):
        return False
    if any(not pair.get("reference_exists") or not pair.get("actual_exists") for pair in pairs):
        return False
    for metric in metrics:
        status = metric.get("status")
        if status not in {"compared", "dimension-mismatch"}:
            return False
        if status == "compared":
            difference_path = metric.get("differenceImagePath")
            if not difference_path or not Path(str(difference_path)).is_file():
                return False
    return True


def measure_pairs(
    run_dir: Path,
    pairs: list[dict[str, object]],
    swift_path: str,
    helper: Path,
) -> tuple[int, list[dict[str, Any]]]:
    pair_file = run_dir / "snapshot-image-pairs.json"
    metrics_file = run_dir / "pixel-diff-metrics.json"
    write_json(pair_file, pairs)
    if not pairs:
        write_json(metrics_file, [])
        return 0, []

    with (run_dir / "pixel-metrics.log").open("w", encoding="utf-8") as log:
        try:
            process = subprocess.run(
                [swift_path, str(helper), str(pair_file), str(metrics_file)],
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )
            exit_code = process.returncode
        except OSError as error:
            log.write(f"Could not run the Swift metrics helper: {error}\n")
            exit_code = 127

    try:
        metrics = json.loads(metrics_file.read_text(encoding="utf-8"))
        if not isinstance(metrics, list):
            raise ValueError("metrics output is not a JSON array")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        metrics = [{"status": "metrics-error", "error": str(error)}]
        write_json(metrics_file, metrics)
        if exit_code == 0:
            exit_code = 1
    return exit_code, metrics


def test_case_passed(xcodebuild_exit: int, row: dict[str, Any]) -> bool:
    return (
        xcodebuild_exit == 0
        and row.get("result") == "Passed"
        and row.get("totalTestCount") == 1
        and row.get("failedTests") == 0
        and row.get("testsExit") == 0
        and row.get("selectedTestIdentifier") == TEST_CASE_IDENTIFIER
    )


def execute_xcodebuild(
    iteration: int,
    source: Path,
    run_dir: Path,
    bundle: Path,
    destination: str,
    env: dict[str, str],
) -> dict[str, Any]:
    developer = Path(env["DEVELOPER_DIR"])
    command = [
        str(developer / "usr/bin/xcodebuild"),
        "-skipMacroValidation",
        "-workspace", str(source / "App.xcworkspace"),
        "-scheme", "App",
        "-configuration", "Debug",
        "-destination", destination,
        "-clonedSourcePackagesDirPath",
        str(Path(env.get("RUNNER_TEMP", "/tmp")) / "issue9-failure-b-source-packages"),
        "-derivedDataPath",
        str(Path(env.get("RUNNER_TEMP", "/tmp")) / "issue9-failure-b-derived-data"),
        "-resultBundlePath", str(bundle),
        "-parallel-testing-enabled", "NO",
        "-destination-timeout", "120",
        f"-only-testing:{XCODEBUILD_SELECTOR}",
        "test",
    ]
    write_json(run_dir / "command.json", {
        "command": command,
        "sourceRevision": BASELINE_SHA,
        "selector": XCODEBUILD_SELECTOR,
        "resultBundle": str(bundle),
    })
    test_env = dict(env)
    test_env["TEST_RUNNER_SNAPSHOT_TESTING_RECORD"] = "never"
    started = time.monotonic()
    timed_out = False
    process_error = ""
    with (run_dir / "xcodebuild.log").open("w", encoding="utf-8") as log:
        try:
            process = subprocess.Popen(
                command,
                cwd=source,
                env=test_env,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                exit_code = process.wait(timeout=PER_ITERATION_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                timed_out = True
                log.write(
                    f"\nxcodebuild exceeded {PER_ITERATION_TIMEOUT_SECONDS} seconds; "
                    "terminating its process group.\n"
                )
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    log.write("Process group did not stop after SIGTERM; sending SIGKILL.\n")
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                exit_code = 124
        except OSError as error:
            process_error = str(error)
            exit_code = 127
            log.write(f"\nCould not start xcodebuild: {error}\n")
    return {
        "iteration": iteration,
        "destination": destination,
        "selectedTest": XCODEBUILD_SELECTOR,
        "durationSeconds": round(time.monotonic() - started, 3),
        "xcodebuildExit": exit_code,
        "timedOut": timed_out,
        "processError": process_error,
    }
def collect_iteration_evidence(
    run_dir: Path,
    bundle: Path,
    iteration: int,
    swift_path: str,
    helper: Path,
    env: dict[str, str],
) -> dict[str, Any]:
    result, pairs = inspect_result(run_dir, bundle, SIMULATOR_NAME, iteration, env)
    metrics_exit, metrics = measure_pairs(run_dir, pairs, swift_path, helper)
    result["pixelMetricsExit"] = metrics_exit
    result["pixelMetrics"] = metrics
    result["snapshotImageEvidenceComplete"] = snapshot_image_evidence_complete(
        result.get("snapshotFailures", []), pairs, metrics
    )
    return result


def classify_iteration(row: dict[str, Any]) -> None:
    row["testOutcome"] = "Passed" if test_case_passed(row.get("xcodebuildExit", 127), row) else "Failed"
    row["evidenceOutcome"] = (
        "Complete"
        if row.get("resultBundle")
        and row.get("summaryExit") == 0
        and row.get("testsExit") == 0
        and row.get("activitiesExit") == 0
        and row.get("attachmentExportExit") == 0
        and row.get("pixelMetricsExit") == 0
        and row.get("snapshotImageEvidenceComplete") is True
        else "Incomplete"
    )


def run_iteration(
    iteration: int,
    source: Path,
    output: Path,
    destination: str,
    swift_path: str,
    helper: Path,
    env: dict[str, str],
) -> dict[str, Any]:
    run_dir = output / "runs" / f"{iteration:02d}"
    run_dir.mkdir(parents=True, exist_ok=True)
    bundle = run_dir / "App.xcresult"
    row = execute_xcodebuild(iteration, source, run_dir, bundle, destination, env)
    try:
        row.update(collect_iteration_evidence(run_dir, bundle, iteration, swift_path, helper, env))
    except Exception as error:
        row["evidenceProcessingError"] = f"{type(error).__name__}: {error}"
        row["pixelMetricsExit"] = 1
        row["snapshotImageEvidenceComplete"] = False
        if not (run_dir / "snapshot-image-pairs.json").exists():
            write_json(run_dir / "snapshot-image-pairs.json", [])
        if not (run_dir / "pixel-diff-metrics.json").exists():
            write_json(run_dir / "pixel-diff-metrics.json", [{
                "status": "evidence-processing-error",
                "error": row["evidenceProcessingError"],
            }])
    classify_iteration(row)
    write_json(run_dir / "iteration-summary.json", row)
    return row



def run_iterations(
    output: Path,
    runner: Callable[[int], dict[str, Any]],
    iteration_count: int = ITERATIONS,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for iteration in range(1, iteration_count + 1):
        try:
            row = runner(iteration)
        except Exception as error:
            row = {
                "iteration": iteration,
                "testOutcome": "Failed",
                "evidenceOutcome": "Incomplete",
                "iterationError": f"{type(error).__name__}: {error}",
                "durationSeconds": 0,
            }
        rows.append(row)
        with (output / "iterations.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
        print(
            f"{iteration:02d}/{iteration_count}: {row.get('testOutcome', 'Failed')} "
            f"exit={row.get('xcodebuildExit', 'unavailable')} "
            f"duration={row.get('durationSeconds', 0):.3f}s "
            f"failures={row.get('failedTests', 'unknown')}"
        )
    return rows


def write_step_summary(path: str, aggregate: dict[str, Any]) -> None:
    if not path:
        return
    lines = [
        "## Issue #9 Failure B diagnostic",
        "",
        f"Qualification: {aggregate['qualification']}",
        "",
        f"Baseline: {BASELINE_SHA}. Selector: {XCODEBUILD_SELECTOR}.",
        "",
        "| Run | Outcome | Test seconds | Test failures | Snapshot image pairs |",
        "| --- | --- | ---: | ---: | ---: |",
    ]
    for row in aggregate["runs"]:
        lines.append(
            f"| {row['iteration']:02d} | {row.get('testOutcome', 'Failed')} "
            f"| {row.get('durationSeconds', 0):.3f} "
            f"| {row.get('failedTests', 'unknown')} "
            f"| {row.get('failureImagePairs', 0)} |"
        )
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--diagnostic-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args()

    source = args.source_root.resolve()
    diagnostic = args.diagnostic_root.resolve()
    output = args.output_root.resolve()
    output.mkdir(parents=True, exist_ok=True)
    helper = diagnostic / "Scripts" / "measure_snapshot_pngs.swift"
    initial = {
        "baselineSHA": BASELINE_SHA,
        "diagnosticSHA": os.environ.get("GITHUB_SHA", ""),
        "expectedXcode": f"{EXPECTED_XCODE_VERSION} build {EXPECTED_XCODE_BUILD}",
        "expectedRuntime": f"iOS {EXPECTED_RUNTIME_VERSION} build {EXPECTED_RUNTIME_BUILD}",
        "selector": XCODEBUILD_SELECTOR,
        "iterations": ITERATIONS,
        "simulator": SIMULATOR_NAME,
    }
    write_json(output / "run-manifest.json", initial)

    try:
        environment = verify_environment(source, output, dict(os.environ), diagnostic)
    except Exception as error:
        failed = {
            **initial,
            "qualification": "Failed",
            "preflightError": f"{type(error).__name__}: {error}",
            "completedIterations": 0,
            "passedRuns": 0,
            "failedRuns": 0,
            "runs": [],
        }
        write_json(output / "aggregate-summary.json", failed)
        write_step_summary(os.environ.get("GITHUB_STEP_SUMMARY", ""), failed)
        print(f"PRE-FLIGHT FAILED: {error}", file=sys.stderr)
        return 2

    swift_path = str(environment["observed"]["swiftPath"])
    simulator_id = str(environment["observed"]["destinationID"])
    destination = f"platform=iOS Simulator,id={simulator_id}"
    run = lambda iteration: run_iteration(
        iteration, source, output, destination, swift_path, helper, dict(os.environ)
    )
    rows = run_iterations(output, run)
    passed = sum(row.get("testOutcome") == "Passed" for row in rows)
    failed = len(rows) - passed
    evidence_failures = sum(row.get("evidenceOutcome") != "Complete" for row in rows)
    qualification = (
        "Passed"
        if len(rows) == ITERATIONS and failed == 0 and evidence_failures == 0
        else "Failed"
    )
    aggregate = {
        **initial,
        "qualification": qualification,
        "sourceRevision": environment["observed"]["baselineSHA"],
        "diagnosticRevision": environment["observed"]["diagnosticSHA"],
        "toolchain": {
            "xcodeVersion": environment["observed"]["xcodeVersion"],
            "xcodeBuild": environment["observed"]["xcodeBuild"],
            "runtimeVersion": EXPECTED_RUNTIME_VERSION,
            "runtimeBuild": EXPECTED_RUNTIME_BUILD,
            "simulatorName": SIMULATOR_NAME,
            "simulatorUDID": simulator_id,
            "destination": destination,
            "scale": "canonical 2x iPad snapshot destination",
            "runnerImage": environment["runner"],
        },
        "completedIterations": len(rows),
        "passedRuns": passed,
        "failedRuns": failed,
        "incompleteEvidenceRuns": evidence_failures,
        "runs": rows,
    }
    write_json(output / "aggregate-summary.json", aggregate)
    write_step_summary(os.environ.get("GITHUB_STEP_SUMMARY", ""), aggregate)
    if qualification != "Passed":
        print("AGGREGATE QUALIFICATION FAILED; all ten scheduled iterations were attempted.")
        return 1
    print("AGGREGATE QUALIFICATION PASSED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
