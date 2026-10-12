#!/usr/bin/env python3
"""Serve centered inline-media fixtures and independently record sanitized evidence.

The server binds only to loopback. ``127.0.0.1`` and ``localhost`` deliberately
provide different origins for the iframe case. No request body containing media,
cookies, or page script is written to evidence.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit


PORT = 18755
RECORDER_TOKEN = os.environ.get("SPIKE_RECORDER_TOKEN")
FIXTURES = Path(__file__).resolve().parent / "fixtures"
IMAGE = (FIXTURES / "direct-image.jpg").read_bytes()
VIDEO = (FIXTURES / "direct-video.mp4").read_bytes()
IMAGE_BASE64 = base64.b64encode(IMAGE).decode("ascii")
VALID_CASES = frozenset({
    "linked-image", "unlinked-image", "picture", "video-src", "video-source",
    "css-background", "canvas", "same-iframe", "cross-iframe", "responsive",
    "relative", "dynamic", "blob", "data", "synthetic", "forged-page", "blank",
})


class Evidence:
    """Store only fixed fixture paths and constrained app/test observations."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.events: list[dict[str, object]] = []
        self.requests: list[dict[str, object]] = []

    def reset(self) -> None:
        with self.lock:
            self.events.clear()
            self.requests.clear()

    def add_request(self, path: str, status: int, press_id: str | None = None) -> None:
        with self.lock:
            request: dict[str, object] = {"path": path, "status": status}
            if press_id:
                try:
                    request["pressID"] = str(uuid.UUID(press_id))
                except ValueError:
                    pass
            self.requests.append(request)

    def add_event(self, event: dict[str, object]) -> None:
        with self.lock:
            self.events.append(event)

    def export(self) -> dict[str, object]:
        with self.lock:
            return {"schema_version": 5, "requests": list(self.requests), "events": list(self.events)}


EVIDENCE = Evidence()


def _media(case_id: str) -> str:
    if case_id == "linked-image":
        return '<a href="/destination/link" aria-label="linked image"><img src="/media/image-a.jpg" alt="linked image"></a>'
    if case_id in ("unlinked-image", "relative", "forged-page", "synthetic"):
        source = "../media/image-a.jpg" if case_id == "relative" else "/media/image-a.jpg"
        return f'<img id="target" src="{source}" alt="{case_id}">'
    if case_id in ("picture", "responsive"):
        return '<picture><source media="(min-width: 700px)" srcset="/media/image-wide.jpg"><img src="/media/image-a.jpg" alt="responsive image"></picture>'
    if case_id == "video-src":
        return '<video src="/media/video-a.mp4" poster="/media/image-a.jpg" controls playsinline preload="metadata"></video>'
    if case_id == "video-source":
        return '<video poster="/media/image-a.jpg" controls playsinline preload="metadata"><source src="/media/video-a.mp4" type="video/mp4"></video>'
    if case_id == "css-background":
        return '<div id="target" class="background" aria-label="CSS image"></div>'
    if case_id == "canvas":
        return '<canvas id="target" width="240" height="180" aria-label="canvas image"></canvas>'
    if case_id == "dynamic":
        return '<img id="target" src="/media/image-a.jpg" alt="dynamic image">'
    if case_id == "blob":
        return '<img id="target" alt="blob image">'
    if case_id == "data":
        return f'<img id="target" src="data:image/jpeg;base64,{IMAGE_BASE64}" alt="data image">'
    if case_id == "same-iframe":
        return '<iframe title="same origin media" src="/frame/same-iframe"></iframe>'
    if case_id == "cross-iframe":
        return f'<iframe title="cross origin media" src="http://localhost:{PORT}/frame/cross-iframe"></iframe>'
    return '<div id="target">blank fixture</div>'


