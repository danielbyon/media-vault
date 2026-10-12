"""Select one byte-identical still receipt using independent server evidence."""

import hashlib
import json
import pathlib
import sys


def select(receipt_root: pathlib.Path, evidence_path: pathlib.Path):
    requests = json.loads(evidence_path.read_text())
    candidates = [
        item
        for item in requests
        if item.get("path") == "/media/still"
        and item.get("complete") is True
        and item.get("cookie_present") is False
        and item.get("authorization_present") is False
    ]
    for manifest_path in sorted((receipt_root / "metadata").glob("*.manifest")):
        manifest = json.loads(manifest_path.read_text())
        identity = manifest["identity"]
        receipt_path = receipt_root / "bytes" / f"{identity['resourceID'].lower()}.receipt"
        if not receipt_path.is_file():
            continue
        contents = receipt_path.read_bytes()
        digest = hashlib.sha256(contents).hexdigest()
        for request in candidates:
            if (
                identity["transferID"].lower() == request["transfer_id"]
                and manifest["byteCount"] == request["source_bytes"] == len(contents)
                and manifest["sha256"] == request["source_sha256"] == digest
            ):
                return manifest_path, receipt_path, identity["transferID"], digest, len(contents)
    raise ValueError("No host receipt matches a complete credential-free fixture GET")


if __name__ == "__main__":
    chosen = select(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    for item in chosen:
        print(item)
