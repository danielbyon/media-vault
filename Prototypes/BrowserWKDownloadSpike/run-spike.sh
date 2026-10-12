#!/usr/bin/env bash
set -euo pipefail

readonly script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly repository_root=$(cd -- "$script_directory/../.." && pwd -P)
readonly http_base="http://127.0.0.1:18753"
readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly evidence_root="$repository_root/.build/spike-3-evidence/$run_id"
readonly tls_directory="$evidence_root/fixture-tls"
readonly certificate="$tls_directory/fixture-cert.pem"
readonly private_key="$tls_directory/fixture-key.pem"
readonly server_log="$evidence_root/fixture-server.log"
readonly fixture_server="$script_directory/fixture_server.py"

server_pid=''
run_status=0

cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -f -- "$private_key"
}
trap cleanup EXIT INT TERM

mkdir -p "$evidence_root" "$tls_directory"
(cd "$script_directory" && python3 -m unittest -v test_fixture_server.py) >"$evidence_root/fixture-tests.log" 2>&1 || {
    cat "$evidence_root/fixture-tests.log" >&2
    exit 1
}
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    -keyout "$private_key" \
    -out "$certificate" >/dev/null 2>&1

python3 -u "$fixture_server" --certificate "$certificate" --private-key "$private_key" --run-id "$run_id" \
    >"$server_log" 2>&1 &
server_pid=$!

server_ready=0
for attempt in $(seq 1 50); do
    health_response=$(curl --fail --silent "$http_base/__spike/health" || true)
    if kill -0 "$server_pid" 2>/dev/null && [[ -n "$health_response" ]] \
        && python3 -c 'import json,sys; health=json.load(sys.stdin); sys.exit(0 if health.get("run_id")==sys.argv[1] else 1)' "$run_id" <<<"$health_response"; then
        server_ready=1
        break
    fi
    sleep 0.2
done
if [[ "$server_ready" -ne 1 ]]; then
    cat "$server_log" >&2
    printf 'Spike 3 fixture server did not become ready. Evidence: %s\n' "$evidence_root" >&2
    exit 1
fi

write_device_metadata() {
    local label=$1
    local destination=$2
    local output_directory=$3
    cat >"$output_directory/device-metadata.json" <<EOF
{
  "device_label": "$label",
  "xcode_destination": "$destination",
  "http_origin": "$http_base",
  "https_origin": "https://127.0.0.1:18754",
  "fixture_certificate_sha256": "$(shasum -a 256 "$certificate" | awk '{print $1}')",
  "fixture_server_pid": "$server_pid"
}
EOF
}

run_device() {
    local label=$1
    local destination=$2
    local output_directory="$evidence_root/$label"
    local derived_data="$evidence_root/DerivedData-$label"
    local result_bundle="$output_directory/BrowserWKDownloadSpike.xcresult"
    mkdir -p "$output_directory"

    curl --fail --silent --show-error -X POST "$http_base/__spike/reset" -o /dev/null
    write_device_metadata "$label" "$destination" "$output_directory"

    printf 'Running Spike 3 on %s. Evidence: %s\n' "$label" "$output_directory"
    if SPIKE_EVIDENCE_DIRECTORY="$output_directory" \
        SPIKE_BASE_URL="$http_base" \
        "$repository_root/Scripts/with-xcode-27-rc.sh" xcodebuild \
            -skipMacroValidation \
            -workspace "$repository_root/App.xcworkspace" \
            -scheme BrowserWKDownloadSpike \
            -configuration Debug \
            -destination "$destination" \
            -derivedDataPath "$derived_data" \
            -resultBundlePath "$result_bundle" \
            -parallel-testing-enabled NO \
            -maximum-concurrent-test-simulator-destinations 1 \
            test; then
        printf 'Spike 3 XCTest passed on %s.\n' "$label"
    else
        printf 'Spike 3 XCTest failed on %s.\n' "$label" >&2
        run_status=1
    fi

    if ! curl --fail --silent --show-error "$http_base/__spike/evidence" \
        --output "$output_directory/fixture-evidence.json"; then
        printf 'Could not export independent fixture evidence for %s.\n' "$label" >&2
        run_status=1
    fi
}

run_device "iphone" 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
run_device "ipad" 'platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0'

cat >"$evidence_root/run-summary.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "fixture_server": "independent host process",
  "http_origin": "$http_base",
  "https_origin": "https://127.0.0.1:18754",
  "iphone_result_bundle": "iphone/BrowserWKDownloadSpike.xcresult",
  "ipad_result_bundle": "ipad/BrowserWKDownloadSpike.xcresult",
  "iphone_fixture_evidence": "iphone/fixture-evidence.json",
  "ipad_fixture_evidence": "ipad/fixture-evidence.json",
  "xcodebuild_status": $run_status
}
EOF

printf 'Spike 3 runtime evidence: %s\n' "$evidence_root"
exit "$run_status"
