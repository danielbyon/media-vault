#!/bin/bash
set -euo pipefail

shopt -s nullglob

for developer_directory in /Applications/Xcode*.app/Contents/Developer; do
  application_name=$(basename "${developer_directory%/Contents/Developer}")

  case "$application_name" in
    *[Bb]eta*.app|*[Aa]lpha*.app) continue ;;
  esac

  version_output=$(DEVELOPER_DIR="$developer_directory" xcodebuild -version)
  version=${version_output%%$'\n'*}
  case "$version" in
    "Xcode 27."*)
      sdk_output=$(DEVELOPER_DIR="$developer_directory" xcodebuild -showsdks)
      if rg -q 'iphoneos27\.[0-9]+' <<<"$sdk_output" \
        && rg -q 'iphonesimulator27\.[0-9]+' <<<"$sdk_output"; then
        printf '%s\n' "$developer_directory"
        exit 0
      fi
      ;;
  esac
done

printf '%s\n' "Xcode 27 RC (or a later Xcode 27 release) is required but is not installed in /Applications." >&2
exit 1
