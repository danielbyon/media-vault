#!/bin/bash
#
# Spike 2 runtime experiment orchestration.
#
# Builds the macOS host-process fixture server, starts it on the shared fixture
# port, and runs the disposable BrowserURLSessionSpike scheme on the available
# iOS 27 iPhone and iPad simulators. The fixture server must be a separate host
# process: a server inside the iOS app cannot prove that transfers survive app
# suspension or termination.
#
# All artifacts stay in the repository build directory:
#   .build/spike-2-evidence/iphone-17.json        iPhone-only fixture evidence
#   .build/spike-2-evidence/ipad-pro-11-m5.json   iPad-only fixture evidence
#   .build/spike-2-evidence/fixture-server.json   latest server snapshot
#   .build/spike-browser-urlsession/bin/          fixture server binary
#
set -euo pipefail

repo_root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

xcode_wrapper="./Scripts/with-xcode-27-rc.sh"
iphone_destination="${IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=27.0}"
ipad_destination="${IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0}"
source_packages="${SOURCE_PACKAGES_DIRECTORY:-$repo_root/.build/SourcePackages}"
fixture_port=18742
evidence_dir="$repo_root/.build/spike-2-evidence"
bin_dir="$repo_root/.build/spike-browser-urlsession/bin"
server_binary="$bin_dir/spike-fixture-server"
server_pid=""
server_started=0

mkdir -p "$evidence_dir" "$bin_dir" "$source_packages"
derived_data=$(mktemp -d "$repo_root/.build/xcodebuild-spike-browser-urlsession.XXXXXX")

cleanup() {
  if [ "$server_started" -eq 1 ] && kill -0 "$server_pid" 2>/dev/null; then
    # SIGTERM makes the server persist its evidence file before exiting.
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      echo "fixture server did not stop after SIGTERM; killing it" >&2
      kill -KILL "$server_pid" 2>/dev/null || true
    fi
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$derived_data"
}
trap cleanup EXIT

if lsof -nP -iTCP:"$fixture_port" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "fixture port $fixture_port is already in use; stop the other fixture server first" >&2
  exit 1
fi

echo "==> building host-process fixture server"
"$xcode_wrapper" xcrun swiftc -swift-version 6 -O -g \
  -o "$server_binary" \
  Prototypes/BrowserURLSessionSpike/Shared/SpikeFixtureContract.swift \
  Prototypes/BrowserURLSessionSpike/FixtureServer/*.swift

run_id=$(date -u +%Y%m%dT%H%M%SZ)
echo "==> starting fixture server (run $run_id)"
SPIKE_FIXTURE_DIAGNOSTICS=1 "$server_binary" \
  --port "$fixture_port" \
  --run-id "$run_id" \
  --evidence "$evidence_dir/fixture-server.json" &
server_pid=$!
server_started=1

ready=0
for _ in $(seq 1 100); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$fixture_port/health"; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  echo "fixture server did not become ready on port $fixture_port" >&2
  exit 1
fi
echo "==> fixture server ready on port $fixture_port"

run_tests() {
  local destination=$1
  local label=$2
  local result_name
  if [ "$label" = "iPhone" ]; then
    result_name="iphone-17"
  else
    result_name="ipad-pro-11-m5"
  fi
  local result_bundle="$evidence_dir/$run_id-$result_name.xcresult"
  echo "==> xcodebuild test ($label) $destination"
  "$xcode_wrapper" xcodebuild -skipMacroValidation \
    -workspace App.xcworkspace \
    -scheme BrowserURLSessionSpike \
    -configuration Debug \
    -destination "$destination" \
    -clonedSourcePackagesDirPath "$source_packages" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    test
}

snapshot_evidence() {
  local filename=$1
  local device_label=$2
  curl -fsS -o /dev/null "http://127.0.0.1:$fixture_port/__spike/export"
  python3 - "$evidence_dir/fixture-server.json" "$evidence_dir/$filename" "$device_label" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
document = json.loads(source.read_text())
document["deviceLabel"] = sys.argv[3]
target.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
}

run_tests "$iphone_destination" iPhone
snapshot_evidence "iphone-17.json" "$iphone_destination"
run_tests "$ipad_destination" iPad
snapshot_evidence "ipad-pro-11-m5.json" "$ipad_destination"

echo "==> exporting fixture evidence"
curl -fsS -o /dev/null "http://127.0.0.1:$fixture_port/__spike/export" || true
echo "==> fixture evidence: $evidence_dir/iphone-17.json"
echo "==> fixture evidence: $evidence_dir/ipad-pro-11-m5.json"
echo "==> latest fixture evidence: $evidence_dir/fixture-server.json"
echo "==> iPhone test result: $evidence_dir/$run_id-iphone-17.xcresult"
echo "==> iPad test result: $evidence_dir/$run_id-ipad-pro-11-m5.xcresult"
