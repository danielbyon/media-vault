#!/usr/bin/env bash
# Run the disposable inline-media experiment without touching production targets.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

run_root=".build/browser-inline-media-spike5/run-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$run_root"

swift_files=(
  Prototypes/BrowserInlineMediaSpike/Package.swift
  Prototypes/BrowserInlineMediaSpike/Sources/BridgeMessageDecoder.swift
  Prototypes/BrowserInlineMediaSpike/Tests/BridgePayloadTests.swift
  BrowserInlineMediaSpikeHost/BrowserInlineMediaSpikeApp.swift
  BrowserInlineMediaSpikeUITests/BrowserInlineMediaSpikeUITests.swift
  Prototypes/BrowserInlineMediaSpike/evidence/native-api-probe.swift
)

bash Scripts/swift-tools.sh configured swiftformat --lint "${swift_files[@]}" > "$run_root/swiftformat.log" 2>&1
bash Scripts/swift-tools.sh configured swiftlint lint --strict "${swift_files[@]}" > "$run_root/swiftlint.log" 2>&1
swift test --package-path Prototypes/BrowserInlineMediaSpike --enable-code-coverage > "$run_root/unit-tests.log" 2>&1
(cd Prototypes/BrowserInlineMediaSpike && python3 -m unittest -v test_fixture_server.py test_summarize_evidence.py) > "$run_root/fixture-tests.log" 2>&1
if xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios27.0-simulator \
  Prototypes/BrowserInlineMediaSpike/evidence/native-api-probe.swift \
  > "$run_root/native-api-probe.log" 2>&1; then
  echo 'Unexpectedly compiled: native SwiftUI context-menu API is available on iOS' >&2
  exit 1
fi
rg -q "webViewContextMenu\(menu:\).*unavailable in iOS" "$run_root/native-api-probe.log"

export SPIKE_RECORDER_TOKEN
SPIKE_RECORDER_TOKEN="$(uuidgen)"
python3 Prototypes/BrowserInlineMediaSpike/fixture_server.py --port 18755 > "$run_root/fixture-server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT

for _ in {1..50}; do
  if curl -fsS http://127.0.0.1:18755/__spike/health > /dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -fsS http://127.0.0.1:18755/__spike/health > "$run_root/fixture-health.json"

find_device() {
  xcrun simctl list devices available -j | python3 -c '
import json,sys
wanted=sys.argv[1]
devices=json.load(sys.stdin)["devices"]
matches=[d["udid"] for key,values in devices.items() if "iOS-27" in key for d in values if d["name"]==wanted]
if len(matches)!=1: raise SystemExit(f"Expected one iOS 27 simulator named {wanted}; found {len(matches)}")
print(matches[0])
' "$1"
}

iphone_id="$(find_device 'iPhone 17')"
ipad_id="$(find_device 'iPad Pro 11-inch (M5)')"
bash Scripts/with-xcode-27-rc.sh xcodebuild \
  -workspace App.xcworkspace -scheme BrowserInlineMediaSpike -configuration Debug \
  -destination "platform=iOS Simulator,id=$iphone_id" \
  -derivedDataPath .build/browser-inline-media-spike5/DerivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO build-for-testing \
  > "$run_root/build-for-testing.log" 2>&1

xctestrun_path="$(python3 - <<'PY'
from pathlib import Path
paths=[p for p in Path('.build/browser-inline-media-spike5/DerivedData/Build/Products').glob('BrowserInlineMediaSpike_iphonesimulator*.xctestrun') if p.stem.endswith('-arm64')]
if len(paths)!=1: raise SystemExit(f'Expected one Spike 5 xctestrun; found {len(paths)}')
print(paths[0])
PY
)"
token_xctestrun="${xctestrun_path%.xctestrun}-recorder.xctestrun"
python3 - "$xctestrun_path" "$token_xctestrun" "$SPIKE_RECORDER_TOKEN" <<'PY'
import plistlib,sys
from pathlib import Path
source = Path(sys.argv[1])
target = Path(sys.argv[2])
token = sys.argv[3]
with source.open('rb') as stream: data=plistlib.load(stream)
entry=data['BrowserInlineMediaSpikeUITests']
for key in ('EnvironmentVariables','TestingEnvironmentVariables','UITargetAppEnvironmentVariables'):
    entry.setdefault(key,{})['SPIKE_RECORDER_TOKEN']=token
with target.open('wb') as stream: plistlib.dump(data,stream)
PY

test_filters=()
if [[ -n "${SPIKE_ONLY_TESTS:-}" ]]; then
  IFS=, read -r -a named_tests <<< "$SPIKE_ONLY_TESTS"
  for named_test in "${named_tests[@]}"; do
    test_filters+=("-only-testing:BrowserInlineMediaSpikeUITests/BrowserInlineMediaSpikeUITests/$named_test")
  done
fi

overall=0
for device in iphone ipad; do
  if [[ "$device" == iphone ]]; then device_id="$iphone_id"; else device_id="$ipad_id"; fi
  curl -fsS -X POST -H "X-Spike-Recorder-Token: $SPIKE_RECORDER_TOKEN" \
    http://127.0.0.1:18755/__spike/reset > /dev/null
  if bash Scripts/with-xcode-27-rc.sh xcodebuild test-without-building \
    -xctestrun "$token_xctestrun" \
    -destination "platform=iOS Simulator,id=$device_id" \
    -resultBundlePath "$run_root/$device.xcresult" \
    -parallel-testing-enabled NO \
    "${test_filters[@]+"${test_filters[@]}"}" \
    > "$run_root/$device-test.log" 2>&1; then
    echo 0 > "$run_root/$device-exit-status"
  else
    status=$?
    echo "$status" > "$run_root/$device-exit-status"
    overall=1
  fi
  curl -fsS http://127.0.0.1:18755/__spike/evidence > "$run_root/$device-evidence.json"
  python3 Prototypes/BrowserInlineMediaSpike/summarize_evidence.py \
    "$run_root/$device-evidence.json" "$device" > "$run_root/$device-matrix.md"
done

git diff --check > "$run_root/diff-check.log" 2>&1 || overall=1
printf 'Spike 5 evidence: %s\n' "$run_root"
exit "$overall"
