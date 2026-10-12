"""Exercise the independent inline-media fixture over HTTP."""

from __future__ import annotations

import base64
import json
import re
import threading
import unittest
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from fixture_server import EVIDENCE, Handler, IMAGE, VIDEO, fixture_page
from summarize_evidence import summarize


class FixtureServerTests(unittest.TestCase):
    def setUp(self) -> None:
        EVIDENCE.reset()
        self.recorder_token = "fixture-test-recorder-token"
        self.recorder_token_patcher = patch("fixture_server.RECORDER_TOKEN", self.recorder_token)
        self.recorder_token_patcher.start()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.recorder_token_patcher.stop()

    def get(self, path: str) -> bytes:
        with urlopen(self.base + path, timeout=5) as response:
            return response.read()

    def post(self, path: str, data: bytes) -> int:
        request = Request(
            self.base + path,
            data=data,
            method="POST",
            headers={"X-Spike-Recorder-Token": self.recorder_token},
        )
        with urlopen(request, timeout=5) as response:
            return response.status

    def test_linked_media_is_distinct_from_link_destination(self) -> None:
        page = self.get("/case/linked-image").decode()
        self.assertIn('href="/destination/link"', page)
        self.assertIn('src="/media/image-a.jpg"', page)

    def test_picture_video_and_frame_fixtures_are_distinct(self) -> None:
        self.assertIn("srcset=", self.get("/case/picture").decode())
        self.assertIn("<source", self.get("/case/video-source").decode())
        self.assertIn("<video src=", self.get("/case/video-src").decode())
        self.assertIn("http://localhost:18755/frame/cross-iframe", self.get("/case/cross-iframe").decode())
        self.assertIn("<img", self.get("/frame/cross-iframe").decode())

    def test_dynamic_and_opaque_cases_have_only_declared_setup(self) -> None:
        self.assertIn("image-b.jpg", fixture_page("dynamic").decode())
        blob_page = fixture_page("blob").decode()
        self.assertIn("createObjectURL", blob_page)
        blob_encoded = re.search(r'atob\("([A-Za-z0-9+/=]+)"\)', blob_page)
        self.assertIsNotNone(blob_encoded)
        self.assertEqual(base64.b64decode(blob_encoded.group(1)), IMAGE)
        page = fixture_page("data").decode()
        encoded = re.search(r'data:image/jpeg;base64,([A-Za-z0-9+/=]+)', page)
        self.assertIsNotNone(encoded)
        self.assertEqual(base64.b64decode(encoded.group(1)), IMAGE)
        self.assertNotIn("querySelectorAll", fixture_page("synthetic").decode())

    def test_media_bytes_and_evidence_are_separate(self) -> None:
        self.assertEqual(self.get("/media/image-a.jpg"), IMAGE)
        self.assertEqual(self.get("/media/video-a.mp4"), VIDEO)
        evidence = json.loads(self.get("/__spike/evidence"))
        self.assertEqual(evidence["requests"][0], {"path": "/media/image-a.jpg", "status": 200})
        self.assertNotIn("body", json.dumps(evidence))

    def test_case_press_id_is_propagated_to_media_requests_and_evidence(self) -> None:
        press_id = "11111111-1111-4111-8111-111111111111"
        page = self.get(f"/case/linked-image?pressID={press_id}").decode()
        self.assertIn(f"/media/image-a.jpg?pressID={press_id}", page)
        self.get(f"/media/image-a.jpg?pressID={press_id}")

        evidence = json.loads(self.get("/__spike/evidence"))
        self.assertEqual(evidence["requests"], [
            {"path": "/case/linked-image", "status": 200, "pressID": press_id},
            {"path": "/media/image-a.jpg", "status": 200, "pressID": press_id},
        ])

    def test_malformed_event_is_rejected_and_page_probe_is_constrained(self) -> None:
        with self.assertRaises(HTTPError) as response:
            self.post("/__spike/event", b"not-json")
        self.assertEqual(response.exception.code, 400)
        response.exception.close()
        self.assertEqual(self.post("/__spike/page-probe", b'{"kind":"page-probe","result":"handler-not-visible","secret":"omit"}'), 200)
        evidence = json.loads(self.get("/__spike/evidence"))
        self.assertEqual(evidence["events"], [{"kind": "page-probe", "result": "handler-not-visible"}])

    def test_page_cannot_forge_app_recorder_event_with_token(self) -> None:
        with patch("fixture_server.RECORDER_TOKEN", "fixture-secret"):
            request = Request(
                self.base + "/__spike/event",
                data=b'{"kind":"bridge-observation"}',
                method="POST",
            )
            with self.assertRaises(HTTPError) as response:
                urlopen(request, timeout=5)
            self.assertEqual(response.exception.code, 403)
            response.exception.close()
            request = Request(
                self.base + "/__spike/event",
                data=b'{"kind":"ui-press"}',
                method="POST",
                headers={"X-Spike-Recorder-Token": "fixture-secret"},
            )
            with urlopen(request, timeout=5) as authorized:
                self.assertEqual(authorized.status, 200)

    def test_recorder_endpoints_fail_closed_without_configured_token(self) -> None:
        with patch("fixture_server.RECORDER_TOKEN", None):
            for path, body in (
                ("/__spike/reset", b"{}"),
                ("/__spike/event", b'{"kind":"bridge-observation"}'),
            ):
                with self.subTest(path=path):
                    request = Request(self.base + path, data=body, method="POST")
                    with self.assertRaises(HTTPError) as response:
                        urlopen(request, timeout=5)
                    self.assertEqual(response.exception.code, 403)
                    response.exception.close()

    def test_matrix_does_not_confuse_menu_with_url_callback(self) -> None:
        evidence = {"events": [
            {"kind": "ui-press", "fields": {"case": "unlinked-image", "mode": "native", "menuAccessibilityDetected": "true"}},
            {"kind": "ui-press", "fields": {"case": "unlinked-image", "mode": "bridge", "menuAccessibilityDetected": "true"}},
            {"kind": "bridge-observation", "fields": {"case": "unlinked-image", "mode": "bridge", "event": "contextmenu", "selectedMedia": "http://127.0.0.1/media/image-a.jpg"}},
        ]}
        matrix = summarize(evidence, "iPhone 17")
        rows = [line for line in matrix.splitlines() if line.startswith("| native |") or line.startswith("| bridge |")]
        self.assertEqual(len(rows), 2)
        self.assertIn("unavailable on iOS 27", rows[0])
        self.assertIn("| 0 |", rows[0])
        self.assertIn("| 1 |", rows[1])


if __name__ == "__main__":
    unittest.main()
