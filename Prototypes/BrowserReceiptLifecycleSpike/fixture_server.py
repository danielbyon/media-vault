"""Independent loopback fixture for explicit GET receipt lifecycle experiments."""

import hashlib
import ipaddress
import json
import os
import struct
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT = 18756
SLOW_CHUNK_DELAY = float(os.environ.get("SPIKE6_SLOW_CHUNK_DELAY", "0.025"))
if not 0.025 <= SLOW_CHUNK_DELAY <= 0.2:
    raise ValueError("The fixed slow fixture delay must remain bounded")
_records = []
_lock = threading.Lock()


def _png() -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\x00" + bytes([40, 90, 170, 255]) * 16 for _ in range(16))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


STILL = _png()
SLOW = STILL + b"\x3a" * (8 * 1024 * 1024)


class Handler(BaseHTTPRequestHandler):
    """Records only fixed fixture paths, opaque IDs, counts, and digests."""

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/health":
            self._reply(b"ok", "text/plain")
            return
        if parsed.path == "/evidence":
            with _lock:
                body = json.dumps(list(_records), sort_keys=True).encode()
            self._reply(body, "application/json")
            return
        if parsed.path not in ("/media/still", "/media/slow", "/media/timeout"):
            self.send_error(404)
            return
        raw_id = parse_qs(parsed.query).get("transfer", [""])[0]
        try:
            transfer_id = str(uuid.UUID(raw_id))
        except ValueError:
            self.send_error(400)
            return
        if parsed.path == "/media/timeout":
            with _lock:
                _records.append(
                    {
                        "path": parsed.path,
                        "transfer_id": transfer_id,
                        "status": 0,
                        "bytes_sent": 0,
                        "source_bytes": 0,
                        "source_sha256": hashlib.sha256(b"").hexdigest(),
                        "complete": False,
                        "cookie_present": "Cookie" in self.headers,
                        "authorization_present": "Authorization" in self.headers,
                    }
                )
            time.sleep(35)
            return
        body = STILL if parsed.path == "/media/still" else SLOW
        self.send_response(200)
        self.send_header("Content-Type", "image/png" if parsed.path == "/media/still" else "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        sent = 0
        try:
            for offset in range(0, len(body), 16_384):
                chunk = body[offset : offset + 16_384]
                self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
                if parsed.path == "/media/slow":
                    time.sleep(SLOW_CHUNK_DELAY)
        except (BrokenPipeError, ConnectionResetError):
            pass
        with _lock:
            _records.append(
                {
                    "path": parsed.path,
                    "transfer_id": transfer_id,
                    "status": 200,
                    "bytes_sent": sent,
                    "source_bytes": len(body),
                    "source_sha256": hashlib.sha256(body).hexdigest(),
                    "complete": sent == len(body),
                    "cookie_present": "Cookie" in self.headers,
                    "authorization_present": "Authorization" in self.headers,
                }
            )

    def _reply(self, body: bytes, content_type: str):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    bind_host = os.environ.get("SPIKE6_BIND_HOST", "127.0.0.1")
    address = ipaddress.IPv4Address(bind_host)
    permitted = ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
    if not any(address in ipaddress.IPv4Network(network) for network in permitted):
        raise ValueError("The fixture binds only to a numeric local address")
    ThreadingHTTPServer((bind_host, PORT), Handler).serve_forever()
