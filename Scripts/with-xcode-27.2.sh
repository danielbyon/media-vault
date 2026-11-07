#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  printf '%s\n' 'A command is required.' >&2
  exit 2
fi

script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
developer_directory=$("$script_directory/select-xcode-27.2.sh")
export DEVELOPER_DIR="$developer_directory"
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

selected_xcodebuild=$(command -v xcodebuild)
selected_swift_command=$(command -v swift)
selected_xcrun=$(command -v xcrun)
case "$selected_xcodebuild" in
  "$DEVELOPER_DIR"/usr/bin/xcodebuild) ;;
  *)
    printf 'PATH selected xcodebuild outside the verified Xcode: %s\n' "$selected_xcodebuild" >&2
    exit 1
    ;;
esac
case "$selected_swift_command" in
  "$DEVELOPER_DIR"/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift) ;;
  *)
    printf 'PATH selected Swift outside the verified Xcode: %s\n' "$selected_swift_command" >&2
    exit 1
    ;;
esac
if [[ "$selected_xcrun" != /usr/bin/xcrun ]]; then
  printf 'PATH selected xcrun outside the system shim: %s\n' "$selected_xcrun" >&2
  exit 1
fi

selected_swift=$(xcrun --find swift)
case "$selected_swift" in
  "$DEVELOPER_DIR"/Toolchains/XcodeDefault.xctoolchain/*) ;;
  *)
    printf 'xcrun selected Swift outside the verified Xcode: %s\n' "$selected_swift" >&2
    exit 1
    ;;
esac

"$script_directory/ensure-ios-27.2-runtime.sh"
exec "$@"
