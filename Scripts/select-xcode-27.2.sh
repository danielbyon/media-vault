#!/usr/bin/env bash
set -euo pipefail

expected_version="27.2"
expected_build="27B52"

validate_developer_directory() {
  local developer_directory="$1"
  local xcodebuild_path="$developer_directory/usr/bin/xcodebuild"
  local version_output
  local version
  local build
  local sdk_output

  if [[ ! -x "$xcodebuild_path" ]]; then
    printf 'Xcode executable is missing: %s\n' "$xcodebuild_path" >&2
    return 1
  fi

  if ! version_output=$(DEVELOPER_DIR="$developer_directory" "$xcodebuild_path" -version 2>&1); then
    printf 'Unable to read Xcode version from %s:\n%s\n' "$xcodebuild_path" "$version_output" >&2
    return 1
  fi

  version=$(sed -n '1s/^Xcode //p' <<<"$version_output")
  build=$(sed -n 's/^Build version //p' <<<"$version_output")
  if [[ "$version" != "$expected_version" || "$build" != "$expected_build" ]]; then
    printf 'Expected Xcode %s build %s at %s; observed version=%s build=%s.\n' \
      "$expected_version" "$expected_build" "$developer_directory" \
      "${version:-unknown}" "${build:-unknown}" >&2
    return 1
  fi

  if ! sdk_output=$(DEVELOPER_DIR="$developer_directory" "$xcodebuild_path" -showsdks 2>&1); then
    printf 'Unable to list SDKs from %s:\n%s\n' "$xcodebuild_path" "$sdk_output" >&2
    return 1
  fi
  if ! grep -Fq 'iphoneos27.2' <<<"$sdk_output" \
    || ! grep -Fq 'iphonesimulator27.2' <<<"$sdk_output"; then
    printf 'Xcode %s build %s at %s does not provide both iOS 27.2 SDKs.\n' \
      "$expected_version" "$expected_build" "$developer_directory" >&2
    return 1
  fi
}

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  validate_developer_directory "$DEVELOPER_DIR"
  printf '%s\n' "$DEVELOPER_DIR"
  exit 0
fi

observations=""
for developer_directory in \
  /Applications/Xcode-27.2.0.app/Contents/Developer \
  /Applications/Xcode_27.2.0.app/Contents/Developer \
  /Applications/Xcode_27.2.app/Contents/Developer; do
  [[ -d "$developer_directory" ]] || continue
  if observation=$(validate_developer_directory "$developer_directory" 2>&1); then
    printf '%s\n' "$developer_directory"
    exit 0
  fi
  observations+="$observation"$'\n'
done

printf 'Xcode 27.2 release build %s is required. Set DEVELOPER_DIR to its Developer directory.\n' \
  "$expected_build" >&2
if [[ -n "$observations" ]]; then
  printf '%s' "$observations" >&2
else
  printf '%s\n' 'No supported Xcode 27.2 installation was found under /Applications.' >&2
fi
exit 1
