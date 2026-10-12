"""Deterministic checks for the independent GET fixture bytes."""

import hashlib
import json
import pathlib
import tempfile
import unittest

from fixture_server import SLOW, STILL, _png
from validate_evidence import validate, validate_lifecycle


class FixtureTests(unittest.TestCase):
    def test_sanitizer_rejects_secret_values_even_when_they_start_with_f(self):
        process_id = "11111111-1111-4111-8111-111111111111"
        slow_id = "22222222-2222-4222-8222-222222222222"
        timeout_id = "33333333-3333-4333-8333-333333333333"
        events = [
            {"kind": "transfer-started", "transferID": slow_id, "processID": process_id},
            {"kind": "scene-phase", "phase": "background", "processID": process_id},
            {"kind": "receipt-accepted", "transferID": slow_id, "processID": process_id,
             "byteCount": "82", "sha256": hashlib.sha256(STILL).hexdigest()},
            {"kind": "transfer-started", "transferID": timeout_id, "processID": process_id},
            {"kind": "transfer-timeout", "transferID": timeout_id,
             "synthetic": "true", "processID": process_id},
        ]
        template = {
            "status": 200, "bytes_sent": 82, "source_bytes": 82,
            "source_sha256": hashlib.sha256(STILL).hexdigest(), "complete": True,
            "cookie_present": False, "authorization_present": False,
        }
        fixture = [dict(template, path="/media/slow", transfer_id=slow_id),
                   dict(template, path="/media/timeout", transfer_id=timeout_id,
                        status=0, bytes_sent=0, source_bytes=0,
                        source_sha256=hashlib.sha256(b"").hexdigest(), complete=False)]

        def check(rows, requests):
            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                event_path = root / "events.jsonl"
                fixture_path = root / "fixture.json"
                event_path.write_text("\n".join(json.dumps(row) for row in rows))
                fixture_path.write_text(json.dumps(requests))
                return validate(event_path, fixture_path)

        self.assertEqual(check(events, fixture)["background_transfer_id"], slow_id)
        for secret in ("password=fsecret", "token=fsecret", "Cookie: fsecret",
                       "Authorization: fsecret", "https://fixture.invalid/secret"):
            with self.subTest(secret=secret):
                altered_events = [dict(row) for row in events]
                altered_events[0]["reason"] = secret
                with self.assertRaises(ValueError):
                    check(altered_events, fixture)
                altered_fixture = [dict(row) for row in fixture]
                altered_fixture[0]["path"] = secret
                with self.assertRaises(ValueError):
                    check(events, altered_fixture)
        for credential_field in ("cookie_present", "authorization_present"):
            with self.subTest(field=credential_field):
                altered_fixture = [dict(row) for row in fixture]
                altered_fixture[0][credential_field] = True
                with self.assertRaises(ValueError):
                    check(events, altered_fixture)

    def test_still_is_deterministic_png(self):
        self.assertEqual(STILL, _png())
        self.assertTrue(STILL.startswith(b"\x89PNG"))
        self.assertEqual(len(hashlib.sha256(STILL).hexdigest()), 64)

    def test_slow_body_is_larger_than_still(self):
        self.assertGreater(len(SLOW), 8 * 1024 * 1024)

    def test_background_and_timeout_need_independent_correlation(self):
        events = [
            {"kind": "transfer-started", "transferID": "slow", "processID": "host"},
            {"kind": "scene-phase", "phase": "background", "processID": "host"},
            {"kind": "receipt-accepted", "transferID": "slow", "processID": "host",
             "byteCount": "1", "sha256": hashlib.sha256(b"x").hexdigest()},
            {"kind": "transfer-started", "transferID": "timeout", "processID": "host"},
            {"kind": "transfer-timeout", "transferID": "timeout", "synthetic": "true"},
        ]
        fixture = [
            {"path": "/media/slow", "transfer_id": "slow", "status": 200,
             "complete": True, "bytes_sent": 1, "source_bytes": 1,
             "source_sha256": hashlib.sha256(b"x").hexdigest()},
            {"path": "/media/timeout", "transfer_id": "timeout", "status": 0,
             "complete": False, "bytes_sent": 0, "source_bytes": 0,
             "source_sha256": hashlib.sha256(b"").hexdigest()},
        ]
        summary = validate_lifecycle(events, fixture)
        self.assertEqual(summary["background_transfer_id"], "slow")
        self.assertEqual(summary["timeout_transfer_id"], "timeout")
        with self.assertRaises(ValueError):
            validate_lifecycle(events[:1] + events[2:], fixture)
        with self.assertRaises(ValueError):
            validate_lifecycle(events, fixture[:1])
        with self.assertRaises(ValueError):
            validate_lifecycle(events[:3] + events[4:], fixture)


if __name__ == "__main__":
    unittest.main()
