#!/usr/bin/env python3
"""Resolve an exact simulator and optionally execute xcodebuild with its UDID."""

import json
import os
import re
import shlex
import subprocess
import sys
import uuid


RUNTIME_IDENTIFIER = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
RUNTIME_VERSION = "27.2"
RUNTIME_BUILD = "24B8117"


def capture(*command):
    """Keep inventory and destination commands read-only; propagate failures."""
    return subprocess.check_output(command, text=True)


def expected_name(destination):
    """Accept a complete Make destination or an exact name for manual preflight."""
    if "=" not in destination:
        if not destination.strip():
            raise ValueError("The expected simulator name is empty.")
        return destination
    fields = {}
    for item in destination.split(","):
        key, separator, value = item.partition("=")
        if not separator or key in fields:
            raise ValueError("Malformed or duplicate destination fields.")
        fields[key] = value
    if (set(fields) != {"platform", "name", "OS"}
            or fields["platform"] != "iOS Simulator"
            or fields["OS"] != RUNTIME_VERSION or not fields["name"].strip()):
        raise ValueError("Expected an iOS Simulator destination with a name and OS=27.2.")
    return fields["name"]


def resolve_device(name, expected_udid):
    """Require one available exact-name device in the pinned runtime and build."""
    runtimes = json.loads(capture("xcrun", "simctl", "list", "runtimes", "--json"))
    matches = [runtime for runtime in runtimes["runtimes"]
               if runtime["identifier"] == RUNTIME_IDENTIFIER]
    if (len(matches) != 1 or matches[0].get("version") != RUNTIME_VERSION
            or matches[0].get("buildversion") != RUNTIME_BUILD
            or matches[0].get("isAvailable") is not True):
        raise ValueError(f"Required runtime unavailable: {RUNTIME_IDENTIFIER}, build {RUNTIME_BUILD}.")
    inventory = json.loads(capture("xcrun", "simctl", "list", "devices", "--json"))
    devices = [device for device in inventory["devices"].get(RUNTIME_IDENTIFIER, [])
               if device.get("name") == name and device.get("isAvailable") is True]
    if expected_udid:
        # UUID equality is case-insensitive, but output preserves simctl's identity.
        requested = uuid.UUID(expected_udid)
        devices = [device for device in devices if uuid.UUID(device["udid"]) == requested]
    if len(devices) != 1:
        raise ValueError(f"Expected one available simulator named {name!r}; found {len(devices)}"
                         f" for UDID {expected_udid or 'unspecified'}. Supply a matching UDID to disambiguate.")
    device = devices[0]
    if str(uuid.UUID(device["udid"])).upper() != device["udid"].upper():
        raise ValueError("Simulator inventory returned a malformed UDID.")
    return device


def option(arguments, flag, default):
    """Use the executing command's scheme, workspace, and package cache for preflight."""
    if arguments.count(flag) > 1:
        raise ValueError(f"Duplicate {flag} options are unsupported.")
    if flag not in arguments:
        return default
    index = arguments.index(flag) + 1
    if index == len(arguments) or arguments[index].startswith("-"):
        raise ValueError(f"Missing value for {flag}.")
    return arguments[index]


def destination_fields(text):
    """Split fields outside brackets and reject malformed or duplicate fields."""
    entries = []
    start = 0
    depth = 0
    for index, character in enumerate(text):
        if character == "[":
            depth += 1
        elif character == "]":
            if depth == 0:
                raise ValueError("Unbalanced xcodebuild destination brackets.")
            depth -= 1
        elif character == "," and depth == 0:
            entries.append(text[start:index])
            start = index + 1
    if depth:
        raise ValueError("Unbalanced xcodebuild destination brackets.")
    entries.append(text[start:])
    fields = {}
    for entry in entries:
        key, separator, value = entry.partition(":")
        if not separator or key.strip() in fields:
            raise ValueError("Malformed xcodebuild destination fields.")
        fields[key.strip()] = value.strip()
    return fields


def verify_scheme(device, arguments):
    """Check complete destination fields only within the scheme's available section."""
    scheme = option(arguments, "-scheme", "App")
    workspace = option(arguments, "-workspace", "App.xcworkspace")
    packages = option(arguments, "-clonedSourcePackagesDirPath", ".build/SourcePackages")
    destinations = capture("xcodebuild", "-workspace", workspace, "-scheme", scheme,
                           "-clonedSourcePackagesDirPath", packages, "-showdestinations")
    print(destinations, file=sys.stderr)
    available = False
    for line in destinations.splitlines():
        if line.strip() == f'Destinations compatible with the "{scheme}" scheme:':
            available = True
            continue
        if line.strip().startswith("Destinations incompatible with "):
            available = False
        row = re.fullmatch(r"\s*\{([^{}]+)\}\s*", line)
        if not available or not row:
            continue
        fields = destination_fields(row[1])
        if (fields.get("platform") == "iOS Simulator"
                and fields.get("id") == device["udid"]
                and fields.get("OS") == RUNTIME_VERSION
                and fields.get("name") == device["name"]):
            return
    raise ValueError(f"Verified UDID {device['udid']} is absent from scheme {scheme!r}'s available destinations.")


def main(arguments):
    """Print a resolved UDID, or recheck and exec one command with that identity."""
    separator = arguments.index("--") if "--" in arguments else len(arguments)
    selection, command = arguments[:separator], arguments[separator + 1:]
    if not 1 <= len(selection) <= 2 or (separator < len(arguments) and not command):
        raise ValueError("Usage: verify-xcode-27.2-destination.sh <destination or name> [expected UDID]"
                         " [-- xcodebuild <options> <action>]")
    if command and (command[0] != "xcodebuild" or any(
            item == "-destination" or item.startswith("-destination=") for item in command[1:])):
        raise ValueError("The verifier must supply the xcodebuild destination.")
    name = expected_name(selection[0])
    device = resolve_device(name, selection[1] if len(selection) == 2 else "")
    verify_scheme(device, command[1:])
    destination = f"platform=iOS Simulator,id={device['udid']}"
    print(f"Expected simulator name: {name}\nResolved simulator name: {device['name']}\n"
          f"Runtime identifier: {RUNTIME_IDENTIFIER}\nRuntime build: {RUNTIME_BUILD}\n"
          f"Verified UDID: {device['udid']}\nEffective destination: {destination}", file=sys.stderr)
    if command:
        # Re-read availability after scheme discovery, immediately before exec.
        resolve_device(name, device["udid"])
        command[1:1] = ["-destination", destination]
        print(f"Executing: {shlex.join(command)}", file=sys.stderr, flush=True)
        os.execvp(command[0], command)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"simulator_udid={device['udid']}\ndestination={destination}\n")
    print(device["udid"])


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Destination verification failed: {error}", file=sys.stderr)
        sys.exit(1)
