"""Validate the closed, sanitized schema of independent Spike 6 evidence."""

import json
import hashlib
import pathlib
import re
import sys

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
INTEGER = re.compile(r"(?:0|[1-9][0-9]*)\Z")
SIGNED_INTEGER = re.compile(r"-?(?:0|[1-9][0-9]*)\Z")
EVENT_KINDS = {
    "app-launched", "background-events-delivered", "background-events-settled",
    "locked-metadata-scan", "metadata-scan-failed", "protection-inheritance",
    "receipt-accepted", "receipt-rejected", "receipt-verified", "scene-phase",
    "session-reattached", "test-unlock", "transfer-cancelled",
    "transfer-start-attempt", "transfer-start-rejected", "transfer-started",
    "transfer-terminal", "transfer-timeout", "verification-deferred",
    "verification-failed",
}
PROTECTION_VALUES = {
    "NSFileProtectionCompleteUnlessOpen", "NSFileProtectionCompleteUntilFirstUserAuthentication",
    "completeUnlessOpen", "completeUntilFirstUserAuthentication",
    "unverified-nil", "unverified-non-ios", "unrecognized",
}
EVENT_RULES = {
    "kind": EVENT_KINDS,
    "processID": UUID,
    "transferID": UUID,
    "assetID": UUID,
    "resourceID": UUID,
    "launchOptionsPresent": {"true", "false"},
    "receiptCount": INTEGER,
    "vaultOpened": {"false"},
    "taskCount": INTEGER,
    "phase": {"active", "inactive", "background"},
    "method": {"GET"},
    "credentialsAttached": {"false"},
    "errorCode": re.compile(r"(?:-?(?:0|[1-9][0-9]*)|none)\Z"),
    "taskID": INTEGER,
    "synthetic": {"true"},
    "verified": {"true", "false"},
    "byteCount": INTEGER,
    "sha256": SHA256,
    "protectionRequested": {"completeUnlessOpen"},
    "receiptDirectoryProtection": PROTECTION_VALUES,
    "receiptFileProtection": PROTECTION_VALUES,
    "metadataDirectoryProtection": PROTECTION_VALUES,
    "inheritanceProtection": PROTECTION_VALUES,
    "reason": {"unsupported", "active-or-unavailable", "protection", "response"},
}
FIXTURE_KEYS = {
    "path", "transfer_id", "status", "bytes_sent", "source_bytes", "source_sha256",
    "complete", "cookie_present", "authorization_present",
}


def _check_string(value, rule, field):
    if not isinstance(value, str) or not (
        value in rule if isinstance(rule, set) else rule.fullmatch(value)
    ):
        raise ValueError(f"Invalid sanitized {field}")


def _check_event(event):
    if not isinstance(event, dict) or not {"kind", "processID"} <= event.keys():
        raise ValueError("Missing event identity")
    if event.keys() - EVENT_RULES.keys():
        raise ValueError("Unexpected event field")
    for field, value in event.items():
        _check_string(value, EVENT_RULES[field], field)


def _check_fixture(request):
    if not isinstance(request, dict) or request.keys() != FIXTURE_KEYS:
        raise ValueError("Invalid fixture fields")
    _check_string(request["path"], {"/media/still", "/media/slow", "/media/timeout"}, "path")
    _check_string(request["transfer_id"], UUID, "transfer_id")
    _check_string(request["source_sha256"], SHA256, "source_sha256")
    if type(request["status"]) is not int or request["status"] not in {0, 200}:
        raise ValueError("Invalid fixture status")
    for field in ("bytes_sent", "source_bytes"):
        if type(request[field]) is not int or request[field] < 0:
            raise ValueError(f"Invalid fixture {field}")
    for field in ("complete", "cookie_present", "authorization_present"):
        if type(request[field]) is not bool:
            raise ValueError(f"Invalid fixture {field}")
    if request["cookie_present"] or request["authorization_present"]:
        raise ValueError("Credential-bearing fixture request")
    if request["path"] == "/media/timeout":
        if (request["status"], request["bytes_sent"], request["source_bytes"], request["complete"]) \
                != (0, 0, 0, False) or request["source_sha256"] != hashlib.sha256(b"").hexdigest():
            raise ValueError("Invalid withheld-response evidence")
    elif not (request["status"] == 200 and request["source_bytes"] > 0
              and request["bytes_sent"] <= request["source_bytes"]
              and request["complete"] == (request["bytes_sent"] == request["source_bytes"])):
        raise ValueError("Invalid completed or partial fixture evidence")


def validate(events_path: pathlib.Path, fixture_path: pathlib.Path):
    """Reject unexpected evidence before correlating app and server observations."""
    events = [json.loads(line) for line in events_path.read_text().splitlines()]
    fixture = json.loads(fixture_path.read_text())
    if not isinstance(fixture, list) or not events or not fixture:
        raise ValueError("Missing independent event or fixture evidence")
    for event in events:
        _check_event(event)
    for request in fixture:
        _check_fixture(request)
    return validate_lifecycle(events, fixture)


def validate_lifecycle(events: list[dict], fixture: list[dict]) -> dict:
    """Correlate simulator background and app-enforced timeout observations."""
    fixture_transfer_ids = {request["transfer_id"] for request in fixture}
    for event in events:
        if event.get("kind") == "receipt-accepted":
            transfer_id = event.get("transferID")
            if not transfer_id or transfer_id not in fixture_transfer_ids:
                raise ValueError("Accepted receipt has no independent fixture request")

    background_transfer = None
    timeout_transfer = None
    for request in fixture:
        transfer_id = request["transfer_id"]
        indexed = [(index, event) for index, event in enumerate(events)
                   if event.get("transferID") == transfer_id]
        accepted = [index for index, event in indexed if event["kind"] == "receipt-accepted"]
        if accepted:
            if request["status"] != 200 or not request["complete"]:
                raise ValueError("Accepted receipt does not match a completed fixture response")
            for index in accepted:
                event = events[index]
                if event.get("byteCount") != str(request["source_bytes"]):
                    raise ValueError("Accepted receipt byte count does not match the independent fixture")
                if event.get("sha256") != request["source_sha256"]:
                    raise ValueError("Accepted receipt hash does not match the independent fixture")
        if request["path"] == "/media/slow" and request["complete"] and accepted:
            started = [(index, event) for index, event in indexed
                       if event["kind"] == "transfer-started"]
            if started:
                start_index, start_event = started[0]
                backgrounded = any(
                    start_index < index < accepted[0]
                    and event.get("kind") == "scene-phase"
                    and event.get("phase") == "background"
                    and event.get("processID") == start_event.get("processID")
                    for index, event in enumerate(events)
                )
                if backgrounded:
                    background_transfer = transfer_id
        if request["path"] == "/media/timeout":
            started = any(event["kind"] == "transfer-started" for _, event in indexed)
            timed_out = any(event["kind"] == "transfer-timeout"
                            and event.get("synthetic") == "true"
                            for _, event in indexed)
            if started and timed_out and not accepted and request["bytes_sent"] == 0 \
                    and not request["complete"]:
                timeout_transfer = transfer_id
    if background_transfer is None:
        raise ValueError("No independently correlated Home-backgrounded completed transfer")
    if timeout_transfer is None:
        raise ValueError("No independently correlated bounded timeout without acceptance")
    return {
        "background_transfer_id": background_transfer,
        "timeout_transfer_id": timeout_transfer,
        "background_kind": "simulator-home-backgrounding",
        "timeout_kind": "app-enforced",
    }


if __name__ == "__main__":
    print(json.dumps(validate(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])), sort_keys=True))
