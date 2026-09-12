#!/bin/bash
set -euo pipefail

if matches=$(rg -n --hidden '[[:blank:]]+\r?$' \
  App \
  AppTests \
  Packages \
  Scripts \
  Makefile \
  App.xcodeproj \
  App.xcworkspace); then
  printf '%s\n' "$matches" >&2
  printf '%s\n' "Trailing whitespace found in implementation files." >&2
  exit 1
else
  scan_status=$?
  if [ "$scan_status" -ne 1 ]; then
    printf '%s\n' "The implementation whitespace scan failed." >&2
    exit 1
  fi
fi

printf '%s\n' "Implementation whitespace passed."
