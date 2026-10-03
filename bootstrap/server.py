from __future__ import annotations

import hashlib
import json
import os
import re
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

VERSION = "0.2.0"
ROOT = Path(os.getenv("WB_BOOTSTRAP_ROOT", "/var/lib/windowsbridge-bootstrap"))
PUBLIC_BASE = os.getenv("WB_BOOTSTRAP_PUBLIC_BASE", "https://windowsbridge.sonoryx.store").rstrip("/")
SOURCE_REF = os.getenv("WB_BOOTSTRAP_SOURCE_REF", "main")
LISTEN_HOST = os.getenv("WB_BOOTSTRAP_HOST", "172.18.0.1")
LISTEN_PORT = int(os.getenv("WB_BOOTSTRAP_PORT", "8792"))
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,128}$")


def bundle_path(token: str) -> Path:
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    return ROOT / "bundles" / f"{digest}.json"


class Handler(BaseHTTPRequestHandler):
    server_version = f"WindowsBridgeBootstrap/{VERSION}"

    def log_message(self, fmt: str, *args) -> None:
        # Do not log request paths: bootstrap URLs contain one-time bearer tokens.
        print(f"{self.address_string()} {fmt % args[:1] if args else fmt}")

    def send_json(self, status: int, payload: dict) -> None:
        raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def send_text(self, status: int, text: str) -> None:
        raw = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/healthz":
            self.send_json(HTTPStatus.OK, {"ok": True, "version": VERSION})
            return

        parts = [x for x in path.split("/") if x]
        if len(parts) != 2 or parts[0] not in {"i", "b"}:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        token = parts[1]
        if not TOKEN_RE.fullmatch(token):
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        source = bundle_path(token)
        if not source.exists():
            self.send_json(HTTPStatus.GONE, {"error": "expired_or_used"})
            return

        if parts[0] == "i":
            install_url = f"https://raw.githubusercontent.com/ZTD38F/WindowsBridge/{SOURCE_REF}/install.ps1"
            bootstrap_url = f"{PUBLIC_BASE}/b/{token}"
            script = (
                "$ErrorActionPreference='Stop';"
                f"$p=Join-Path $env:TEMP 'WindowsBridge-install.ps1';"
                f"Invoke-WebRequest -UseBasicParsing '{install_url}' -OutFile $p;"
                f"& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -BootstrapUrl '{bootstrap_url}' -SourceRef '{SOURCE_REF}';"
                "$c=$LASTEXITCODE;Remove-Item $p -Force -ErrorAction SilentlyContinue;exit $c"
            )
            self.send_text(HTTPStatus.OK, script)
            return

        used = source.with_suffix(f".used-{os.getpid()}-{time.time_ns()}")
        try:
            os.replace(source, used)
        except FileNotFoundError:
            self.send_json(HTTPStatus.GONE, {"error": "expired_or_used"})
            return

        try:
            payload = json.loads(used.read_text(encoding="utf-8"))
            if int(payload.get("expires_at", 0)) < int(time.time()):
                self.send_json(HTTPStatus.GONE, {"error": "expired"})
                return
            required = {"tunnel_id", "runtime_api_key"}
            if not required.issubset(payload):
                self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "invalid_bundle"})
                return
            self.send_json(
                HTTPStatus.OK,
                {
                    "tunnel_id": payload["tunnel_id"],
                    "runtime_api_key": payload["runtime_api_key"],
                    "source_ref": payload.get("source_ref", SOURCE_REF),
                },
            )
        finally:
            try:
                used.unlink()
            except FileNotFoundError:
                pass


def main() -> None:
    (ROOT / "bundles").mkdir(parents=True, exist_ok=True)
    os.chmod(ROOT / "bundles", 0o700)
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"WindowsBridge bootstrap listening on {LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
