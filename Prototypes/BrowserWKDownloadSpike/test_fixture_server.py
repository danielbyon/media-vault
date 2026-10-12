import hashlib
import unittest

from fixture_server import TEARDOWN_PAYLOAD, slow_payload_for, slow_transfer_evidence


class SlowTransferEvidenceTests(unittest.TestCase):
    def test_range_response_keeps_full_resource_identity_separate(self):
        path = "/resource/slow-cancel"
        full_body = slow_payload_for(path)
        response_body = full_body[4096:]

        evidence = slow_transfer_evidence(
            request_id=7,
            timestamp=1.0,
            path=path,
            bytes_sent=len(response_body),
            response_body=response_body,
            body_complete=True,
        )

        self.assertEqual(evidence["expected_bytes"], len(response_body))
        self.assertEqual(evidence["expected_full_bytes"], len(full_body))
        self.assertEqual(evidence["expected_full_sha256"], hashlib.sha256(full_body).hexdigest())
        self.assertEqual(evidence["response_sha256"], hashlib.sha256(response_body).hexdigest())
        self.assertNotEqual(evidence["response_sha256"], evidence["expected_full_sha256"])

    def test_teardown_fixture_uses_its_own_full_resource(self):
        self.assertIs(slow_payload_for("/resource/slow-ephemeral-teardown"), TEARDOWN_PAYLOAD)


if __name__ == "__main__":
    unittest.main()
