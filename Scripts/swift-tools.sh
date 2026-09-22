#!/usr/bin/env bash
set -euo pipefail

readonly script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly repository_root=$(cd -- "$script_directory/.." && pwd -P)
readonly lock_file="$script_directory/swift-tools.lock"
readonly default_repository_url="https://github.com/danielbyon/swift-tooling"
cleanup_root=''

die() {
    printf 'swift-tools: %s\n' "$1" >&2
    exit 1
}

cleanup_exit() {
    if [[ -n "$cleanup_root" ]]; then
        rm -rf "$cleanup_root"
        cleanup_root=''
    fi
}

trap cleanup_exit EXIT

lock_value() {
    local key=$1
    awk -F= -v expected_key="$key" '$1 == expected_key { print substr($0, index($0, "=") + 1); exit }' "$lock_file"
}

manifest_value() {
    local key=$1
    local file=$2
    awk -F= -v expected_key="$key" '$1 == expected_key { print substr($0, index($0, "=") + 1); exit }' "$file"
}

[[ -f "$lock_file" ]] || die "lock file is missing: $lock_file"

release_version=$(lock_value SWIFT_TOOLING_RELEASE_VERSION)
release_sha256=$(lock_value SWIFT_TOOLING_RELEASE_SHA256)
release_asset=$(lock_value SWIFT_TOOLING_RELEASE_ASSET)
release_repository_url=$(lock_value SWIFT_TOOLING_REPOSITORY_URL)
release_repository_url=${release_repository_url:-$default_repository_url}
release_asset=${release_asset:-swift-tooling.tar.gz}

