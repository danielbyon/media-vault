#!/usr/bin/env python3
"""Independent, redacting HTTP/HTTPS fixture for the WKDownload spike."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import secrets
import socket
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit


HTTP_PORT = 18753
HTTPS_PORT = 18754
BASIC_USER = "spike-basic-user"
COOKIE_NAME = "spike_http_only"
SECURE_COOKIE_NAME = "spike_secure"
PAYLOAD = (b"browser-wkdownload-spike-v3\n" + bytes(range(256))) * 2048
SLOW_PAYLOAD = (bytes(range(256)) * 32768)
TEARDOWN_PAYLOAD = bytes(range(256)) * 131072
FIXTURE_DIRECTORY = Path(__file__).resolve().parent / "fixtures"
DIRECT_IMAGE = (FIXTURE_DIRECTORY / "direct-image.jpg").read_bytes()
DIRECT_VIDEO = (FIXTURE_DIRECTORY / "direct-video.mp4").read_bytes()


class EvidenceState:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.requests: list[dict[str, object]] = []
        self.app_events: list[dict[str, object]] = []
        self.transfer_events: list[dict[str, object]] = []
        self.single_use_tokens: dict[str, tuple[str, bool]] = {}
        self.valid_cookie_values: set[str] = set()
        self.valid_secure_cookie_values: set[str] = set()
        self.post_side_effect_count = 0
        self.next_request_id = 0

    def reset(self) -> None:
        with self.lock:
            self.requests.clear()
            self.app_events.clear()
            self.transfer_events.clear()
            self.single_use_tokens.clear()
            self.valid_cookie_values.clear()
            self.valid_secure_cookie_values.clear()
            self.post_side_effect_count = 0
            self.next_request_id = 0

    def request_id(self) -> int:
        with self.lock:
            self.next_request_id += 1
            return self.next_request_id

    def add_request(self, request: dict[str, object]) -> None:
        with self.lock:
            self.requests.append(request)

    def add_event(self, event: dict[str, object]) -> None:
        with self.lock:
            self.app_events.append(event)

    def add_transfer_event(self, event: dict[str, object]) -> None:
        with self.lock:
            self.transfer_events.append(event)

    def export(self) -> dict[str, object]:
        with self.lock:
            return {
                "schema_version": 1,
                "requests": list(self.requests),
                "app_events": list(self.app_events),
                "transfer_events": list(self.transfer_events),
                "post_side_effect_count": self.post_side_effect_count,
            }


STATE = EvidenceState()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_origin(value: str | None) -> str:
    if not value:
        return "absent"
    parts = urlsplit(value)
    if parts.scheme.lower() not in ("http", "https") or not parts.hostname:
        return "unparseable"
    scheme = parts.scheme.lower()
    host = parts.hostname.lower()
    if host.endswith("."):
        host = host[:-1]
    try:
        port = parts.port or (443 if scheme == "https" else 80)
    except ValueError:
        return "unparseable"
    return f"{scheme}://{host}:{port}"


def safe_referer(value: str | None) -> str:
    if not value:
        return "absent"
    origin = safe_origin(value)
    if origin in ("absent", "unparseable"):
        return origin
    parts = urlsplit(value)
    return origin + (parts.path or "/")


def cookie_fields(raw_cookie: str | None) -> tuple[list[str], list[str]]:
    names: list[str] = []
    values: list[str] = []
    if raw_cookie:
        for pair in raw_cookie.split(";"):
            name, separator, value = pair.strip().partition("=")
            if separator and name:
                names.append(name)
                values.append(value)
    return sorted(set(names)), values


def authorization_fields(raw_authorization: str | None) -> tuple[str, str]:
    if not raw_authorization:
        return "absent", "absent"
    scheme, _, encoded = raw_authorization.partition(" ")
    identity = "unavailable"
    if scheme.lower() == "basic":
        try:
            username = base64.b64decode(encoded, validate=True).decode("utf-8").partition(":")[0]
            identity = hashlib.sha256(username.encode("utf-8")).hexdigest()[:12]
        except (ValueError, UnicodeDecodeError):
            identity = "invalid-basic-value"
    return scheme.title(), identity


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], use_tls: bool) -> None:
        super().__init__(address, FixtureHandler)
        self.use_tls = use_tls


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MediaVaultBrowserSaveToVaultFixture/4"
    sys_version = ""

    def log_message(self, _format: str, *args: object) -> None:
        return

    def do_GET(self) -> None:
        self._handle()

    def do_POST(self) -> None:
        self._handle()

    def _handle(self) -> None:
        parsed = urlsplit(self.path)
        path = parsed.path
        query = parse_qs(parsed.query, keep_blank_values=True)
        if path == "/__spike/health":
            self._json(200, {"healthy": True, "fixture": "BrowserSaveToVaultSpike"})
            return
        if path == "/__spike/reset" and self.command == "POST":
            STATE.reset()
            self._empty(204)
            return
        if path == "/__spike/event" and self.command == "POST":
            self._accept_app_event()
            return
        if path == "/__spike/evidence":
            self._json(200, STATE.export())
            return

        body = self._read_body()
        status, headers, response_body, fixture_id, token_status = self._route(path, query, body)
        request_id = STATE.request_id()
        record = self._request_evidence(
            request_id=request_id,
            path=path,
            status=status,
            body=body,
            response_body=response_body,
            response_headers=headers,
            fixture_id=fixture_id,
            token_status=token_status,
        )
        STATE.add_request(record)
        if path.startswith("/resource/slow-"):
            self._send_slow(request_id, path, status, headers, response_body)
            return
        self._send(status, headers, response_body)

    def _read_body(self) -> bytes:
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 2_000_000)
        except ValueError:
            length = 0
        return self.rfile.read(length) if length else b""

    def _route(
        self,
        path: str,
        query: dict[str, list[str]],
        body: bytes,
    ) -> tuple[int, dict[str, str], bytes, str, str]:
        if path == "/":
            token_pre = secrets.token_urlsafe(24)
            token_response = secrets.token_urlsafe(24)
            with STATE.lock:
                STATE.single_use_tokens[token_pre] = ("/signed/pre-request", False)
                STATE.single_use_tokens[token_response] = ("/signed/response-triggered", False)
                cookie_value = None
                if query.get("login", [""])[0] in ("persistent", "ephemeral"):
                    cookie_value = secrets.token_urlsafe(18)
                    STATE.valid_cookie_values.add(cookie_value)
            page = self._menu(token_pre, token_response)
            headers = self._html_headers()
            if cookie_value is not None:
                headers["Set-Cookie"] = f"{COOKIE_NAME}={cookie_value}; Path=/; HttpOnly; SameSite=Lax"
            return 200, headers, page, "fixture-menu", "none"

        if path == "/normal":
            return 200, self._html_headers(), b"<html><body><h1>ordinary-visible-navigation</h1></body></html>", "ordinary-visible-navigation", "none"

        if path == "/control/attachment":
            return 200, self._attachment_headers(), PAYLOAD, "visible-webpage-attachment-control", "none"

        if path in ("/control/direct-image", "/resource/direct-image"):
            return 200, self._media_headers("image/jpeg"), DIRECT_IMAGE, "direct-still-image", "none"

        if path in ("/control/direct-video", "/resource/direct-video"):
            return 200, self._media_headers("video/mp4"), DIRECT_VIDEO, "direct-video", "none"

        if path == "/resource/truncated-video":
            return (
                200,
                self._media_headers("video/mp4"),
                b"\x00\x00\x00\x10ftypisom\x00\x00\x00\x00",
                "truncated-video-container",
                "none",
            )

        if path == "/resource/claimed-image":
            headers = self._media_headers("image/jpeg")
            headers["Content-Disposition"] = 'attachment; filename="../../suggested-name-is-untrusted.jpg"'
            return 200, headers, PAYLOAD, "claimed-image-with-invalid-bytes", "none"

        if path == "/resource/attachment":
            return 200, self._attachment_headers(untrusted=True), PAYLOAD, "companion-attachment", "none"

        if path == "/resource/same-origin-final":
            return 200, self._attachment_headers(), PAYLOAD, "same-origin-redirect-final", "none"

        if path == "/redirect/same-origin-hop-2":
            return 302, self._redirect_headers("/resource/same-origin-final"), b"", "same-origin-redirect-hop-2", "none"

        if path == "/redirect/same-origin":
            return 302, self._redirect_headers("/redirect/same-origin-hop-2"), b"", "same-origin-redirect-hop-1", "none"

        if path == "/redirect/cross-origin":
            location = f"http://127.0.0.1:{HTTP_PORT}/prohibited/cross-origin"
            return 302, self._redirect_headers(location), b"", "cross-origin-redirect", "none"

        if path == "/redirect/https-downgrade":
            location = f"http://127.0.0.1:{HTTP_PORT}/prohibited/https-downgrade"
            return 302, self._redirect_headers(location), b"", "https-downgrade-redirect", "none"

        if path.startswith("/prohibited/"):
            return 200, self._attachment_headers(), b"prohibited destination received a request", "prohibited-destination", "none"

        if path == "/post" and self.command == "POST":
            with STATE.lock:
                STATE.post_side_effect_count += 1
            return 200, self._attachment_headers(), PAYLOAD, "contained-single-post", "none"

        if path in ("/signed/pre-request", "/signed/response-triggered"):
            token = query.get("token", [""])[0]
            with STATE.lock:
                entry = STATE.single_use_tokens.get(token)
                if entry and entry[0] == path and not entry[1]:
                    STATE.single_use_tokens[token] = (entry[0], True)
                    if path == "/signed/pre-request":
                        return 200, self._media_headers("image/jpeg"), DIRECT_IMAGE, "signed-pre-request", "first-use"
                    return 200, self._attachment_headers(), PAYLOAD, path.removeprefix("/signed/"), "first-use"
            return 403, self._attachment_headers(), b"single-use fixture token rejected", "single-use-token-replay", "used-or-invalid"

        if path == "/cookie/resource":
            names, values = cookie_fields(self.headers.get("Cookie"))
            valid = COOKIE_NAME in names and any(value in STATE.valid_cookie_values for value in values)
            status = 200 if valid else 401
            return status, self._attachment_headers(), PAYLOAD if valid else b"missing automatic HttpOnly cookie", "http-only-cookie", "valid" if valid else "missing"

        if path == "/cookie/no-login":
            return 200, self._html_headers(), b"<html><body><h1>ephemeral profile without login</h1></body></html>", "cookie-profile-negative-control", "none"

        if path == "/secure/seed" and self._is_tls():
            with STATE.lock:
                cookie_value = secrets.token_urlsafe(18)
                STATE.valid_secure_cookie_values.add(cookie_value)
            page = b"<html><body><a id='secure-resource-link' href='/secure/resource'>secure cookie resource</a></body></html>"
            headers = self._html_headers()
            headers["Set-Cookie"] = f"{SECURE_COOKIE_NAME}={cookie_value}; Path=/; Secure; HttpOnly; SameSite=Lax"
            return 200, headers, page, "https-secure-cookie-seed", "none"

        if path == "/secure/resource":
            names, values = cookie_fields(self.headers.get("Cookie"))
            valid = self._is_tls() and SECURE_COOKIE_NAME in names and any(
                value in STATE.valid_secure_cookie_values for value in values
            )
            status = 200 if valid else 401
            body_value = PAYLOAD if valid else b"missing Secure cookie or HTTPS transport"
            return status, self._attachment_headers(), body_value, "secure-cookie", "valid" if valid else "missing"

        if path == "/basic/resource":
            scheme, username_hash = authorization_fields(self.headers.get("Authorization"))
            valid = False
            raw = self.headers.get("Authorization", "")
            if raw.lower().startswith("basic "):
                try:
                    credentials = base64.b64decode(raw.split(" ", 1)[1], validate=True).decode("utf-8")
                    username, separator, password = credentials.partition(":")
                    valid = bool(separator and password) and username == BASIC_USER
                except (ValueError, UnicodeDecodeError):
                    valid = False
            status = 200 if valid else 401
            headers = self._attachment_headers()
            if not valid:
                headers["WWW-Authenticate"] = 'Basic realm="wkdownload-fixture"'
                body_value = b"Basic authentication challenge"
            else:
                body_value = PAYLOAD
            return status, headers, body_value, "basic-authentication", f"{scheme}:{username_hash}"

        if path.startswith("/resource/slow-"):
            slow_payload = TEARDOWN_PAYLOAD if path in (
                "/resource/slow-ephemeral-teardown",
                "/resource/slow-persistent-survivor",
            ) else SLOW_PAYLOAD
            start = 0
            range_header = self.headers.get("Range", "")
            match = re.fullmatch(r"bytes=(\d+)-", range_header)
            if match:
                start = min(int(match.group(1)), len(slow_payload))
            status = 206 if start else 200
            headers = self._attachment_headers()
            headers["Accept-Ranges"] = "bytes"
            headers["ETag"] = '"wkdownload-spike-slow-v1"'
            if start:
                headers["Content-Range"] = f"bytes {start}-{len(slow_payload) - 1}/{len(slow_payload)}"
            return status, headers, slow_payload[start:], path.removeprefix("/resource/"), "range" if start else "none"

        return 404, self._attachment_headers(), b"unknown fixture path", "unknown", "none"

    def _request_evidence(
        self,
        request_id: int,
        path: str,
        status: int,
        body: bytes,
        response_body: bytes,
        response_headers: dict[str, str],
        fixture_id: str,
        token_status: str,
    ) -> dict[str, object]:
        cookie_names, cookie_values = cookie_fields(self.headers.get("Cookie"))
        authorization_scheme, auth_identity = authorization_fields(self.headers.get("Authorization"))
        user_agent = self.headers.get("User-Agent")
        referer = self.headers.get("Referer")
        origin = self.headers.get("Origin")
        query = urlsplit(self.path).query
        query_keys = sorted(parse_qs(query, keep_blank_values=True).keys())
        range_header = self.headers.get("Range", "")
        if path == "/cookie/resource":
            cookie_auth_valid = any(value in STATE.valid_cookie_values for value in cookie_values)
        elif path == "/secure/resource":
            cookie_auth_valid = any(value in STATE.valid_secure_cookie_values for value in cookie_values)
        else:
            cookie_auth_valid = None
        if path == "/post":
            with STATE.lock:
                post_count = STATE.post_side_effect_count
        else:
            post_count = None
        return {
            "request_id": request_id,
            "timestamp": time.time(),
            "host": (self.headers.get("Host", "").split(":", 1)[0]).lower().removesuffix("."),
            "path": path,
            "method": self.command,
            "status": status,
            "fixture_id": fixture_id,
            "query_keys": query_keys,
            "body_length": len(body),
            "body_sha256": digest(body),
            "response_bytes": len(response_body),
            "response_sha256": digest(response_body),
            "response_content_type": response_headers.get("Content-Type", "absent"),
            "cookie_names": cookie_names,
            "cookie_auth_valid": cookie_auth_valid,
            "authorization_scheme": authorization_scheme,
            "authentication_identity_sha256_prefix": auth_identity,
            "referer_present": bool(referer),
            "referer_sanitized": safe_referer(referer),
            "origin_present": bool(origin),
            "origin_sanitized": safe_origin(origin),
            "user_agent_present": bool(user_agent),
            "user_agent_sha256": digest(user_agent.encode("utf-8")) if user_agent else "absent",
            "range_present": bool(range_header),
            "range_start": re.match(r"bytes=(\d+)-", range_header).group(1) if re.match(r"bytes=(\d+)-", range_header) else "none",
            "query_values_recorded": False,
            "credential_values_recorded": False,
            "cookie_values_recorded": False,
            "request_body_recorded": False,
            "single_use_token_state": token_status,
            "post_side_effect_count": post_count,
        }

    def _accept_app_event(self) -> None:
        body = self._read_body()
        try:
            event = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._empty(400)
            return
        allowed = {"kind", "timestamp", "profile_id", "profile", "operation_id", "fields"}
        sanitized = {key: event[key] for key in allowed if key in event}
        fields = sanitized.get("fields")
        if isinstance(fields, dict):
            sanitized["fields"] = {
                str(key): value
                for key, value in fields.items()
                if isinstance(value, (str, int, float, bool))
                and not any(secret in str(key).lower() for secret in ("password", "credential_value", "cookie_value", "signed_url"))
            }
        STATE.add_event(sanitized)
        self._empty(204)

    def _send_slow(
        self,
        request_id: int,
        path: str,
        status: int,
        headers: dict[str, str],
        body: bytes,
    ) -> None:
        headers = dict(headers)
        headers["Content-Length"] = str(len(body))
        headers["Connection"] = "close"
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        sent = 0
        completed = False
        try:
            chunk_size = 64 * 1024
            for offset in range(0, len(body), chunk_size):
                chunk = body[offset : offset + chunk_size]
                self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
                time.sleep(0.018)
            completed = True
        except (BrokenPipeError, ConnectionResetError, socket.timeout, OSError):
            completed = False
        finally:
            STATE.add_transfer_event(
                {
                    "kind": "fixture-transfer-body-finished",
                    "request_id": request_id,
                    "timestamp": time.time(),
                    "path": path,
                    "bytes_sent": sent,
                    "expected_bytes": len(body),
                    "expected_full_sha256": digest(body),
                    "body_complete": completed,
                    "response_sha256": digest(body) if completed else "not-complete",
                }
            )
            self.close_connection = True

    def _menu(self, token_pre: str, token_response: str) -> bytes:
        def save_link(identifier: str, label: str, target: str, method: str = "GET") -> str:
            escaped_target = quote(target, safe="")
            return (
                f'<a id="{identifier}" href="vault-save://intent?target={escaped_target}'
                f'&amp;case={identifier}&amp;method={method}">{label}</a>'
            )

        html = f"""<!doctype html><html><head><meta name="viewport" content="width=device-width">
        <style>body {{ font: 18px sans-serif; }} a {{ display: block; margin: 12px 0; }}</style></head><body>
        <h1>Browser Save to Vault Spike 4</h1>
        <a id="ordinary-navigation" href="/normal">ordinary navigation</a>
        <a id="login-persistent" href="/?login=persistent">log in to the HttpOnly fixture</a>
        <a id="open-direct-image" href="/resource/direct-image">display direct still image</a>
        <a id="open-direct-video" href="/resource/direct-video">display direct video</a>
        <a id="open-cookie-resource" href="/cookie/resource">open logged-in media in this browser</a>
        <a id="open-ephemeral-negative" href="/cookie/no-login">open logged-out ephemeral page</a>
        {save_link("save-link-still", "Save linked still to Vault", "/resource/direct-image")}
        {save_link("save-video", "Save linked video to Vault", "/resource/direct-video")}
        {save_link("save-truncated-video", "Reject truncated video container", "/resource/truncated-video")}
        {save_link("save-signed-still", "Save one-use still to Vault", f"/signed/pre-request?token={token_pre}")}
        {save_link("save-same-origin", "Save through same-origin redirects", "/redirect/same-origin")}
        {save_link("save-cross-origin", "Probe cross-origin redirect", f"http://localhost:{HTTP_PORT}/redirect/cross-origin")}
        {save_link("save-https-downgrade", "Probe HTTPS downgrade", f"https://127.0.0.1:{HTTPS_PORT}/redirect/https-downgrade")}
        {save_link("save-cookie-media", "Save logged-in media to Vault", "/cookie/resource")}
        {save_link("save-non-media", "Save unsupported binary to Vault", "/resource/attachment")}
        {save_link("save-claimed-image", "Save invalid claimed image to Vault", "/resource/claimed-image")}
        {save_link("save-missing", "Save missing resource to Vault", "/missing")}
        {save_link("save-slow-cancel", "Start cancellable transfer", "/resource/slow-cancel")}
        {save_link("reject-post", "Reject POST acquisition", "/post", method="POST")}
        {save_link("reject-blob", "Reject blob URL", "blob:https://fixture.invalid/spike4")}
        {save_link("reject-data", "Reject data URL", "data:text/plain,spike4")}
        </body></html>"""
        return html.encode("utf-8")

    @staticmethod
    def _html_headers() -> dict[str, str]:
        return {
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "0",
            "Cache-Control": "no-store",
            "Connection": "close",
        }

    @staticmethod
    def _attachment_headers(untrusted: bool = False) -> dict[str, str]:
        filename = "../../suggested-name-is-untrusted.bin" if untrusted else "fixture.bin"
        return {
            "Content-Type": "application/octet-stream",
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Content-Length": "0",
            "Cache-Control": "no-store",
            "Connection": "close",
        }

    @staticmethod
    def _media_headers(content_type: str) -> dict[str, str]:
        return {
            "Content-Type": content_type,
            "Cache-Control": "no-store",
            "Connection": "close",
        }

    @staticmethod
    def _redirect_headers(location: str) -> dict[str, str]:
        return {"Location": location, "Content-Length": "0", "Cache-Control": "no-store", "Connection": "close"}

    def _is_tls(self) -> bool:
        return bool(getattr(self.server, "use_tls", False))

    def _send(self, status: int, headers: dict[str, str], body: bytes) -> None:
        updated = dict(headers)
        updated["Content-Length"] = str(len(body))
        self.send_response(status)
        for name, value in updated.items():
            self.send_header(name, value)
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    def _empty(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def _json(self, status: int, value: object) -> None:
        data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--private-key", required=True)
    parser.add_argument("--http-port", type=int, default=HTTP_PORT)
    parser.add_argument("--https-port", type=int, default=HTTPS_PORT)
    args = parser.parse_args()

    http_server = FixtureServer(("127.0.0.1", args.http_port), use_tls=False)
    https_server = FixtureServer(("127.0.0.1", args.https_port), use_tls=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.certificate, args.private_key)
    https_server.socket = context.wrap_socket(https_server.socket, server_side=True)

    threads = [
        threading.Thread(target=http_server.serve_forever, name="fixture-http", daemon=True),
        threading.Thread(target=https_server.serve_forever, name="fixture-https", daemon=True),
    ]
    for thread in threads:
        thread.start()
    print(json.dumps({"ready": True, "http_port": args.http_port, "https_port": args.https_port}), flush=True)
    try:
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        pass
    finally:
        http_server.shutdown()
        https_server.shutdown()
        http_server.server_close()
        https_server.server_close()


if __name__ == "__main__":
    main()
