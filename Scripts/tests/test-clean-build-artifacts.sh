#!/bin/bash
set -euo pipefail
shopt -s nullglob

# These fixtures use disposable Git repositories and the real Make clean
# target. They do not require Xcode, SwiftPM, network access, or a prior build.
repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
readonly repository_root
readonly makefile_source="$repository_root/Makefile"
readonly clean_script_source="$repository_root/Scripts/clean-build-artifacts.sh"
readonly gitignore_source="$repository_root/.gitignore"
readonly test_shell="${CLEAN_TEST_SHELL:-/bin/bash}"

[[ -x "$test_shell" ]] || {
  printf 'clean fixture tests: test shell is not executable: %s\n' "$test_shell" >&2
  exit 1
}

# Git may keep a trace2 daemon alive briefly while a disposable fixture is
# removed. Route trace output to /dev/null for deterministic test cleanup.
export GIT_TRACE2_EVENT=/dev/null

test_root=$(mktemp -d "${TMPDIR:-/tmp}/media-vault-clean-tests.XXXXXX")
readonly test_root
readonly output_directory="$test_root/outputs"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

mkdir -p "$output_directory"

fail() {
  printf 'clean fixture tests: %s\n' "$1" >&2
  exit 1
}

assert_exists() {
  local path=$1
  [[ -e "$path" || -L "$path" ]] || fail "expected path to exist: $path"
}

assert_missing() {
  local path=$1
  [[ ! -e "$path" && ! -L "$path" ]] || fail "expected path to be absent: $path"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" ||
    fail "expected '$expected' in $file:\n$(cat "$file")"
}

assert_not_contains() {
  local file=$1
  local unexpected=$2
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '$unexpected' in $file:\n$(cat "$file")"
  fi
}

assert_matches() {
  local file=$1
  local pattern=$2
  grep -Eq -- "$pattern" "$file" ||
    fail "expected output matching '$pattern' in $file:\n$(cat "$file")"
}

write_text() {
  local path=$1
  local contents=$2
  mkdir -p "${path%/*}"
  printf '%s\n' "$contents" >"$path"
}

assert_summary() {
  local file=$1
  local inspected=$2
  local removed=$3
  local skipped=$4
  assert_contains "$file" \
    "clean: inspected $inspected candidate(s), removed $removed, skipped $skipped, reclaimed"
}

new_fixture() {
  local scenario=$1
  local fixture="$test_root/$scenario/repository with spaces"

  mkdir -p "$fixture/Scripts"
  cp "$makefile_source" "$fixture/Makefile"
  cp "$clean_script_source" "$fixture/Scripts/clean-build-artifacts.sh"
  cp "$gitignore_source" "$fixture/.gitignore"
  chmod 755 "$fixture/Scripts/clean-build-artifacts.sh"
  write_text "$fixture/README.md" "Disposable cleanup fixture."
  write_text \
    "$fixture/App.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    '{"pins":[],"version":2}'

  git -C "$fixture" init -q
  git -C "$fixture" config user.name "Clean Fixture"
  git -C "$fixture" config user.email "clean-fixture@example.invalid"
  git -C "$fixture" add -- Makefile Scripts/clean-build-artifacts.sh .gitignore \
    README.md App.xcworkspace/xcshareddata/swiftpm/Package.resolved
  git -C "$fixture" commit -q -m "fixture baseline"
  printf '%s\n' "$fixture"
}

record_pin() {
  local fixture=$1
  local identity=$2
  local location=$3
  local revision=$4
  local kind=${5:-remoteSourceControl}
  local lockfile="$fixture/App.xcworkspace/xcshareddata/swiftpm/Package.resolved"

  python3 - "$lockfile" "$identity" "$location" "$revision" "$kind" <<'PY'
import json
import sys

lockfile, identity, location, revision, kind = sys.argv[1:]
with open(lockfile, encoding="utf-8") as stream:
    document = json.load(stream)

pins = document.setdefault("pins", [])
pins[:] = [pin for pin in pins if pin.get("identity") != identity]
pins.append(
    {
        "identity": identity,
        "kind": kind,
        "location": location,
        "state": {"revision": revision},
    }
)
with open(lockfile, "w", encoding="utf-8") as stream:
    json.dump(document, stream, indent=2)
    stream.write("\n")
PY

  git -C "$fixture" add -- \
    App.xcworkspace/xcshareddata/swiftpm/Package.resolved
  git -C "$fixture" commit -q -m "pin $identity"
}

