#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

repository_root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repository_root"
output_root=${1:-"$repository_root/.build/spike6-run-$(date -u +%Y%m%dT%H%M%SZ)"}
mkdir -p "$output_root"

python3 -m unittest discover -s Prototypes/BrowserReceiptLifecycleSpike -p 'test_*.py'
swift test --package-path Prototypes/BrowserReceiptLifecycleSpike

python3 -u Prototypes/BrowserReceiptLifecycleSpike/fixture_server.py >"$output_root/fixture-server.log" 2>&1 &
server_pid=$!
active_simulator=''
cleanup() {
    if [[ -n "$active_simulator" ]]; then
        xcrun simctl spawn "$active_simulator" launchctl unsetenv SPIKE6_RECEIPT_MANIFEST_BASE64 || true
        xcrun simctl spawn "$active_simulator" launchctl unsetenv SPIKE6_RECEIPT_FILE_BASE64 || true
    fi
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

ready=0
for _ in {1..50}; do
    if [[ "$(curl --fail --silent http://127.0.0.1:18756/health || true)" == ok ]]; then
        ready=1
        break
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]] || ! kill -0 "$server_pid" 2>/dev/null; then
    echo "Fixture server did not start independently; see $output_root/fixture-server.log" >&2
    exit 2
fi

simulator_id() {
    xcrun simctl list devices --json | python3 -c 'import json,sys; name=sys.argv[1]; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for group in devices.values() for d in group if d["name"] == name and d["isAvailable"]))' "$1"
}

run_device() {
    local label=$1
    local name=$2
    local simulator=$3
    local device_root="$output_root/$label"
    mkdir -p "$device_root"
    active_simulator=$simulator
    xcrun simctl bootstatus "$simulator" -b
    # Each matrix starts with an empty app container and no prior background session.
    xcrun simctl uninstall "$simulator" com.danielbyon.mediavault.browserreceiptlifecyclehost 2>/dev/null || true

    gtimeout --signal=TERM --kill-after=15s 300s ./Scripts/with-xcode-27-rc.sh xcodebuild -skipMacroValidation \
        -workspace App.xcworkspace -scheme BrowserReceiptLifecycleSpike \
        -destination "platform=iOS Simulator,id=$simulator" \
        -derivedDataPath "$device_root/DerivedData" \
        -resultBundlePath "$device_root/ui.xcresult" \
        -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO \
        >"$device_root/ui.log" 2>&1 || {
            result=$?
            if [[ $result == 124 || $result == 137 ]]; then
                echo "$name UI test or diagnostics timed out; assertions may have finished" >&2
                return 3
            fi
            echo "$name UI assertions failed (exit $result)" >&2
            return 1
        }
    if grep -qi 'diagnostic.*timed out\|timed out.*diagnostic' "$device_root/ui.log"; then
        echo "$name UI assertions passed but diagnostic collection timed out" >&2
        return 3
    fi
    # The simulator suite has six expected UI cases, including task-restoration gating.
    xcrun xcresulttool get test-results summary --path "$device_root/ui.xcresult" \
        | python3 -c 'import json,sys; result=json.load(sys.stdin); assert result["passedTests"] == 6 and result["failedTests"] == 0 and result["skippedTests"] == 0, result'

    local container
    container=$(xcrun simctl get_app_container "$simulator" com.danielbyon.mediavault.browserreceiptlifecyclehost data)
    cp "$container/Library/Application Support/BrowserReceiptLifecycleSpike/events.jsonl" "$device_root/events.jsonl"
    curl --fail --silent http://127.0.0.1:18756/evidence >"$device_root/fixture-evidence.json"
    python3 Prototypes/BrowserReceiptLifecycleSpike/validate_evidence.py \
        "$device_root/events.jsonl" "$device_root/fixture-evidence.json" \
        >"$device_root/lifecycle-summary.json"
    local receipt_root="$container/Library/Application Support/BrowserReceiptLifecycleSpike/receipts"
    local selected
    selected=$(python3 Prototypes/BrowserReceiptLifecycleSpike/select_handoff.py "$receipt_root" "$device_root/fixture-evidence.json")
    local manifest_file receipt_file transfer_id source_digest byte_count
    manifest_file=$(sed -n '1p' <<<"$selected")
    receipt_file=$(sed -n '2p' <<<"$selected")
    transfer_id=$(sed -n '3p' <<<"$selected")
    source_digest=$(sed -n '4p' <<<"$selected")
    byte_count=$(sed -n '5p' <<<"$selected")
    xcrun simctl spawn "$simulator" launchctl setenv SPIKE6_RECEIPT_MANIFEST_BASE64 "$(base64 <"$manifest_file" | tr -d '\n')"
    xcrun simctl spawn "$simulator" launchctl setenv SPIKE6_RECEIPT_FILE_BASE64 "$(base64 <"$receipt_file" | tr -d '\n')"

    gtimeout --signal=TERM --kill-after=15s 300s ./Scripts/with-xcode-27-rc.sh xcodebuild -skipMacroValidation \
        -workspace Packages/ApplicationFoundation/.swiftpm/xcode/package.xcworkspace \
        -scheme ApplicationFoundation-Package \
        -destination "platform=iOS Simulator,id=$simulator" \
        -derivedDataPath "$device_root/PackageDerivedData" \
        -resultBundlePath "$device_root/journal.xcresult" \
        -parallel-testing-enabled NO \
        '-only-testing:MediaLibraryTests/BrowserReceiptLifecycleSpikeTests' \
        test CODE_SIGNING_ALLOWED=NO >"$device_root/journal.log" 2>&1 || {
            result=$?
            if [[ $result == 124 || $result == 137 ]]; then
                echo "$name journal test or diagnostics timed out; assertions may have finished" >&2
                return 3
            fi
            echo "$name journal handoff assertions failed (exit $result)" >&2
            return 1
        }
    if grep -qi 'diagnostic.*timed out\|timed out.*diagnostic' "$device_root/journal.log"; then
        echo "$name journal assertions passed but diagnostic collection timed out" >&2
        return 3
    fi
    xcrun xcresulttool get test-results summary --path "$device_root/journal.xcresult" \
        | python3 -c 'import json,sys; result=json.load(sys.stdin); assert result["passedTests"] == 2 and result["failedTests"] == 0 and result["skippedTests"] == 0, result; assert any(item.get("subtitle") == "5 test runs" for item in result.get("statistics", [])), result'
    xcrun simctl spawn "$simulator" launchctl unsetenv SPIKE6_RECEIPT_MANIFEST_BASE64
    xcrun simctl spawn "$simulator" launchctl unsetenv SPIKE6_RECEIPT_FILE_BASE64
    active_simulator=''
    printf '{"simulator":"%s","transfer_id":"%s","byte_count":%s,"sha256":"%s","test_gate":"synthetic","physical_data_protection":"unverified"}\n' \
        "$name" "$transfer_id" "$byte_count" "$source_digest" >"$device_root/summary.json"
}

run_device iphone-17 'iPhone 17' "$(simulator_id 'iPhone 17')"
run_device ipad-pro-11-m5 'iPad Pro 11-inch (M5)' "$(simulator_id 'iPad Pro 11-inch (M5)')"
printf 'Simulator tests passed; physical Data Protection and genuine OS relaunch remain unverified. Results: %s\n' "$output_root"