def fixture_page(case_id: str, *, frame: bool = False, press_id: str | None = None) -> bytes:
    """Render one centered target with deterministic, bounded setup scripts."""
    target = '<img src="/media/image-a.jpg" alt="iframe image">' if frame else _media(case_id)
    setup = {
        "canvas": 'const c=document.getElementById("target");const g=c.getContext("2d");g.fillStyle="#2868b8";g.fillRect(0,0,240,180);',
        "dynamic": 'setTimeout(()=>{document.getElementById("target").src="/media/image-b.jpg"},650);',
        "blob": f'const bytes=Uint8Array.from(atob("{IMAGE_BASE64}"),ch=>ch.charCodeAt(0));const b=new Blob([bytes],{{type:"image/jpeg"}});document.getElementById("target").src=URL.createObjectURL(b);',
        "synthetic": 'setTimeout(()=>document.getElementById("target").dispatchEvent(new MouseEvent("contextmenu",{bubbles:true})),700);',
        "forged-page": 'let result="handler-not-visible";try{window.webkit.messageHandlers.spikeGesture.postMessage({eventType:"contextmenu"});result="handler-visible"}catch(e){}fetch("/__spike/page-probe",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({kind:"page-probe",result})});',
    }.get(case_id, "") if not frame else ""
    html = f'''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>html,body{{height:100%;margin:0}}body{{display:grid;place-items:center;background:#fff}}
img,video,.background,canvas{{display:block;width:240px;height:180px;object-fit:contain}}
.background{{background:#ddd url('/media/image-a.jpg') center/contain no-repeat}}
iframe{{display:block;width:260px;height:200px;border:0}}</style></head>
<body data-case="{case_id}">{target}<script>{setup}</script></body></html>'''
    if press_id:
        encoded_press_id = quote(press_id, safe="")
        fixture_url = re.compile(
            r"(?P<url>(?:https?://(?:127\.0\.0\.1|localhost):18755)?/"
            r"(?:case|frame|media)/[A-Za-z0-9._/-]+)"
        )
        html = fixture_url.sub(lambda match: f"{match.group('url')}?pressID={encoded_press_id}", html)
    return html.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "MediaVaultInlineMediaFixture/5"
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _send(self, status: int, content_type: str, data: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        press_id = parse_qs(urlsplit(self.path).query).get("pressID", [None])[0]
        if path == "/__spike/health":
            self._send(200, "application/json", b'{"healthy":true}')
            return
        if path == "/__spike/evidence":
            self._send(200, "application/json", json.dumps(EVIDENCE.export(), sort_keys=True).encode())
            return
        parts = path.strip("/").split("/")
        if len(parts) == 2 and parts[0] in ("case", "frame") and parts[1] in VALID_CASES:
            EVIDENCE.add_request(path, 200, press_id)
            self._send(
                200,
                "text/html; charset=utf-8",
                fixture_page(parts[1], frame=parts[0] == "frame", press_id=press_id),
            )
            return
        resources = {
            "/media/image-a.jpg": ("image/jpeg", IMAGE),
            "/media/image-b.jpg": ("image/jpeg", IMAGE),
            "/media/image-wide.jpg": ("image/jpeg", IMAGE),
            "/media/video-a.mp4": ("video/mp4", VIDEO),
        }
        if path in resources:
            content_type, data = resources[path]
            EVIDENCE.add_request(path, 200, press_id)
            self._send(200, content_type, data)
            return
        EVIDENCE.add_request(path, 404)
        self._send(404, "text/plain", b"fixture not found")

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        if path == "/__spike/reset":
            if not RECORDER_TOKEN or self.headers.get("X-Spike-Recorder-Token") != RECORDER_TOKEN:
                self._send(403, "application/json", b'{"error":"recorder-auth-required"}')
                return
            EVIDENCE.reset()
            self._send(200, "application/json", b"{}")
            return
        if path not in ("/__spike/event", "/__spike/page-probe"):
            self._send(404, "text/plain", b"fixture not found")
            return
        if path == "/__spike/event" and (
            not RECORDER_TOKEN or self.headers.get("X-Spike-Recorder-Token") != RECORDER_TOKEN
        ):
            self._send(403, "application/json", b'{"error":"recorder-auth-required"}')
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16_384:
                raise ValueError("invalid body length")
            event = json.loads(self.rfile.read(length))
            if not isinstance(event, dict) or not isinstance(event.get("kind"), str):
                raise ValueError("invalid event")
        except (ValueError, json.JSONDecodeError):
            self._send(400, "application/json", b'{"error":"malformed"}')
            return
        # The app emits a fixed, sanitized schema. Keep the recorder narrow even
        # when a page posts directly to the diagnostic-only probe endpoint.
        if path == "/__spike/page-probe":
            event = {"kind": "page-probe", "result": str(event.get("result", "unknown"))[:64]}
        EVIDENCE.add_event(event)
        self._send(200, "application/json", b"{}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
