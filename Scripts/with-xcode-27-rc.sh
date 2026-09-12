#!/bin/bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  printf '%s\n' "A command is required." >&2
  exit 2
fi

script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
developer_directory=$("$script_directory/select-xcode-27-rc.sh")
export DEVELOPER_DIR="$developer_directory"
"$script_directory/ensure-ios-27-runtime.sh"
exec "$@"
