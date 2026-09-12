#!/bin/bash
set -euo pipefail
set -o pipefail

script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_directory/.." && pwd)
xcode_wrapper="$script_directory/with-xcode-27-rc.sh"
compiler_log_directory="$repository_root/.build/swiftlint"
compiler_log="$compiler_log_directory/compiler.log"
app_derived_data="$compiler_log_directory/DerivedData/App"
package_derived_data="$compiler_log_directory/DerivedData/ApplicationFoundation"
iphone_destination="${IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=27.0}"
mint_binary="$repository_root/.build/tools/mint/0.18.0/mint"

if [ ! -x "$mint_binary" ]; then
  printf '%s\n' "Pinned Mint is not bootstrapped. Run Scripts/bootstrap-swift-tools.sh first." >&2
  exit 1
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

export MINT_PATH="$repository_root/.build/mint"
export MINT_LINK_PATH="$MINT_PATH/bin"

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
  rg --files App AppTests Packages \
    -g '*.swift' \
    -g '!**/Generated/**' \
    -g '!**/*.generated.swift' \
    | sort
)

analyze_batch() {
  "$xcode_wrapper" env \
    MINT_PATH="$MINT_PATH" \
    MINT_LINK_PATH="$MINT_LINK_PATH" \
    "$mint_binary" run realm/SwiftLint analyze \
    --config .swiftlint.yml \
    --compiler-log-path "$compiler_log" \
    "$@"
}

batch_size=8
for ((batch_start = 0; batch_start < ${#swift_files[@]}; batch_start += batch_size)); do
  analyze_batch "${swift_files[@]:batch_start:batch_size}"
done
