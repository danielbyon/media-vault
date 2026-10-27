#!/bin/bash
set -euo pipefail
shopt -s nullglob dotglob

# Remove only SwiftPM dependency checkouts whose project ownership can be
# established from a tracked Package.resolved pin. The command is intended for
# an idle checkout: a trusted operator runs it while no build, test, or cleanup
# process is modifying the repository.

die() {
  printf 'clean: error: %s\n' "$1" >&2
  exit 1
}

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_directory
script_checkout=$(cd -- "$script_directory/.." && pwd -P)
readonly script_checkout

# Git variables inherited from a caller can redirect ownership and cleanliness
# checks away from the checkout containing this Makefile.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
export GIT_LITERAL_PATHSPECS=1
export GIT_OPTIONAL_LOCKS=0

current_directory=$(pwd -P)
if ! git_root=$(git -C "$current_directory" rev-parse --show-toplevel 2>/dev/null); then
  die "run make clean from the repository that owns this Makefile"
fi
repository_root=$(cd -- "$git_root" && pwd -P)
readonly repository_root
if [[ "$current_directory" != "$repository_root" ||
      "$repository_root" != "$script_checkout" ]]; then
  die "run make clean from the repository that owns this Makefile"
fi

readonly package_resolved_paths=(
  'App.xcworkspace/xcshareddata/swiftpm/Package.resolved'
  'App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
  'Packages/ApplicationFoundation/Package.resolved'
)

pin_identities=()
pin_locations=()
pin_revisions=()
candidate_count=0
removed_count=0
skipped_count=0
reclaimed_kib=0
cleanup_failed=0

relative_path() {
  local path=$1
  if [[ "$path" == "$repository_root" ]]; then
    printf '.\n'
  elif [[ "$path" == "$repository_root"/* ]]; then
    printf '%s\n' "${path#"$repository_root"/}"
  else
    die "refusing to report a path outside the repository: $path"
  fi
}

# Return success when any component of a checkout-relative path is a symbolic
# link. This prevents a normal cleanup from following a redirected cache or
# manifest into another directory.
path_has_symlink() {
  local relative=$1
  local current=$repository_root
  local component remainder=$relative

  while [[ -n "$remainder" ]]; do
    component=${remainder%%/*}
    if [[ -n "$component" ]]; then
      current="$current/$component"
      [[ -L "$current" ]] && return 0
    fi
    if [[ "$remainder" == */* ]]; then
      remainder=${remainder#*/}
    else
      remainder=''
    fi
  done
  return 1
}

skip_candidate() {
  local candidate=$1
  local reason=$2
  candidate_count=$((candidate_count + 1))
  skipped_count=$((skipped_count + 1))
  printf 'clean: skipped %s (%s)\n' "$(relative_path "$candidate")" "$reason"
}

skip_failed_candidate() {
  local candidate=$1
  local reason=$2
  cleanup_failed=1
  skip_candidate "$candidate" "$reason"
}

normalize_remote_url() {
  local url=$1
  while [[ "$url" == */ ]]; do
    url=${url%/}
  done
  [[ "$url" == *.git ]] && url=${url%.git}
  printf '%s' "$url"
}

load_package_pins() {
  local manifest relative

  for manifest in "${package_resolved_paths[@]}"; do
    relative=$manifest
    [[ -f "$repository_root/$relative" ]] || continue

    if path_has_symlink "$relative"; then
      printf 'clean: skipped manifest %s (symbolic-link path; preserved)\n' "$relative"
      continue
    fi
    if ! tracked=$(git -C "$repository_root" ls-files --error-unmatch -- "$relative" 2>/dev/null); then
      continue
    fi
    [[ -n "$tracked" ]] || continue

    if ! pins=$(python3 - "$repository_root/$relative" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)

pins = document.get("pins")
if pins is None:
    pins = document.get("object", {}).get("pins", [])

for pin in pins:
    kind = pin.get("kind") or "remoteSourceControl"
    identity = pin.get("identity") or pin.get("package") or ""
    location = pin.get("location") or pin.get("repositoryURL") or ""
    revision = pin.get("state", {}).get("revision") or ""
    if kind != "remoteSourceControl" or not identity or not location or not revision:
        continue
    if any("\t" in value or "\n" in value for value in (identity, location, revision)):
        continue
    print("\t".join((identity, location, revision)))
PY
    ); then
      printf 'clean: skipped manifest %s (cannot read package pins; preserved)\n' "$relative"
      cleanup_failed=1
      continue
    fi

    while IFS=$'\t' read -r identity location revision; do
      [[ -n "$identity" ]] || continue
      pin_identities+=("$identity")
      pin_locations+=("$location")
      pin_revisions+=("$revision")
    done <<< "$pins"
  done
}

