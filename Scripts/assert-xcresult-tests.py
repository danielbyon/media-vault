#!/usr/bin/env python3
"""Require an exact set of passed tests on the intended simulator."""

import argparse
import json
import subprocess
import sys


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


def normalize_identifier(identifier):
    parts = identifier.split("/")
    identifier = "/".join(parts[-2:])
    return identifier.removesuffix("()")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--expected-device-id", required=True)
    parser.add_argument("--expected-device-name", required=True)
    parser.add_argument("--expected-os-version", required=True)
    parser.add_argument("--expected-test", action="append", required=True)
    arguments = parser.parse_args()

    expected_tests = [normalize_identifier(value) for value in arguments.expected_test]
    if len(set(expected_tests)) != len(expected_tests):
        parser.error("expected test identities must be unique")

    summary = xcresult_json(arguments.bundle, "summary")
    report = xcresult_json(arguments.bundle, "tests")
    cases = list(test_case_nodes(report.get("testNodes", [])))
    observed_tests = [normalize_identifier(node.get("nodeIdentifier", "")) for node in cases]
    observed_tests.sort()
    expected_tests.sort()

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
    if counts["total"] != len(expected_tests) or counts["passed"] != len(expected_tests):
        problems.append(f"expected {len(expected_tests)} passed tests, observed {counts}")
    if counts["failed"] != 0 or counts["skipped"] != 0 or counts["expectedFailures"] != 0:
        problems.append(f"failed, skipped, and expected-failure counts must be zero: {counts}")
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
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"xcresult validation failed: {error}", file=sys.stderr)
        sys.exit(1)
