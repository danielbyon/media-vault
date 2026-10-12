import unittest

from validate_evidence import validate_lifecycle


PROCESS_ID = "11111111-1111-4111-8111-111111111111"
SLOW_TRANSFER_ID = "22222222-2222-4222-8222-222222222222"
TIMEOUT_TRANSFER_ID = "33333333-3333-4333-8333-333333333333"
SOURCE_HASH = "a" * 64


def fixture_evidence():
    return [
        {
            "path": "/media/slow",
            "transfer_id": SLOW_TRANSFER_ID,
            "status": 200,
            "bytes_sent": 512,
            "source_bytes": 512,
            "source_sha256": SOURCE_HASH,
            "complete": True,
            "cookie_present": False,
            "authorization_present": False,
        },
        {
            "path": "/media/timeout",
            "transfer_id": TIMEOUT_TRANSFER_ID,
            "status": 0,
            "bytes_sent": 0,
            "source_bytes": 0,
            "source_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "complete": False,
            "cookie_present": False,
            "authorization_present": False,
        },
    ]


def lifecycle_events(byte_count="512", sha256=SOURCE_HASH):
    return [
        {
            "kind": "transfer-started",
            "processID": PROCESS_ID,
            "transferID": SLOW_TRANSFER_ID,
        },
        {
            "kind": "scene-phase",
            "processID": PROCESS_ID,
            "phase": "background",
        },
        {
            "kind": "receipt-accepted",
            "processID": PROCESS_ID,
            "transferID": SLOW_TRANSFER_ID,
            "byteCount": byte_count,
            "sha256": sha256,
        },
        {
            "kind": "transfer-started",
            "processID": PROCESS_ID,
            "transferID": TIMEOUT_TRANSFER_ID,
        },
        {
            "kind": "transfer-timeout",
            "processID": PROCESS_ID,
            "transferID": TIMEOUT_TRANSFER_ID,
            "synthetic": "true",
        },
    ]


class EvidenceValidationTests(unittest.TestCase):
    def test_accepts_receipt_matching_complete_independent_fixture(self):
        result = validate_lifecycle(lifecycle_events(), fixture_evidence())

        self.assertEqual(result["background_transfer_id"], SLOW_TRANSFER_ID)

    def test_rejects_receipt_with_different_byte_count_or_hash(self):
        for byte_count, sha256 in (("511", SOURCE_HASH), ("512", "b" * 64)):
            with self.subTest(byte_count=byte_count, sha256=sha256):
                with self.assertRaisesRegex(ValueError, "does not match the independent fixture"):
                    validate_lifecycle(lifecycle_events(byte_count, sha256), fixture_evidence())

    def test_rejects_accepted_receipt_without_a_fixture_transfer(self):
        events = lifecycle_events()
        events.append({
            "kind": "receipt-accepted",
            "processID": PROCESS_ID,
            "transferID": "44444444-4444-4444-8444-444444444444",
            "byteCount": "512",
            "sha256": SOURCE_HASH,
        })

        with self.assertRaisesRegex(ValueError, "no independent fixture request"):
            validate_lifecycle(events, fixture_evidence())


if __name__ == "__main__":
    unittest.main()