# Find a single tracked pin matching the checkout directory name. SwiftPM uses
# the package identity as its directory name in most cases, while the basename
# of the remote repository is also a supported spelling.
find_matching_pin() {
  local candidate_name=$1
  local candidate_lower identity_lower location_base location_lower
  local index matched=0 conflict=0

  matched_location=''
  matched_revision=''
  candidate_lower=$(printf '%s' "$candidate_name" | tr '[:upper:]' '[:lower:]')

  for ((index = 0; index < ${#pin_identities[@]}; index++)); do
    identity_lower=$(printf '%s' "${pin_identities[$index]}" | tr '[:upper:]' '[:lower:]')
    location_base=${pin_locations[$index]##*/}
    location_base=${location_base%.git}
    location_lower=$(printf '%s' "$location_base" | tr '[:upper:]' '[:lower:]')
    if [[ "$candidate_lower" != "$identity_lower" &&
          "$candidate_lower" != "$location_lower" ]]; then
      continue
    fi

    if [[ "$matched" -eq 0 ]]; then
      matched_location=${pin_locations[$index]}
      matched_revision=${pin_revisions[$index]}
    elif [[ "$matched_location" != "${pin_locations[$index]}" ||
            "$matched_revision" != "${pin_revisions[$index]}" ]]; then
      conflict=1
    fi
    matched=$((matched + 1))
  done

  [[ "$matched" -gt 0 && "$conflict" -eq 0 ]]
}

inspect_checkout() {
  local candidate=$1
  local relative candidate_name candidate_top candidate_top_physical
  local tracked nested_git status head origin size_output size_kib

  relative=${candidate#"$repository_root"/}
  candidate_name=${candidate##*/}

  if [[ -L "$candidate" ]]; then
    skip_candidate "$candidate" "symbolic link; preserved"
    return
  fi
  if [[ ! -d "$candidate" ]]; then
    skip_candidate "$candidate" "not a directory; preserved"
    return
  fi
  if path_has_symlink "$relative"; then
    skip_candidate "$candidate" "symbolic link in checkout path; preserved"
    return
  fi

  if ! tracked=$(git -C "$repository_root" ls-files -- "$relative" 2>/dev/null); then
    skip_failed_candidate "$candidate" "tracked-file inspection failed; preserved"
    return
  fi
  if [[ -n "$tracked" ]]; then
    skip_candidate "$candidate" "contains tracked project files; preserved"
    return
  fi

  if ! find_matching_pin "$candidate_name"; then
    skip_candidate "$candidate" "no unambiguous tracked package pin; preserved"
    return
  fi

  if [[ ! -d "$candidate/.git" || -L "$candidate/.git" ]]; then
    skip_candidate "$candidate" "Git metadata is not a checkout-local directory; preserved"
    return
  fi
  if [[ -e "$candidate/.git/worktrees" || -L "$candidate/.git/worktrees" ]]; then
    skip_candidate "$candidate" "Git metadata administers another worktree; preserved"
    return
  fi

  # A submodule or independent repository is a complex ownership case. Keep the
  # complete package checkout rather than analysing nested Git administration.
  if ! nested_git=$(find "$candidate" \( -path "$candidate/.git" -prune \) \
      -o -name .git -print 2>/dev/null); then
    skip_failed_candidate "$candidate" "nested Git inspection failed; preserved"
    return
  fi
  if [[ -n "$nested_git" ]]; then
    skip_candidate "$candidate" "nested Git repository or submodule; preserved"
    return
  fi

  if ! candidate_top=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
    skip_candidate "$candidate" "not a readable Git checkout; preserved"
    return
  fi
  if ! candidate_top_physical=$(cd -- "$candidate_top" && pwd -P); then
    skip_failed_candidate "$candidate" "Git checkout root inspection failed; preserved"
    return
  fi
  if [[ "$candidate_top_physical" != "$candidate" ]]; then
    skip_candidate "$candidate" "Git checkout root differs from package directory; preserved"
    return
  fi

  if ! status=$(git -C "$candidate" status --porcelain=v1 --ignored \
      --untracked-files=all 2>/dev/null); then
    skip_failed_candidate "$candidate" "Git cleanliness inspection failed; preserved"
    return
  fi
  if [[ -n "$status" ]]; then
    skip_candidate "$candidate" "modified, untracked, or ignored content; preserved"
    return
  fi

  if ! head=$(git -C "$candidate" rev-parse HEAD 2>/dev/null); then
    skip_failed_candidate "$candidate" "Git revision inspection failed; preserved"
    return
  fi
  if [[ "$head" != "$matched_revision" ]]; then
    skip_candidate "$candidate" "HEAD does not match tracked package pin; preserved"
    return
  fi

  origin=$(git -C "$candidate" config --get remote.origin.url 2>/dev/null || true)
  if [[ -z "$origin" ]]; then
    skip_candidate "$candidate" "missing origin remote; preserved"
    return
  fi
  if [[ "$(normalize_remote_url "$origin")" != \
        "$(normalize_remote_url "$matched_location")" ]]; then
    skip_candidate "$candidate" "origin does not match tracked package pin; preserved"
    return
  fi

  if ! size_output=$(du -sk "$candidate" 2>/dev/null); then
    skip_failed_candidate "$candidate" "size inspection failed; preserved"
    return
  fi
  size_kib=${size_output%%[[:space:]]*}
  if [[ ! "$size_kib" =~ ^[0-9]+$ ]]; then
    skip_failed_candidate "$candidate" "size inspection returned invalid data; preserved"
    return
  fi

  candidate_count=$((candidate_count + 1))
  if rm -rf -- "$candidate"; then
    removed_count=$((removed_count + 1))
    reclaimed_kib=$((reclaimed_kib + size_kib))
    printf 'clean: removed %s (%s KiB)\n' "$relative" "$size_kib"
  else
    cleanup_failed=1
    printf 'clean: error: failed to remove %s; it may be partially removed\n' "$relative" >&2
  fi
}

load_package_pins

if path_has_symlink '.build'; then
  skip_candidate "$repository_root/.build" "symbolic link; preserved"
elif [[ -e "$repository_root/.build" && ! -d "$repository_root/.build" ]]; then
  skip_candidate "$repository_root/.build" "not a directory; preserved"
elif [[ -d "$repository_root/.build" ]]; then
  # Build and test recipes remove the temporary directory they create. A later
  # invocation cannot establish that a similarly named stale directory belongs
  # to this project.
  for stale in "$repository_root/.build"/xcodebuild-build.* \
      "$repository_root/.build"/xcodebuild-test.* \
      "$repository_root/.build/swiftlint"; do
    if [[ -e "$stale" || -L "$stale" ]]; then
      skip_candidate "$stale" "current Make invocation does not own this path; preserved"
    fi
  done

  source_packages="$repository_root/.build/SourcePackages"
  checkouts="$source_packages/checkouts"
  if path_has_symlink '.build/SourcePackages'; then
    skip_candidate "$source_packages" "symbolic link; preserved"
  elif [[ -e "$source_packages" && ! -d "$source_packages" ]]; then
    skip_candidate "$source_packages" "not a directory; preserved"
  elif path_has_symlink '.build/SourcePackages/checkouts'; then
    skip_candidate "$checkouts" "symbolic link; preserved"
  elif [[ -e "$checkouts" && ! -d "$checkouts" ]]; then
    skip_candidate "$checkouts" "not a directory; preserved"
  elif [[ -d "$checkouts" ]]; then
    for candidate in "$checkouts"/*; do
      inspect_checkout "$candidate"
    done
  fi
fi

printf 'clean: inspected %s candidate(s), removed %s, skipped %s, reclaimed %s KiB\n' \
  "$candidate_count" "$removed_count" "$skipped_count" "$reclaimed_kib"

if [[ "$cleanup_failed" -ne 0 ]]; then
  exit 1
fi
