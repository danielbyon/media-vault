import unittest

from summarize_evidence import summarize


def make_event(kind, press_id, **values):
    return {"kind": kind, "fields": {"pressID": press_id, **values}}


class EvidenceSummaryTests(unittest.TestCase):
    def test_repeated_case_and_mode_rows_use_only_their_press_events(self):
        first_press = "11111111-1111-4111-8111-111111111111"
        second_press = "22222222-2222-4222-8222-222222222222"
        common = {"case": "cross-iframe", "mode": "native"}
        evidence = {
            "requests": [],
            "events": [
                make_event("ui-press", first_press, **common),
                make_event("bridge-observation", first_press, **common, event="contextmenu"),
                make_event("ui-press", second_press, **common),
                make_event("bridge-observation", second_press, **common, event="contextmenu"),
                make_event("bridge-observation", second_press, **common, event="contextmenu"),
            ],
        }

        rows = [line for line in summarize(evidence, "iphone").splitlines()
                if line.startswith("| native | cross-iframe |")]

        self.assertEqual([row.split("|")[7].strip() for row in rows], ["1", "2"])

    def test_repeated_case_rows_do_not_reuse_media_requests_from_other_presses(self):
        first_press = "11111111-1111-4111-8111-111111111111"
        second_press = "22222222-2222-4222-8222-222222222222"
        common = {"case": "cross-iframe", "mode": "native"}
        evidence = {
            "requests": [
                {"path": "/case/cross-iframe", "pressID": first_press},
                {"path": "/media/first.jpg", "pressID": first_press},
                {"path": "/case/cross-iframe", "pressID": second_press},
                {"path": "/media/second.jpg", "pressID": second_press},
            ],
            "events": [
                make_event("ui-press", first_press, **common),
                make_event("ui-press", second_press, **common),
            ],
        }

        rows = [line for line in summarize(evidence, "iphone").splitlines()
                if line.startswith("| native | cross-iframe |")]
        first_media = rows[0].split("|")[3]
        second_media = rows[1].split("|")[3]

        self.assertIn("/media/first.jpg", first_media)
        self.assertNotIn("/media/second.jpg", first_media)
        self.assertIn("/media/second.jpg", second_media)
        self.assertNotIn("/media/first.jpg", second_media)


if __name__ == "__main__":
    unittest.main()
