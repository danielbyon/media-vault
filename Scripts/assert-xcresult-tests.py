#!/usr/bin/env python3
"""Require an exact set of passed tests on the intended simulator."""

import argparse
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


def xcresult_json(bundle, command):
    return json.loads(subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", command,
         "--path", str(bundle), "--compact"],
        text=True,
    ))


def test_case_nodes(nodes):
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            yield node
        yield from test_case_nodes(node.get("children", []))


def test_case_identities(nodes, bundle_target=None, bundle_url_parts=None):
    for node in nodes:
        node_type = node.get("nodeType")
        current_target = bundle_target
        current_url_parts = bundle_url_parts
        if node_type in ("Unit test bundle", "UI test bundle"):
            current_target = node.get("name")
            current_url_parts = test_identifier_url_parts(
                node.get("nodeIdentifierURL"), "test bundle")
            if not isinstance(current_target, str) or not current_target:
                raise ValueError("test bundle must have a nonempty name")
            if current_url_parts[-1] != current_target:
                raise ValueError(
                    f"test bundle URL target differs from its name: "
                    f"{current_url_parts[-1]!r} != {current_target!r}")

        if node_type == "Test Case":
            if not current_target or not current_url_parts:
                raise ValueError("test case is missing its enclosing test bundle")
            node_identifier = node.get("nodeIdentifier")
            if not isinstance(node_identifier, str) or not node_identifier:
                raise ValueError("test case must have a nonempty nodeIdentifier")
            case_url_parts = test_identifier_url_parts(
                node.get("nodeIdentifierURL"), "test case")
            if case_url_parts[:len(current_url_parts)] != current_url_parts:
                raise ValueError("test case URL does not belong to its enclosing test bundle")
            relative_parts = case_url_parts[len(current_url_parts):]
            relative_identifier = "/".join(relative_parts)
            if not relative_identifier:
                raise ValueError("test case URL does not identify a case below its test bundle")
            if normalize_full_identifier(node_identifier) != normalize_full_identifier(
                    relative_identifier):
                raise ValueError(
                    "test case nodeIdentifier differs from its bundle-relative URL: "
                    f"{node_identifier!r} != {relative_identifier!r}")
            yield current_target + "/" + normalize_full_identifier(relative_identifier), node
        else:
            yield from test_case_identities(
                node.get("children", []), current_target, current_url_parts)


def test_identifier_url_parts(value, label):
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must have a nonempty nodeIdentifierURL")
    parsed = urlsplit(value)
    if parsed.scheme != "test" or parsed.netloc != "com.apple.xcode":
        raise ValueError(f"{label} has an unrecognized nodeIdentifierURL: {value!r}")
    parts = [unquote(part) for part in parsed.path.split("/") if part]
    if len(parts) < 2 or any(not part for part in parts):
        raise ValueError(f"{label} nodeIdentifierURL has an invalid path: {value!r}")
    return parts

def validate_http_matrix(result_cases):
    expected_rows = {
        "originatingMatrix(profile:row:)": sorted(
            (f"{profile}, {row}", "Passed")
            for profile in (".persistentPrivate", ".ephemeral")
            for row in (".attachment", ".inline", ".octet", ".redirect", ".protected", ".post", ".blob", ".attribute")
        ),
        "slowCancellation(profile:knownLength:)": sorted(
            (f"{profile}, {known_length}", "Passed")
            for profile in (".persistentPrivate", ".ephemeral")
            for known_length in ("true", "false")
        ),
    }
    verified_rows = {}
    for method, expected in expected_rows.items():
        identity = f"AppHostedUITests/BrowserDownloadHTTPTests/{method}"
        full_identity = "AppHostedTests/" + identity
        parents = [node for observed_identity, node in result_cases
                   if observed_identity == full_identity]
        if len(parents) != 1:
            raise ValueError(
                "App HTTP matrix parent target identity is missing or duplicated: "
                f"{full_identity} (count {len(parents)})")
        rows = sorted(
            (node.get("name"), node.get("result"))
            for node in parents[0].get("children", [])
            if node.get("nodeType") == "Arguments"
        )
        if rows != expected:
            raise ValueError(f"App HTTP parameter rows differ for {method}: expected {expected}, observed {rows}")
        if parents[0].get("result") != "Passed":
            raise ValueError(f"App HTTP parameter parent result for {method}: {parents[0].get('result')}")
        verified_rows[method] = rows
    return verified_rows


