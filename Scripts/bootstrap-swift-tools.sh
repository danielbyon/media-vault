#!/bin/bash
set -euo pipefail

mint_version="0.18.0"
mint_archive_sha256="ce44b0fc4ef3bc854ea43b2d2d3f96502d52231c0e0849ec212815121955f5ef"
mint_archive_url="https://github.com/yonaskolb/Mint/releases/download/${mint_version}/mint.zip"

script_directory=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_directory/.." && pwd)
tool_directory="$repository_root/.build/tools/mint/$mint_version"
mint_archive="$tool_directory/mint.zip"
mint_binary="$tool_directory/mint"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_archive() {
  [ -f "$mint_archive" ] && [ "$(sha256_file "$mint_archive")" = "$mint_archive_sha256" ]
}

mkdir -p "$tool_directory"

if ! verify_archive; then
  temporary_archive="$tool_directory/mint.zip.download"
  rm -f "$temporary_archive"
  curl --fail --location --silent --show-error --retry 3 \
    "$mint_archive_url" \
    --output "$temporary_archive"

  actual_archive_sha256=$(sha256_file "$temporary_archive")
  if [ "$actual_archive_sha256" != "$mint_archive_sha256" ]; then
    rm -f "$temporary_archive"
    printf '%s\n' "Mint archive checksum mismatch." >&2
    printf '%s\n' "Expected: $mint_archive_sha256" >&2
    printf '%s\n' "Actual:   $actual_archive_sha256" >&2
    exit 1
  fi

  mv "$temporary_archive" "$mint_archive"
fi

extraction_directory=$(mktemp -d "$tool_directory/extract.XXXXXX")
trap 'rm -rf "$extraction_directory"' EXIT

# The verified archive is the trust anchor. Re-extract it on every invocation
# so a cache hit is checked against the pinned release instead of trusting a
# previously extracted binary.
ditto -x -k "$mint_archive" "$extraction_directory"
extracted_mint=$(find "$extraction_directory" -type f -name mint -print -quit)
if [ -z "$extracted_mint" ]; then
  printf '%s\n' "Mint executable was not found in the verified release archive." >&2
  exit 1
fi

expected_mint_binary_sha256=$(sha256_file "$extracted_mint")
if [ ! -x "$mint_binary" ] || [ "$(sha256_file "$mint_binary")" != "$expected_mint_binary_sha256" ]; then
  install -m 0755 "$extracted_mint" "$mint_binary"
fi

export DEVELOPER_DIR="$("$script_directory/select-xcode-27-rc.sh")"
export MINT_PATH="$repository_root/.build/mint"
export MINT_LINK_PATH="$MINT_PATH/bin"
mkdir -p "$MINT_PATH" "$MINT_LINK_PATH"

cd "$repository_root"
"$mint_binary" bootstrap

printf '%s\n' "Swift tooling bootstrapped with Mint $mint_version."
