#!/bin/bash
set -euo pipefail

runtime_is_available() {
  xcrun simctl list runtimes \
    | awk '/iOS 27\.0[[:space:]]/ && /com\.apple\.CoreSimulator\.SimRuntime\.iOS-27-0/ && $0 !~ /unavailable/ { found = 1 } END { exit !found }'
}

if runtime_is_available; then
  exit 0
fi

printf '%s\n' "The iOS 27 simulator runtime is missing; attempting the normal Xcode platform download." >&2
if ! xcodebuild -downloadPlatform iOS; then
  printf '%s\n' "The iOS 27 simulator runtime could not be installed with normal host permissions." >&2
  exit 1
fi

if ! runtime_is_available; then
  printf '%s\n' "The Xcode platform download completed without an available iOS 27 simulator runtime." >&2
  exit 1
fi