def normalize_identifier(identifier):
    parts = identifier.split("/")
    identifier = "/".join(parts[-2:])
    return identifier.removesuffix("()")


def normalize_full_identifier(identifier):
    return identifier.removesuffix("()")


def normalized_enumerated_identifiers(path):
    identifiers = enumerated_test_identifiers(path)
    normalized = []
    for identifier in identifiers:
        parts = identifier.split("/")
        if len(parts) < 3 or any(not part for part in parts):
            raise ValueError(
                "enumerated test identity must contain a target, suite, and method: "
                f"{identifier!r}")
        normalized.append(normalize_full_identifier(identifier))
    return normalized


def resolve_required_tests(required_values, expected_tests, enumeration_mode, parser):
    if not enumeration_mode:
        return [normalize_identifier(value) for value in required_values]

    resolved = []
    for value in required_values:
        full_identifier = normalize_full_identifier(value)
        if full_identifier in expected_tests:
            resolved.append(full_identifier)
            continue
        short_identifier = normalize_identifier(value)
        matches = [identity for identity in expected_tests
                   if normalize_identifier(identity) == short_identifier]
        if len(matches) != 1:
            parser.error(
                "required test selector must match exactly one enabled target identity: "
                f"{value!r} matched {len(matches)}")
        resolved.append(matches[0])
    return resolved

