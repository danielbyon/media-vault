#!/bin/bash
set -euo pipefail

configuration_directory="App/Configuration"
release_configuration="$configuration_directory/Release.xcconfig"
debug_configuration="$configuration_directory/Debug.xcconfig"

read_setting() {
  local key="$1"
  local file="$2"
  awk -F ' = ' -v expected_key="$key" '$1 == expected_key { print $2; exit }' "$file"
}

release_display_name=$(read_setting APP_DISPLAY_NAME "$release_configuration")
debug_display_name=$(read_setting APP_DISPLAY_NAME "$debug_configuration")
release_identifier=$(read_setting PRODUCT_BUNDLE_IDENTIFIER "$release_configuration")
debug_identifier=$(read_setting PRODUCT_BUNDLE_IDENTIFIER "$debug_configuration")

if [ -z "$release_display_name" ] || [ -z "$debug_display_name" ] \
  || [ -z "$release_identifier" ] || [ -z "$debug_identifier" ]; then
  printf '%s\n' "Release and Debug identity settings must be present." >&2
  exit 1
fi

if [ "$debug_display_name" != "$release_display_name Dev" ]; then
  printf '%s\n' "Debug display identity must append the internal suffix." >&2
  exit 1
fi

if [ "$debug_identifier" != "$release_identifier.dev" ]; then
  printf '%s\n' "Debug bundle identity must append the internal suffix." >&2
  exit 1
fi

case "$release_identifier" in
  com.danielbyon.*) ;;
  *)
    printf '%s\n' "The release bundle identity must use the approved company namespace." >&2
    exit 1
    ;;
esac

if ! rg -q '<string>\$\(APP_DISPLAY_NAME\)</string>' App/Resources/Info.plist \
  || ! rg -q '<string>\$\(PRODUCT_BUNDLE_IDENTIFIER\)</string>' App/Resources/Info.plist; then
  printf '%s\n' "The application resource must consume identity through build settings." >&2
  exit 1
fi

assert_identity_isolated() {
  local value="$1"
  local description="$2"

  local matches
  local scan_status

  if matches=$(rg -n -i --hidden --fixed-strings "$value" . \
    --glob '!.git/**' \
    --glob '!.chatgpt/**' \
    --glob '!.codegraph/**' \
    --glob '!.serena/**' \
    --glob '!App/Configuration/**' \
    --glob '!App/Resources/**' \
    --glob '!.build/**' \
    --glob '!.swiftpm/**'); then
    printf '%s\n' "$matches"
    printf '%s\n' "$description leaked outside the approved configuration/resource boundary." >&2
    exit 1
  else
    scan_status=$?
    if [ "$scan_status" -ne 1 ]; then
      printf '%s\n' "The identity isolation scan failed for $description." >&2
      exit 1
    fi
  fi
}

assert_identity_isolated "$release_display_name" "Release display identity"
assert_identity_isolated "$debug_display_name" "Debug display identity"
assert_identity_isolated "$release_identifier" "Release bundle identity"
assert_identity_isolated "$debug_identifier" "Debug bundle identity"

printf '%s\n' "Release and Debug identity isolation passed."
