#!/bin/bash
set -euo pipefail
set -o pipefail

script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_directory/.." && pwd)
xcode_wrapper="$script_directory/with-xcode-27-rc.sh"
swift_tools_adapter="$script_directory/swift-tools.sh"
swift_tools_local_config="$script_directory/swift-tools-local.sh"
compiler_log_directory="$repository_root/.build/swiftlint"
compiler_log="$compiler_log_directory/compiler.log"
app_derived_data="$compiler_log_directory/DerivedData/App"
package_derived_data="$compiler_log_directory/DerivedData/ApplicationFoundation"
iphone_destination="${IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=27.0}"

if [ ! -x "$swift_tools_adapter" ]; then
	printf '%s\n' "Shared Swift tooling is not installed. Run Scripts/swift-tools.sh bootstrap first." >&2
	exit 1
fi

if [ ! -f "$swift_tools_local_config" ]; then
	printf '%s\n' "Shared Swift tooling configuration is missing: $swift_tools_local_config" >&2
	exit 1
fi

SWIFT_TOOLS_ROOT="$repository_root"
SWIFT_TOOLS_SOURCE_PATHS=()
SWIFT_TOOLS_SWIFTLINT_CONFIG=''
# shellcheck source=/dev/null
source "$swift_tools_local_config"
if [ "${#SWIFT_TOOLS_SOURCE_PATHS[@]}" -eq 0 ]; then
	printf '%s\n' "Shared Swift tooling configuration does not define source paths." >&2
	exit 1
fi
for source_path in "${SWIFT_TOOLS_SOURCE_PATHS[@]}"; do
	if [[ "$source_path" != /* ]]; then
		source_path="$repository_root/$source_path"
	fi
	if [ ! -e "$source_path" ]; then
		printf '%s\n' "Configured Swift source path is missing: $source_path" >&2
		exit 1
	fi
done
if [[ -n "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]]; then
	if [[ "$SWIFT_TOOLS_SWIFTLINT_CONFIG" != /* ]]; then
		SWIFT_TOOLS_SWIFTLINT_CONFIG="$repository_root/$SWIFT_TOOLS_SWIFTLINT_CONFIG"
	fi
	if [ ! -f "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]; then
		printf '%s\n' "SwiftLint configuration is missing: $SWIFT_TOOLS_SWIFTLINT_CONFIG" >&2
		exit 1
	fi
fi

mkdir -p "$compiler_log_directory"
: > "$compiler_log"

run_xcodebuild() {
  "$xcode_wrapper" xcodebuild -skipMacroValidation "$@" 2>&1 | tee -a "$compiler_log"
}

run_xcodebuild \
  -workspace "$repository_root/App.xcworkspace" \
  -scheme App \
  -configuration Debug \
  -destination "$iphone_destination" \
  -derivedDataPath "$app_derived_data" \
  clean build-for-testing

run_xcodebuild \
  -workspace "$repository_root/Packages/ApplicationFoundation/.swiftpm/xcode/package.xcworkspace" \
  -scheme ApplicationFoundation-Package \
  -configuration Debug \
  -destination "$iphone_destination" \
  -derivedDataPath "$package_derived_data" \
  clean build-for-testing

cd "$repository_root"

# Keep every first-party Swift file in the analyzer input while bounding the
# number of concurrent macro-heavy Swift Testing files handled by SourceKit.
# A single large SwiftLint 0.65.1 invocation can crash the Xcode 27 RC
# compiler service even though the same files build and analyze successfully
# in smaller explicit batches.
swift_files=()
while IFS= read -r swift_file; do
	swift_files+=("$swift_file")
done < <(
	rg --files "${SWIFT_TOOLS_SOURCE_PATHS[@]}" \
		-g '*.swift' \
    -g '!**/Generated/**' \
    -g '!**/*.generated.swift' \
    | sort
)

analyze_batch() {
	"$swift_tools_adapter" configured swiftlint analyze \
		--compiler-log-path "$compiler_log" \
		"$@"
}

batch_size=8
for ((batch_start = 0; batch_start < ${#swift_files[@]}; batch_start += batch_size)); do
  analyze_batch "${swift_files[@]:batch_start:batch_size}"
done
