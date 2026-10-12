#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root_dir"

output_root="$root_dir/.build/browser-save-to-vault-spike"
mkdir -p "$output_root"
certificate="$output_root/fixture-cert.pem"
private_key="$output_root/fixture-key.pem"
ca_certificate="$output_root/fixture-ca.pem"
ca_private_key="$output_root/fixture-ca-key.pem"
certificate_request="$output_root/fixture-cert.csr"
certificate_extensions="$output_root/fixture-cert-extensions.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$ca_private_key" -out "$ca_certificate" \
    -subj "/CN=Browser Spike 4 Fixture CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$private_key" -out "$certificate_request" \
    -subj "/CN=127.0.0.1" >/dev/null 2>&1
cat >"$certificate_extensions" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1,DNS:localhost
EOF
openssl x509 -req -in "$certificate_request" -CA "$ca_certificate" \
    -CAkey "$ca_private_key" -CAcreateserial -out "$certificate" \
    -days 2 -sha256 -extfile "$certificate_extensions" >/dev/null 2>&1

python3 Prototypes/BrowserSaveToVaultSpike/fixture_server.py \
    --certificate "$certificate" --private-key "$private_key" \
    >"$output_root/fixture-server.log" 2>&1 &
fixture_pid=$!
cleanup() {
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

ready=0
for attempt in {1..50}; do
    health="$(curl --fail --silent http://127.0.0.1:18753/__spike/health || true)"
    if [[ "$health" == *BrowserSaveToVaultSpike* ]]; then
        ready=1
        break
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]]; then
    cat "$output_root/fixture-server.log"
    echo "Fixture server failed to start" >&2
    exit 1
fi

failed=0
xcode_wrapper="Scripts/with-xcode-27-rc.sh"
package_workspace="Packages/ApplicationFoundation/.swiftpm/xcode/package.xcworkspace"
package_scheme="ApplicationFoundation-Package"
host_bundle_id="com.danielbyon.mediavault.browsersavetovaulthost"

run_device() {
    local label="$1"
    local udid="$2"
    local derived_data="$output_root/DerivedData-$label"
    local ui_result="$output_root/$label-ui.xcresult"
    local package_result="$output_root/$label-journal.xcresult"

    echo "=== Spike 4 UI matrix: $label ($udid) ==="
    xcrun simctl bootstatus "$udid" -b
    xcrun simctl keychain "$udid" add-root-cert "$ca_certificate"
    curl --fail --silent --request POST http://127.0.0.1:18753/__spike/reset >/dev/null
    if container=$(xcrun simctl get_app_container "$udid" "$host_bundle_id" data 2>/dev/null); then
        rm -rf -- "$container/Library/Application Support/BrowserSaveToVaultSpike/receipt-staging"
    fi
    rm -rf -- "$ui_result" "$package_result"

    if ! "$xcode_wrapper" xcodebuild -skipMacroValidation \
        -workspace App.xcworkspace -scheme BrowserSaveToVaultSpike \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived_data" -resultBundlePath "$ui_result" \
        -parallel-testing-enabled NO test 2>&1 | tee "$output_root/$label-ui.log"; then
        echo "UI matrix failed for $label" >&2
        failed=1
    fi

    curl --fail --silent http://127.0.0.1:18753/__spike/evidence \
        >"$output_root/$label-evidence.json" || failed=1
    if [[ ! -d "$ui_result" ]]; then
        return
    fi

    if ! container=$(xcrun simctl get_app_container "$udid" "$host_bundle_id" data 2>/dev/null); then
        echo "Spike host app container is unavailable for $label" >&2
        failed=1
        return
    fi
    local receipt="$container/Library/Application Support/BrowserSaveToVaultSpike/receipt-staging/save-link-still.receipt"
    if [[ ! -f "$receipt" ]]; then
        echo "Expected simulator receipt was not found for $label" >&2
        failed=1
        return
    fi

    local receipt_base64
    receipt_base64="$(base64 <"$receipt" | tr -d '\n')"
    echo "=== Spike 4 SQLite journal handoff: $label ==="
    xcrun simctl spawn "$udid" launchctl setenv SPIKE_BROWSER_RECEIPT_BASE64 "$receipt_base64"
    if ! "$xcode_wrapper" xcodebuild \
        -skipMacroValidation -workspace "$package_workspace" -scheme "$package_scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived_data/PackageTests" -resultBundlePath "$package_result" \
        -parallel-testing-enabled NO \
        '-only-testing:MediaLibraryTests/BrowserReceiptIngestionTests/reconcilesTransferredReceipt()' test \
        2>&1 | tee "$output_root/$label-journal.log"; then
        echo "SQLite journal test failed for $label" >&2
        failed=1
    elif ! xcrun xcresulttool get test-results summary --path "$package_result" --format json \
        | python3 -c 'import json,sys; result=json.load(sys.stdin); assert result["passedTests"] == 1 and result["failedTests"] == 0 and result["skippedTests"] == 0 and result["totalTestCount"] == 1, result'; then
        echo "SQLite journal result bundle did not contain the selected passing test for $label" >&2
        failed=1
    fi
    xcrun simctl spawn "$udid" launchctl unsetenv SPIKE_BROWSER_RECEIPT_BASE64
}

# Resolve simulator IDs by model because CoreSimulator assigns IDs per machine.
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
run_device "iphone-17" "$iphone_id"
run_device "ipad-pro-11-m5" "$ipad_id"

if [[ "$failed" != 0 ]]; then
    echo "One or more Spike 4 simulator validations failed; inspect $output_root" >&2
    exit 1
fi

echo "Spike 4 simulator matrices and journal handoffs passed; evidence saved under $output_root"
