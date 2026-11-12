#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  printf '%s\n' 'DEVELOPER_DIR is not set; invoke this check through with-xcode-27.2.sh.' >&2
  exit 1
fi

# Keep diagnostics on stderr so the last stdout line is the resolved UDID.
printf 'Runner image: OS=%s version=%s\n' "${ImageOS:-unknown}" "${ImageVersion:-unknown}" >&2
printf 'Source revision: %s\n' "${GITHUB_SHA:-local}" >&2
printf 'Developer directory: %s\n' "$DEVELOPER_DIR" >&2
xcodebuild -version >&2
swift --version >&2
printf 'xcrun executable: %s\n' "$(command -v xcrun)" >&2
printf 'xcrun selected Swift: %s\n' "$(xcrun --find swift)" >&2

toolchain_id=$( { xcodebuild -version; swift --version | sed -n '1p'; } | shasum -a 256 | cut -c 1-16 )
printf 'Toolchain cache id: %s\n' "$toolchain_id" >&2
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'id=%s\n' "$toolchain_id" >> "$GITHUB_OUTPUT"
fi

script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$script_directory/resolve-xcode-27.2-destination.py" "$@"
