#!/usr/bin/env bash

# Configure the project-specific inputs consumed by the shared Swift tooling
# release. The shared release supplies the baseline policy and pinned tools;
# this file supplies the repository's source roots, local policy overlays, and
# Xcode selection required by compiler-backed SwiftLint analysis.
SWIFT_TOOLS_SOURCE_PATHS=(App AppTests Packages)
SWIFT_TOOLS_SWIFTFORMAT_CONFIG=.swiftformat
SWIFT_TOOLS_SWIFTLINT_CONFIG=.swiftlint.yml
SWIFT_TOOLS_COMMAND_PREFIX=("$SWIFT_TOOLS_ROOT/Scripts/with-xcode-27-rc.sh")
