#!/usr/bin/env bash
set -euo pipefail

expected_runtime_line='iOS 27.2 (27.2 - 24B8117) - com.apple.CoreSimulator.SimRuntime.iOS-27-2'

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  printf '%s\n' 'DEVELOPER_DIR must identify the verified Xcode 27.2 installation.' >&2
  exit 1
fi

if ! runtime_inventory=$(xcrun simctl list runtimes 2>&1); then
  printf 'Unable to list simulator runtimes using DEVELOPER_DIR=%s:\n%s\n' \
    "$DEVELOPER_DIR" "$runtime_inventory" >&2
  exit 1
fi

if ! grep -Fqx "$expected_runtime_line" <<<"$runtime_inventory"; then
  printf 'Required simulator runtime is unavailable: %s\n' "$expected_runtime_line" >&2
  printf 'Observed iOS runtimes:\n%s\n' "$(grep -E '^iOS ' <<<"$runtime_inventory" || true)" >&2
  printf '%s\n' 'Install the matching iOS 27.2 runtime in Xcode before running this gate; automatic downloads are disabled.' >&2
  exit 1
fi

printf 'Verified simulator runtime: %s\n' "$expected_runtime_line"