[[ -n "$release_version" ]] || die 'lock file must define SWIFT_TOOLING_RELEASE_VERSION'
[[ -n "$release_sha256" ]] || die 'lock file must define SWIFT_TOOLING_RELEASE_SHA256'
[[ "$release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "release version must look like vMAJOR.MINOR.PATCH: $release_version"

release_root="${SWIFT_TOOLING_RELEASE_ROOT:-$repository_root/.tools/swift-tooling/$release_version}"

cached_release_files=(
    bin/swift-tooling
    Scripts/toolchain-lock.sh
    toolchain.lock
    Mintfile
    config/swiftformat.base
    config/swiftlint.base.yml
)

cached_release_matches_archive() {
    local archive=$1
    local relative expected actual

    for relative in "${cached_release_files[@]}"; do
        [[ -f "$release_root/$relative" && ! -L "$release_root/$relative" ]] || return 1
        if ! expected=$(tar -xOf "$archive" "./$relative" | shasum -a 256 | awk '{print $1}'); then
            return 1
        fi
        actual=$(shasum -a 256 "$release_root/$relative" | awk '{print $1}')
        [[ "$actual" = "$expected" ]] || return 1
    done
}

run_setup_from_archive() {
    local archive=$1
    local version=$2
    local sha256=$3
    local asset=$4
    local setup_script="$cleanup_root/setup-swift-tools.sh"

    [[ -f "$archive" ]] || die "release archive does not exist: $archive"
    [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$sha256" ]] \
        || die 'shared release checksum mismatch'

    # The archive checksum is verified before reading the canonical installer
    # from it. The installer then performs the full archive validation and
    # transactional consumer update.
    tar -xOf "$archive" ./Scripts/setup-swift-tools.sh > "$setup_script"
    chmod 0755 "$setup_script"
    bash "$setup_script" \
        --repository-root "$repository_root" \
        --repository-url "$release_repository_url" \
        --release-archive "$archive" \
        --release-version "$version" \
        --release-sha256 "$sha256" \
        --release-asset "$asset"
}

ensure_release() {
    local archive=${SWIFT_TOOLING_RELEASE_ARCHIVE:-}
    local cached_archive="$release_root/.swift-tooling-release.tar.gz"
    local temporary_archive
    local archive_url

    if [[ -z "$archive" \
        && -x "$release_root/bin/swift-tooling" \
        && -f "$cached_archive" \
        && "$(shasum -a 256 "$cached_archive" | awk '{print $1}')" = "$release_sha256" ]]; then
        if cached_release_matches_archive "$cached_archive"; then
            return
        fi
    fi

    cleanup_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-consumer.XXXXXX")
    if [[ -z "$archive" && -f "$cached_archive" \
        && "$(shasum -a 256 "$cached_archive" | awk '{print $1}')" = "$release_sha256" ]]; then
        archive="$cached_archive"
    fi

    if [[ -z "$archive" ]]; then
        temporary_archive="$cleanup_root/release.tar.gz"
        archive_url="$release_repository_url/releases/download/$release_version/$release_asset"
        curl --fail --location --silent --show-error "$archive_url" --output "$temporary_archive"
        archive="$temporary_archive"
    fi

    run_setup_from_archive "$archive" "$release_version" "$release_sha256" "$release_asset"
    cleanup_exit
}

update_release() {
    local temporary_root
    local manifest_file
    local archive_file
    local latest_version
    local latest_sha256
    local latest_asset

    temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-update.XXXXXX")
    manifest_file="$temporary_root/release-manifest.env"
    archive_file="$temporary_root/release.tar.gz"
    cleanup_root="$temporary_root"

    curl --fail --location --silent --show-error \
        "$release_repository_url/releases/latest/download/release-manifest.env" \
        --output "$manifest_file"
    latest_version=$(manifest_value RELEASE_VERSION "$manifest_file")
    latest_sha256=$(manifest_value RELEASE_SHA256 "$manifest_file")
    latest_asset=$(manifest_value RELEASE_ASSET "$manifest_file")
    latest_asset=${latest_asset:-swift-tooling.tar.gz}
    [[ -n "$latest_version" ]] || die 'release manifest did not provide RELEASE_VERSION'
    [[ -n "$latest_sha256" ]] || die 'release manifest did not provide RELEASE_SHA256'
    [[ "$latest_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "release version must look like vMAJOR.MINOR.PATCH: $latest_version"

    curl --fail --location --silent --show-error \
        "$release_repository_url/releases/download/$latest_version/$latest_asset" \
        --output "$archive_file"
    run_setup_from_archive "$archive_file" "$latest_version" "$latest_sha256" "$latest_asset"
    cleanup_exit
}

release_supports_configured() {
    "$release_root/bin/swift-tooling" --capabilities 2>/dev/null \
        | grep -Fxq 'configured-exec=1'
}

write_legacy_local_config() {
    local target=$1
    {
        printf 'SWIFT_TOOLS_ROOT=%q\n' "$SWIFT_TOOLS_ROOT"
        printf 'SWIFT_TOOLS_SOURCE_PATHS=('
        if [[ "${#SWIFT_TOOLS_SOURCE_PATHS[@]}" -gt 0 ]]; then
            printf '%q ' "${SWIFT_TOOLS_SOURCE_PATHS[@]}"
        fi
        printf ')\n'
        printf 'SWIFT_TOOLS_SWIFTFORMAT_CONFIG=%q\n' "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG"
        printf 'SWIFT_TOOLS_SWIFTLINT_CONFIG=%q\n' "$SWIFT_TOOLS_SWIFTLINT_CONFIG"
        printf 'SWIFT_TOOLS_COMMAND_PREFIX=('
        if [[ "${#SWIFT_TOOLS_COMMAND_PREFIX[@]}" -gt 0 ]]; then
            printf '%q ' "${SWIFT_TOOLS_COMMAND_PREFIX[@]}"
        fi
        printf ')\n'
    } > "$target"
}

run_legacy_configured() {
    [[ "$#" -ge 1 ]] || die 'configured requires swiftformat or swiftlint'
    local tool=$1
    shift
    local temporary_root
    local generated_local_config
    local status=0
    temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-tooling-config.XXXXXX")
    cleanup_root="$temporary_root"
    generated_local_config="$temporary_root/swift-tools-local.sh"

    # Resolve the consumer configuration once. Legacy releases source the
    # generated declarative snapshot, so they retain source paths, overlays,
    # and command prefixes without evaluating consumer code a second time.
    SWIFT_TOOLS_ROOT="$repository_root"
    SWIFT_TOOLS_SOURCE_PATHS=()
    SWIFT_TOOLS_SWIFTFORMAT_CONFIG=''
    SWIFT_TOOLS_SWIFTLINT_CONFIG=''
    SWIFT_TOOLS_COMMAND_PREFIX=()
    if [[ -f "$repository_root/Scripts/swift-tools-local.sh" ]]; then
        # shellcheck source=/dev/null
        source "$repository_root/Scripts/swift-tools-local.sh"
    fi
    if [[ -n "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" \
        && "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" != /* ]]; then
        SWIFT_TOOLS_SWIFTFORMAT_CONFIG="$repository_root/$SWIFT_TOOLS_SWIFTFORMAT_CONFIG"
    fi
    if [[ -n "$SWIFT_TOOLS_SWIFTLINT_CONFIG" \
        && "$SWIFT_TOOLS_SWIFTLINT_CONFIG" != /* ]]; then
        SWIFT_TOOLS_SWIFTLINT_CONFIG="$repository_root/$SWIFT_TOOLS_SWIFTLINT_CONFIG"
    fi
    if [[ -n "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" ]]; then
        [[ -f "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" ]] \
            || die "SwiftFormat config is missing: $SWIFT_TOOLS_SWIFTFORMAT_CONFIG"
    fi
    if [[ -n "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]]; then
        [[ -f "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]] \
            || die "SwiftLint config is missing: $SWIFT_TOOLS_SWIFTLINT_CONFIG"
    fi
    write_legacy_local_config "$generated_local_config"

    case "$tool" in
        swiftlint)
            [[ "$#" -ge 1 ]] || die 'configured SwiftLint execution requires a subcommand'
            local subcommand=$1
            shift
            local args=(
                --root "$repository_root"
                --release-root "$release_root"
                --local-config "$generated_local_config"
                exec swiftlint "$subcommand"
                --config "$release_root/config/swiftlint.base.yml"
            )
            if [[ -n "$SWIFT_TOOLS_SWIFTLINT_CONFIG" ]]; then
                args+=(--config "$SWIFT_TOOLS_SWIFTLINT_CONFIG")
            fi
            args+=("$@")
            "$release_root/bin/swift-tooling" "${args[@]}" || status=$?
            cleanup_exit
            return "$status"
            ;;
        swiftformat)
            local effective_config
            effective_config="$temporary_root/swiftformat.effective"
            {
                cat "$release_root/config/swiftformat.base"
                if [[ -n "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG" ]]; then
                    cat "$SWIFT_TOOLS_SWIFTFORMAT_CONFIG"
                fi
            } > "$effective_config"
            "$release_root/bin/swift-tooling" \
                --root "$repository_root" \
                --release-root "$release_root" \
                --local-config "$generated_local_config" \
                exec swiftformat --config "$effective_config" "$@" || status=$?
            cleanup_exit
            return "$status"
            ;;
        *)
            die "unsupported configured tool: $tool"
            ;;
    esac
}

case "${1:-}" in
    update)
        shift
        [[ "$#" -eq 0 ]] || die 'update does not accept positional arguments'
        update_release
        ;;
    bootstrap|format|lint|exec)
        command=$1
        shift
        ensure_release
        exec "$release_root/bin/swift-tooling" \
            --root "$repository_root" \
            --release-root "$release_root" \
            --local-config "$repository_root/Scripts/swift-tools-local.sh" \
            "$command" "$@"
        ;;
    configured)
        shift
        ensure_release
        if release_supports_configured; then
            exec "$release_root/bin/swift-tooling" \
                --root "$repository_root" \
                --release-root "$release_root" \
                --local-config "$repository_root/Scripts/swift-tools-local.sh" \
                configured "$@"
        fi
        run_legacy_configured "$@"
        ;;
    help|--help|-h|'')
        cat <<'USAGE'
Usage: Scripts/swift-tools.sh <bootstrap|format|lint|configured|exec|update>

The release version and checksum are recorded in Scripts/swift-tools.lock.
Project-specific paths and wrapper settings live in Scripts/swift-tools-local.sh.
SwiftLint and SwiftFormat config paths are optional overlays; the shared release
baseline is used when a repository does not define one.
USAGE
        ;;
    *)
        die "unknown command: $1"
        ;;
esac
