#!/bin/bash
set -euo pipefail
set -o pipefail

script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_directory/.." && pwd)
xcode_wrapper="$script_directory/with-xcode-27-rc.sh"
swift_tools_adapter="$script_directory/swift-tools.sh"
swift_tools_local_config="$script_directory/swift-tools-local.sh"
compiler_log_directory="$repository_root/.build/swiftlint"
# Reuse the package checkout cache the Makefile maintains so every gate clones
# dependencies once; only compiler and build products live in the per-run
# analyzer directory below.
source_packages_directory="$repository_root/.build/SourcePackages"
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
# Analyzer runs that are killed outright (SIGKILL) never reach their cleanup
# trap, so bound how long an abandoned run directory can survive. Only this
# script's own run.* directories are pruned; caches, package checkouts and
# unrelated build artifacts are never touched.
find "$compiler_log_directory" -maxdepth 1 -type d -name 'run.*' -mtime +0 -exec rm -rf -- {} +
analysis_directory=$(mktemp -d "$compiler_log_directory/run.XXXXXX")
trap 'rm -rf -- "$analysis_directory"' EXIT
trap 'exit 143' INT TERM
compiler_log="$analysis_directory/compiler.log"
app_derived_data="$analysis_directory/DerivedData/App"
package_derived_data="$analysis_directory/DerivedData/ApplicationFoundation"
overview_ui_test_derived_data="$analysis_directory/DerivedData/BrowserTabOverviewUITests"
: > "$compiler_log"

run_xcodebuild() {
  "$xcode_wrapper" xcodebuild -skipMacroValidation "$@" 2>&1 | tee -a "$compiler_log"
}

run_xcodebuild \
  -workspace "$repository_root/App.xcworkspace" \
  -scheme App \
  -configuration Debug \
  -destination "$iphone_destination" \
  -clonedSourcePackagesDirPath "$source_packages_directory" \
  -derivedDataPath "$app_derived_data" \
  clean build-for-testing

run_xcodebuild \
  -workspace "$repository_root/Packages/ApplicationFoundation/.swiftpm/xcode/package.xcworkspace" \
  -scheme ApplicationFoundation-Package \
  -configuration Debug \
  -destination "$iphone_destination" \
  -clonedSourcePackagesDirPath "$source_packages_directory" \
  -derivedDataPath "$package_derived_data" \
  clean build-for-testing

# The overview UI test target has its own scheme; the `App` scheme does not build
# it, so this invocation is what makes its host and test sources appear in the
# compiler log analyzed below.
run_xcodebuild \
  -workspace "$repository_root/App.xcworkspace" \
  -scheme BrowserTabOverviewUITests \
  -configuration Debug \
  -destination "$iphone_destination" \
  -clonedSourcePackagesDirPath "$source_packages_directory" \
  -derivedDataPath "$overview_ui_test_derived_data" \
  clean build-for-testing

cd "$repository_root"