create_checkout() {
  local fixture=$1
  local checkout_path=$2
  local location=$3
  local identity=${4:-${checkout_path##*/}}
  local revision

  mkdir -p "${checkout_path%/*}"
  git -C "$fixture" init -q "$checkout_path"
  git -C "$checkout_path" config user.name "Clean Fixture"
  git -C "$checkout_path" config user.email "clean-fixture@example.invalid"
  git -C "$checkout_path" remote add origin "$location"
  write_text "$checkout_path/Package.swift" "clean dependency manifest"
  git -C "$checkout_path" add -- Package.swift
  git -C "$checkout_path" commit -q -m "fixture dependency"
  revision=$(git -C "$checkout_path" rev-parse HEAD)
  record_pin "$fixture" "$identity" "$location" "$revision"
}

create_independent_repository() {
  local path=$1

  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config user.name "Clean Fixture"
  git -C "$path" config user.email "clean-fixture@example.invalid"
  write_text "$path/Package.swift" "independent repository"
  git -C "$path" add -- Package.swift
  git -C "$path" commit -q -m "independent fixture"
}

run_clean() {
  local fixture=$1
  local output=$2

  if ! (cd -- "$fixture" &&
    make --no-print-directory SHELL="$test_shell" clean) >"$output" 2>&1; then
    fail "make clean failed in $fixture:\n$(cat "$output")"
  fi
}

populate_protected_state() {
  local fixture=$1

  write_text "$fixture/App/Source.swift" "source code"
  write_text "$fixture/App/Artwork/Master.svg" "approved artwork"
  write_text "$fixture/App/Configuration/Local.xcconfig" "LOCAL_SETTING = preserved"
  write_text "$fixture/AppTests/Fixture.swift" "test source"
  write_text "$fixture/Snapshots/Baseline.png" "snapshot"
  write_text "$fixture/.chatgpt/evidence.json" "review evidence"
  write_text "$fixture/.tools/bin/tool" "shared tool"
  write_text "$fixture/.codegraph/index" "code index"
  write_text "$fixture/.worktrees/notes/README.md" "worktree notes"
  write_text "$fixture/.serena/project.yml" "developer setup"
  write_text "$fixture/.swiftpm/xcode/xcuserdata/User.xcuserdatad/settings" \
    "user state"
  write_text "$fixture/xcuserdata/User.xcuserdatad/settings" "user state"
  write_text "$fixture/.DS_Store" "finder metadata"
  write_text "$fixture/DerivedData/app/output.o" "ambiguous local output"
  write_text "$fixture/build/app/output.o" "ambiguous local output"
  write_text "$fixture/Packages/Core/.build/debug/output.o" "package object"
  write_text "$fixture/Packages/Core/build/Release/output.o" \
    "legacy package object"
}

# Standard cleanup removes one pinned checkout, reports three ambiguous stale
# Make paths and one unknown checkouts child, and leaves every protected tree.
fixture=$(new_fixture standard-cleanup)
eligible="$fixture/.build/SourcePackages/checkouts/Package"
create_checkout "$fixture" "$eligible" "https://example.invalid/Package"
write_text "$fixture/.build/xcodebuild-build.ABC/Build/Products/output.o" \
  "derived data"
write_text "$fixture/.build/xcodebuild-test.ABC/App/Build/Products/test.o" \
  "application test data"
write_text "$fixture/.build/swiftlint/run.ABC/compiler.log" "compiler log"
write_text "$fixture/.build/xcodebuild-archive.KEEP/output.o" "unknown archive"
write_text "$fixture/.build/DerivedData/app/output.o" "ambiguous derived data"
write_text "$fixture/.build/SourcePackages-old/output.o" "lookalike cache"
write_text "$fixture/.build/swiftlint-cache/output.o" "lookalike lint cache"
write_text "$fixture/.build/custom-tool/state.db" "unknown cache content"
write_text "$fixture/.build/SourcePackages/checkouts/Unknown/state.db" \
  "unknown checkout content"
populate_protected_state "$fixture"
outside_target="$test_root/standard-outside-target"
write_text "$outside_target/sentinel" "outside target"
ln -s "$outside_target" "$fixture/.build/xcodebuild-build.ABC/external-link"

standard_output="$output_directory/standard.log"
run_clean "$fixture" "$standard_output"
assert_exists "$fixture/.build"
assert_missing "$eligible"
assert_exists "$fixture/.build/SourcePackages/checkouts"
assert_exists "$fixture/.build/SourcePackages/checkouts/Unknown/state.db"
assert_exists "$fixture/.build/xcodebuild-build.ABC/Build/Products/output.o"
assert_exists "$fixture/.build/xcodebuild-test.ABC/App/Build/Products/test.o"
assert_exists "$fixture/.build/swiftlint/run.ABC/compiler.log"
assert_exists "$fixture/.build/xcodebuild-archive.KEEP/output.o"
assert_exists "$fixture/.build/DerivedData/app/output.o"
assert_exists "$fixture/.build/SourcePackages-old/output.o"
assert_exists "$fixture/.build/swiftlint-cache/output.o"
assert_exists "$fixture/.build/custom-tool/state.db"
assert_exists "$outside_target/sentinel"
assert_exists "$fixture/App/Source.swift"
assert_exists "$fixture/App/Artwork/Master.svg"
assert_exists "$fixture/App/Configuration/Local.xcconfig"
assert_exists "$fixture/.chatgpt/evidence.json"
assert_exists "$fixture/.tools/bin/tool"
assert_exists "$fixture/.codegraph/index"
assert_exists "$fixture/.serena/project.yml"
assert_exists "$fixture/Packages/Core/.build/debug/output.o"
assert_exists "$fixture/Packages/Core/build/Release/output.o"
assert_contains "$standard_output" ".build/xcodebuild-build.ABC (current Make invocation"
assert_contains "$standard_output" ".build/xcodebuild-test.ABC (current Make invocation"
assert_contains "$standard_output" ".build/swiftlint (current Make invocation"
assert_contains "$standard_output" ".build/SourcePackages/checkouts/Unknown (no unambiguous tracked package pin"
assert_matches "$standard_output" \
  'clean: removed \.build/SourcePackages/checkouts/Package \([1-9][0-9]* KiB\)'
assert_summary "$standard_output" 5 1 4
assert_matches "$standard_output" 'reclaimed [1-9][0-9]* KiB$'

# Missing and empty caches are successful, repeatable no-op cleanup runs.
fixture=$(new_fixture missing-and-repeated)
missing_output="$output_directory/missing.log"
empty_output="$output_directory/empty.log"
repeated_output="$output_directory/repeated.log"
run_clean "$fixture" "$missing_output"
assert_summary "$missing_output" 0 0 0
assert_contains "$missing_output" "reclaimed 0 KiB"
mkdir -p "$fixture/.build/SourcePackages/checkouts"
run_clean "$fixture" "$empty_output"
assert_summary "$empty_output" 0 0 0
run_clean "$fixture" "$repeated_output"
assert_summary "$repeated_output" 0 0 0

# A tracked descendant, dirty package, non-Git unknown child, and an
# independent repository are preserved while another pinned package is removed.
fixture=$(new_fixture unsafe-and-unknown)
dependency="$fixture/.build/SourcePackages/checkouts/Dependency"
create_checkout "$fixture" "$dependency" \
  "https://example.invalid/Dependency"
tracked_candidate="$fixture/.build/SourcePackages/checkouts/Tracked"
write_text "$tracked_candidate/Source.swift" "tracked build descendant"
git -C "$fixture" add -f -- \
  .build/SourcePackages/checkouts/Tracked/Source.swift
git -C "$fixture" commit -q -m "tracked cleanup descendant"
dirty_candidate="$fixture/.build/SourcePackages/checkouts/Dirty"
create_checkout "$fixture" "$dirty_candidate" "https://example.invalid/Dirty"
write_text "$dirty_candidate/local-notes.txt" "unrecorded local content"
write_text "$fixture/.build/SourcePackages/checkouts/Unknown/state.db" \
  "unknown repository content"
independent="$fixture/.build/SourcePackages/checkouts/Independent"
create_independent_repository "$independent"
write_text "$fixture/Packages/ApplicationFoundation/.build/app/output.o" \
  "package local build"

unsafe_output="$output_directory/unsafe-and-unknown.log"
run_clean "$fixture" "$unsafe_output"
assert_missing "$dependency"
assert_exists "$tracked_candidate/Source.swift"
assert_exists "$dirty_candidate/local-notes.txt"
assert_exists "$fixture/.build/SourcePackages/checkouts/Unknown/state.db"
assert_exists "$independent/Package.swift"
assert_exists "$fixture/Packages/ApplicationFoundation/.build/app/output.o"
assert_contains "$unsafe_output" "contains tracked project files; preserved"
assert_contains "$unsafe_output" "modified, untracked, or ignored content; preserved"
assert_contains "$unsafe_output" "no unambiguous tracked package pin; preserved"
assert_summary "$unsafe_output" 5 1 4

# Worktree administration and package-local outputs keep the full candidate.
fixture=$(new_fixture worktrees-and-package-local)
eligible="$fixture/.build/SourcePackages/checkouts/Package"
create_checkout "$fixture" "$eligible" "https://example.invalid/Package"
dependency="$fixture/.build/SourcePackages/checkouts/Dependency"
create_checkout "$fixture" "$dependency" \
  "https://example.invalid/Dependency"
dependency_worktree="$test_root/dependency-external-worktree"
git -C "$dependency" worktree add -q -b dependency-external-test \
  "$dependency_worktree"
root_worktree="$fixture/.worktrees/sibling"
git -C "$fixture" worktree add -q -b root-sibling-test "$root_worktree"
nested_worktree="$fixture/.build/xcodebuild-build.NESTED"
git -C "$fixture" worktree add -q -b nested-worktree-test "$nested_worktree"
write_text "$fixture/Packages/ApplicationFoundation/.build/local/output.o" \
  "package local build"

worktree_output="$output_directory/worktrees.log"
run_clean "$fixture" "$worktree_output"
assert_missing "$eligible"
assert_exists "$dependency/Package.swift"
assert_exists "$dependency_worktree/Package.swift"
assert_exists "$root_worktree/README.md"
assert_exists "$nested_worktree/README.md"
assert_exists "$fixture/Packages/ApplicationFoundation/.build/local/output.o"
assert_contains "$worktree_output" \
  "Git metadata administers another worktree; preserved"
assert_contains "$worktree_output" \
  ".build/xcodebuild-build.NESTED (current Make invocation"
assert_summary "$worktree_output" 3 1 2

# Invocation is anchored to the checkout. Both an outer cache symlink and a
# candidate symlink are skipped, and moving the real checkout into place then
# permits normal removal without touching the outside target.
fixture=$(new_fixture symlink-and-invocation)
outside_root="$test_root/outside symlink target"
external_candidate="$outside_root/candidate/Package"
create_checkout "$fixture" "$external_candidate" \
  "https://example.invalid/Package"
mkdir -p "$fixture/.build/SourcePackages"
ln -s "$outside_root/candidate" \
  "$fixture/.build/SourcePackages/checkouts"

outer_symlink_output="$output_directory/outer-symlink.log"
run_clean "$fixture" "$outer_symlink_output"
assert_exists "$external_candidate/Package.swift"
assert_contains "$outer_symlink_output" \
  ".build/SourcePackages/checkouts (symbolic link; preserved)"
assert_summary "$outer_symlink_output" 1 0 1

outside_invocation="$test_root/outside-invocation"
mkdir -p "$outside_invocation"
outside_output="$output_directory/outside-invocation.log"
if (cd -- "$outside_invocation" &&
  make --no-print-directory SHELL="$test_shell" \
    -f "$fixture/Makefile" clean) >"$outside_output" 2>&1; then
  fail "make -f outside the owning checkout unexpectedly succeeded"
fi
assert_contains "$outside_output" \
  "run make clean from the repository that owns this Makefile"
assert_exists "$external_candidate/Package.swift"

rm -- "$fixture/.build/SourcePackages/checkouts"
mkdir -p "$fixture/.build/SourcePackages/checkouts"
ln -s "$external_candidate" \
  "$fixture/.build/SourcePackages/checkouts/Package"
candidate_symlink_output="$output_directory/candidate-symlink.log"
run_clean "$fixture" "$candidate_symlink_output"
assert_exists "$external_candidate/Package.swift"
assert_contains "$candidate_symlink_output" \
  ".build/SourcePackages/checkouts/Package (symbolic link; preserved)"
assert_summary "$candidate_symlink_output" 1 0 1

rm -- "$fixture/.build/SourcePackages/checkouts/Package"
mv -- "$external_candidate" \
  "$fixture/.build/SourcePackages/checkouts/Package"
recovered_output="$output_directory/recovered.log"
if ! (cd -- "$outside_invocation" &&
  make --no-print-directory SHELL="$test_shell" \
    -C "$fixture" clean) >"$recovered_output" 2>&1; then
  fail "make -C from another directory failed:\n$(cat "$recovered_output")"
fi
assert_missing "$fixture/.build/SourcePackages/checkouts/Package"
assert_summary "$recovered_output" 1 1 0

# Ambiguous ownership in ordinary repositories is preserved. A separate clean
# pinned checkout proves cleanup continues after inspecting ambiguous peers.
fixture=$(new_fixture ambiguous-ownership)
wrong_revision="$fixture/.build/SourcePackages/checkouts/WrongRevision"
create_checkout "$fixture" "$wrong_revision" \
  "https://example.invalid/WrongRevision"
write_text "$wrong_revision/new-commit.txt" "new committed dependency content"
git -C "$wrong_revision" add -- new-commit.txt
git -C "$wrong_revision" commit -q -m "advance beyond pin"

modified="$fixture/.build/SourcePackages/checkouts/Modified"
create_checkout "$fixture" "$modified" "https://example.invalid/Modified"
write_text "$modified/Package.swift" "modified dependency manifest"

untracked="$fixture/.build/SourcePackages/checkouts/Untracked"
create_checkout "$fixture" "$untracked" "https://example.invalid/Untracked"
write_text "$untracked/local.txt" "local dependency content"

local_mirror="$fixture/.build/SourcePackages/checkouts/LocalMirror"
create_checkout "$fixture" "$local_mirror" \
  "https://example.invalid/LocalMirror"
git -C "$local_mirror" config remote.origin.url \
  "$fixture/.build/SourcePackages/repositories/local-mirror.git"

nested="$fixture/.build/SourcePackages/checkouts/Nested"
create_checkout "$fixture" "$nested" "https://example.invalid/Nested"
create_independent_repository "$nested/vendor/Inner"

local_pin="$fixture/.build/SourcePackages/checkouts/LocalPin"
create_checkout "$fixture" "$local_pin" "https://example.invalid/LocalPin"
local_pin_revision=$(git -C "$local_pin" rev-parse HEAD)
record_pin "$fixture" "LocalPin" "https://example.invalid/LocalPin" \
  "$local_pin_revision" "localSourceControl"

keep="$fixture/.build/SourcePackages/checkouts/Keep"
create_checkout "$fixture" "$keep" "https://example.invalid/Keep"

ambiguous_output="$output_directory/ambiguous.log"
run_clean "$fixture" "$ambiguous_output"
assert_exists "$wrong_revision/Package.swift"
assert_exists "$modified/Package.swift"
assert_exists "$untracked/local.txt"
assert_exists "$local_mirror/Package.swift"
assert_exists "$nested/vendor/Inner/Package.swift"
assert_exists "$local_pin/Package.swift"
assert_missing "$keep"
assert_contains "$ambiguous_output" \
  "HEAD does not match tracked package pin; preserved"
assert_contains "$ambiguous_output" \
  "modified, untracked, or ignored content; preserved"
assert_contains "$ambiguous_output" \
  "origin does not match tracked package pin; preserved"
assert_contains "$ambiguous_output" \
  "nested Git repository or submodule; preserved"
assert_contains "$ambiguous_output" \
  ".build/SourcePackages/checkouts/LocalPin (no unambiguous tracked package pin; preserved)"
assert_summary "$ambiguous_output" 7 1 6

# An untracked lockfile and SwiftPM workspace state do not establish ownership.
fixture=$(new_fixture workspace-state-is-not-ownership)
workspace_checkout="$fixture/.build/SourcePackages/checkouts/WorkspaceOnly"
create_independent_repository "$workspace_checkout"
workspace_revision=$(git -C "$workspace_checkout" rev-parse HEAD)
write_text \
  "$fixture/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
  "{\"pins\":[{\"identity\":\"WorkspaceOnly\",\"kind\":\"remoteSourceControl\",\"location\":\"https://example.invalid/WorkspaceOnly\",\"state\":{\"revision\":\"$workspace_revision\"}}],\"version\":2}"
write_text "$fixture/.build/SourcePackages/workspace-state.json" \
  "{\"object\":{\"dependencies\":[{\"packageRef\":{\"identity\":\"WorkspaceOnly\"}}]}}"
workspace_output="$output_directory/workspace-state.log"
run_clean "$fixture" "$workspace_output"
assert_exists "$workspace_checkout/.git"
assert_exists "$workspace_checkout/Package.swift"
assert_exists \
  "$fixture/.build/SourcePackages/workspace-state.json"
assert_contains "$workspace_output" \
  "no unambiguous tracked package pin; preserved"
assert_summary "$workspace_output" 1 0 1

# Ordinary inspection and deletion failures are reported, preserved, and make
# the command fail without adding retry, rollback, or race machinery.
fixture=$(new_fixture inspection-failure)
inspection_candidate="$fixture/.build/SourcePackages/checkouts/Package"
create_checkout "$fixture" "$inspection_candidate" \
  "https://example.invalid/Package"
failure_bin="$test_root/failure-bin"
mkdir -p "$failure_bin"
write_text "$failure_bin/du" '#!/bin/bash
printf "simulated du failure\n" >&2
exit 1'
chmod 755 "$failure_bin/du"
inspection_output="$output_directory/inspection-failure.log"
if (cd -- "$fixture" && PATH="$failure_bin:$PATH" \
  make --no-print-directory SHELL="$test_shell" clean) >\
  "$inspection_output" 2>&1; then
  fail "make clean unexpectedly ignored a size inspection failure"
fi
assert_exists "$inspection_candidate/Package.swift"
assert_contains "$inspection_output" "size inspection failed; preserved"
assert_summary "$inspection_output" 1 0 1

fixture=$(new_fixture deletion-failure)
deletion_candidate="$fixture/.build/SourcePackages/checkouts/Package"
create_checkout "$fixture" "$deletion_candidate" \
  "https://example.invalid/Package"
rm_failure_bin="$test_root/rm-failure-bin"
mkdir -p "$rm_failure_bin"
write_text "$rm_failure_bin/rm" '#!/bin/bash
printf "simulated rm failure\n" >&2
exit 1'
chmod 755 "$rm_failure_bin/rm"
deletion_output="$output_directory/deletion-failure.log"
if (cd -- "$fixture" && PATH="$rm_failure_bin:$PATH" \
  make --no-print-directory SHELL="$test_shell" clean) >\
  "$deletion_output" 2>&1; then
  fail "make clean unexpectedly ignored a deletion failure"
fi
assert_exists "$deletion_candidate/Package.swift"
assert_contains "$deletion_output" "failed to remove"
assert_summary "$deletion_output" 1 0 0

printf 'clean fixture tests: all scenarios passed with %s\n' "$test_shell"