def enumerated_test_identifiers(path):
    document = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(document, dict) or not isinstance(document.get("errors"), list):
        raise ValueError("Xcode enumeration must contain an errors list")
    if document["errors"]:
        raise ValueError(f"Xcode enumeration reported errors: {document['errors']}")
    values = document.get("values")
    if not isinstance(values, list) or not values:
        raise ValueError("Xcode enumeration must contain nonempty values")

    identifiers = []
    for value in values:
        if not isinstance(value, dict):
            raise ValueError("Xcode enumeration values must be objects")
        enabled_tests = value.get("enabledTests")
        disabled_tests = value.get("disabledTests")
        if not isinstance(enabled_tests, list) or not isinstance(disabled_tests, list):
            raise ValueError("Xcode enumeration values must contain enabledTests and disabledTests lists")
        for entry in enabled_tests + disabled_tests:
            if not isinstance(entry, dict) or not isinstance(entry.get("identifier"), str) or not entry["identifier"]:
                raise ValueError("Xcode enumeration test entries must contain a nonempty identifier")
        identifiers.extend(entry["identifier"] for entry in enabled_tests)

    if not identifiers:
        raise ValueError("Xcode enumeration contains no enabled test identities")
    return identifiers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--expected-device-id", required=True)
    parser.add_argument("--expected-device-name", required=True)
    parser.add_argument("--expected-os-version", required=True)
    parser.add_argument("--expected-test", action="append", default=[])
    parser.add_argument("--expected-tests-file")
    parser.add_argument("--allow-known-physical-skip", action="store_true")
    parser.add_argument("--required-test", action="append", default=[])
    parser.add_argument("--http-matrix", action="store_true")
    arguments = parser.parse_args()

    enumeration_mode = arguments.expected_tests_file is not None
    if enumeration_mode and arguments.expected_test:
        parser.error("--expected-test and --expected-tests-file use separate identity scopes")
    if arguments.http_matrix and not enumeration_mode:
        parser.error("--http-matrix requires --expected-tests-file")
    if enumeration_mode:
        expected_tests = normalized_enumerated_identifiers(arguments.expected_tests_file)
    else:
        expected_tests = [normalize_identifier(value) for value in arguments.expected_test]
    if not expected_tests:
        parser.error("provide --expected-test or --expected-tests-file")

    if len(set(expected_tests)) != len(expected_tests):
        parser.error("expected test identities must be unique")

    physical_skip = normalize_identifier(
        "AppHostedUITests/BrowserDownloadPersistenceIsolationTests/"
        "completedFilesRetainProtectionAndBackupExclusion()"
    )
    allowed_skipped_tests = []
    if arguments.allow_known_physical_skip:
        if not enumeration_mode:
            parser.error("the known physical skip requires an enumerated identity set")
        physical_matches = [identity for identity in expected_tests
                            if normalize_identifier(identity) == physical_skip]
        if len(physical_matches) != 1:
            parser.error(
                "the known physical skip must match exactly one enumerated identity")
        allowed_skipped_tests = physical_matches

    required_tests = resolve_required_tests(
        arguments.required_test, expected_tests, enumeration_mode, parser)
    if len(set(required_tests)) != len(required_tests):
        parser.error("required test identities must be unique")
    if not set(required_tests).issubset(expected_tests):
        parser.error("every required test must be in the expected identity set")

    summary = xcresult_json(arguments.bundle, "summary")
    report = xcresult_json(arguments.bundle, "tests")
    if enumeration_mode:
        result_cases = list(test_case_identities(report.get("testNodes", [])))
    else:
        result_cases = [
            (normalize_identifier(node.get("nodeIdentifier", "")), node)
            for node in test_case_nodes(report.get("testNodes", []))
        ]
    http_matrix_rows = validate_http_matrix(result_cases) if arguments.http_matrix else {}
    observed_tests = [identity for identity, _node in result_cases]
    passed_tests = sorted(
        identity
        for identity, node in result_cases
        if node.get("result") == "Passed"
    )
    skipped_tests = sorted(
        identity
        for identity, node in result_cases
        if node.get("result") == "Skipped"
    )
    observed_tests.sort()
    expected_tests.sort()
    unexpected_skips = sorted(set(skipped_tests) - set(allowed_skipped_tests))
    expected_passed_tests = sorted(set(expected_tests) - set(skipped_tests))

    counts = {
        "total": summary.get("totalTestCount", 0),
        "passed": summary.get("passedTests", 0),
        "failed": summary.get("failedTests", 0),
        "skipped": summary.get("skippedTests", 0),
        "expectedFailures": summary.get("expectedFailures", 0),
    }
    configurations = summary.get("devicesAndConfigurations", [])
    expected_device_id = arguments.expected_device_id.casefold()
    expected_device = {
        "deviceId": expected_device_id,
        "deviceName": arguments.expected_device_name,
        "osVersion": arguments.expected_os_version,
        "platform": "iOS Simulator",
    }
    observed_devices = [
        {
            "deviceId": str(configuration.get("device", {}).get("deviceId", "")).casefold(),
            "deviceName": configuration.get("device", {}).get("deviceName"),
            "osVersion": configuration.get("device", {}).get("osVersion"),
            "platform": configuration.get("device", {}).get("platform"),
        }
        for configuration in configurations
    ]

    problems = []
    if summary.get("result") != "Passed":
        problems.append(f"result is {summary.get('result')!r}, expected 'Passed'")
    if observed_tests != expected_tests:
        problems.append(f"test identities differ: expected {expected_tests}, observed {observed_tests}")
    if passed_tests != expected_passed_tests:
        problems.append(f"passed test identities differ: expected {expected_passed_tests}, observed {passed_tests}")
    if unexpected_skips:
        problems.append(f"unexpected skipped test identities: {unexpected_skips}")
    if set(passed_tests).intersection(skipped_tests) or set(passed_tests).union(skipped_tests) != set(expected_tests):
        problems.append("test results contain identities without exactly one pass or approved skip")
    if not set(required_tests).issubset(passed_tests):
        problems.append(f"required test identities did not pass: {sorted(set(required_tests) - set(passed_tests))}")
    if counts["total"] != len(expected_tests) or counts["passed"] != len(expected_passed_tests):
        problems.append(f"expected {len(expected_passed_tests)} passed tests, observed {counts}")
    if counts["failed"] != 0 or counts["skipped"] != len(skipped_tests) or counts["expectedFailures"] != 0:
        problems.append(f"failed or unexpected test outcomes: {counts}")
    if not observed_devices or any(device != expected_device for device in observed_devices):
        problems.append(f"device mismatch: expected {expected_device}, observed {observed_devices}")

    if problems:
        for problem in problems:
            print(f"xcresult validation failed: {problem}", file=sys.stderr)
        return 1

    print(f"Exact test identities: {', '.join(expected_tests)}")
    print(f"Counts: passed={counts['passed']} failed={counts['failed']} skipped={counts['skipped']}")
    print(
        "Destination: "
        f"{arguments.expected_device_name} ({arguments.expected_device_id}), "
        f"iOS {arguments.expected_os_version}"
    )
    for method, rows in http_matrix_rows.items():
        print(f"HTTP matrix rows for {method}: {len(rows)}")
        for name, result in rows:
            print(f"  HTTP matrix row: arguments={name!r} result={result}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError) as error:
        print(f"xcresult validation failed: {error}", file=sys.stderr)
        sys.exit(1)