# SwiftLint 0.65.1 keys compiler-log invocations by absolute file URL and
# matches them against the absolute path of each analyzer input. Relative
# inputs match no invocation, and SwiftLint then reports "Done analyzing! Found
# 0 violations, 0 serious in 0 files." while still exiting 0, which is a false
# green. Every analyzer input therefore has to be absolute, and the guard below
# fails when a pass processes fewer files than expected.
#
# `Package.swift` manifests are excluded because SwiftPM manifests never appear
# as compiler invocations in the log. The processed-file guard is intentionally
# strict: a first-party file that none of the build-for-testing invocations above
# compiles fails the gate instead of being silently dropped from analysis.
analyzer_files=()
while IFS= read -r swift_file; do
  if [[ "$swift_file" != /* ]]; then
    swift_file="$repository_root/$swift_file"
  fi
  analyzer_files+=("$swift_file")
done < <(
  rg --files "${SWIFT_TOOLS_SOURCE_PATHS[@]}" \
    -g '*.swift' \
    -g '!**/Package.swift' \
    -g '!**/Generated/**' \
    -g '!**/*.generated.swift' \
    | sort
)

if [ "${#analyzer_files[@]}" -eq 0 ]; then
  printf '%s\n' "Compiler-backed SwiftLint analysis found no first-party Swift files to analyze." >&2
  exit 1
fi

# xcodebuild escapes characters in logged compiler invocations and SwiftLint
# 0.65.1 only unescapes `\ ` and `\=`. The `\#` escape is left in place, which
# corrupts `-load-plugin-executable` paths such as
# `.../DependenciesMacrosPlugin\#DependenciesMacrosPlugin`; SourceKit then fails
# every macro expansion and aborts some Swift Testing files outright. The raw
# log is kept for diagnostics and SwiftLint receives an unescaped copy.
analyzer_compiler_log="$analysis_directory/compiler-analyzer.log"
sed 's/\\#/#/g' "$compiler_log" > "$analyzer_compiler_log"

# Each analyzer rule runs over the complete file list in its own pass. A single
# invocation with several analyzer rules enabled crashes the Xcode 27 Swift
# compiler service while expanding Swift Testing macros, and the crash aborts
# the run before SwiftLint prints a completion summary. Batching the corpus into
# fixed-size chunks is not an alternative either: `unused_declaration` only
# reports a declaration after checking every other analyzed file for a
# reference, so a partial corpus would change what the rule means. One rule per
# complete-corpus pass preserves every rule's semantics.
#
# The rule names come from SwiftLint's own effective configuration so the
# configuration stays the single source of truth and a rule added there cannot
# be silently omitted from the gate. `swiftlint rules --enabled` reports every
# enabled rule together with whether it runs in analyzer mode, which is the
# selection `swiftlint analyze` would run; reading `analyzer_rules` out of the
# YAML directly would be a second, narrower interpretation of the same setting.
if [ -z "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]; then
  printf '%s\n' "Shared Swift tooling configuration does not define a SwiftLint configuration path." >&2
  exit 1
fi
analyzer_rules_file="$analysis_directory/analyzer-rules.txt"
if ! "$swift_tools_adapter" configured swiftlint rules \
    --config "$SWIFT_TOOLS_SWIFTLINT_CONFIG" \
    --enabled \
  | awk -F'|' '
      NF < 9 { next }
      {
        identifier = $2
        enabled = $5
        analyzer = $7
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", identifier)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", enabled)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", analyzer)
        if (identifier == "" || enabled != "yes" || analyzer != "yes") { next }
        if (identifier !~ /^[A-Za-z0-9_]+$/) {
          printf "Unrecognized analyzer rule identifier: %s\n", identifier > "/dev/stderr"
          exit 1
        }
        print identifier
      }
    ' > "$analyzer_rules_file"; then
  printf '%s\n' "SwiftLint could not report the analyzer rules enabled by: $SWIFT_TOOLS_SWIFTLINT_CONFIG" >&2
  exit 1
fi
analyzer_rules=()
while IFS= read -r analyzer_rule; do
  analyzer_rules+=("$analyzer_rule")
done < "$analyzer_rules_file"
if [ "${#analyzer_rules[@]}" -eq 0 ]; then
  printf '%s\n' "SwiftLint configuration defines no analyzer rules to run: $SWIFT_TOOLS_SWIFTLINT_CONFIG" >&2
  exit 1
fi
expected_file_count=${#analyzer_files[@]}
analyzer_violation_count=0

for analyzer_rule in "${analyzer_rules[@]}"; do
  rule_log="$analysis_directory/analyzer-$analyzer_rule.log"
  analysis_status=0
  "$swift_tools_adapter" configured swiftlint analyze \
    --compiler-log-path "$analyzer_compiler_log" \
    --only-rule "$analyzer_rule" \
    "${analyzer_files[@]}" 2>&1 | tee "$rule_log" || analysis_status=$?

  summary_line=$(grep -m 1 '^Done analyzing!' "$rule_log" || true)
  if [ -z "$summary_line" ]; then
    printf '%s\n' "SwiftLint analyzer rule '$analyzer_rule' printed no completion summary (exit status $analysis_status); treating the pass as failed." >&2
    exit 1
  fi
  rule_violations=$(printf '%s\n' "$summary_line" | sed -n 's/^Done analyzing! Found \([0-9][0-9]*\) violations,.*$/\1/p')
  rule_files=$(printf '%s\n' "$summary_line" | sed -n 's/^Done analyzing! Found [0-9][0-9]* violations, [0-9][0-9]* serious in \([0-9][0-9]*\) files\{0,1\}\.$/\1/p')
  if [ -z "$rule_violations" ] || [ -z "$rule_files" ]; then
    printf '%s\n' "SwiftLint analyzer rule '$analyzer_rule' printed an unrecognized summary: $summary_line" >&2
    exit 1
  fi
  if [ "$rule_files" -ne "$expected_file_count" ]; then
    printf '%s\n' "SwiftLint analyzer rule '$analyzer_rule' processed $rule_files of $expected_file_count expected first-party files; refusing to report a partial analysis as a pass." >&2
    exit 1
  fi
  if [ "$analysis_status" -ne 0 ] && [ "$analysis_status" -ne 2 ]; then
    printf '%s\n' "SwiftLint analyzer rule '$analyzer_rule' exited with status $analysis_status instead of a lint result; treating the pass as failed." >&2
    exit 1
  fi
  if [ "$analysis_status" -eq 0 ] && [ "$rule_violations" -ne 0 ]; then
    printf '%s\n' "SwiftLint analyzer rule '$analyzer_rule' reported $rule_violations violation(s) but exited 0; treating the pass as failed." >&2
    exit 1
  fi
  if [ "$rule_violations" -gt 0 ]; then
    printf '%s\n' "SwiftLint analyzer rule '$analyzer_rule': $rule_violations violation(s) across $rule_files files." >&2
  fi
  analyzer_violation_count=$((analyzer_violation_count + rule_violations))
done

if [ "$analyzer_violation_count" -ne 0 ]; then
  printf '%s\n' "Compiler-backed SwiftLint analysis reported $analyzer_violation_count violation(s) across ${#analyzer_rules[@]} complete-corpus passes over $expected_file_count files." >&2
  exit 1
fi

printf '%s\n' "Compiler-backed SwiftLint analysis passed: ${#analyzer_rules[@]} complete-corpus passes over $expected_file_count files with 0 violations."
