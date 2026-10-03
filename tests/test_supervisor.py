import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROUTER_TOKEN = "a" * 64
BACKEND_TOKEN = "b" * 64


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def backend_handler(name, slow_started, slow_release):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            return

        def do_POST(self):
            if self.headers.get("X-Bridge-Backend-Token") != BACKEND_TOKEN:
                return self.reply(403, {"error": "forbidden"})
            length = int(self.headers.get("Content-Length", "0"))
            if length:
                self.rfile.read(length)
            if self.path == "/slow":
                slow_started.set()
                if not slow_release.wait(10):
                    return self.reply(504, {"error": "test-timeout"})
            self.reply(200, {"backend": name, "path": self.path})

        def reply(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


class SupervisorIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="WindowsBridge-test-"))
        self.root = self.temp / "root with ünicode"
        (self.root / "state").mkdir(parents=True)
        (self.root / "secrets").mkdir()
        (self.root / "secrets" / "router_token").write_text(ROUTER_TOKEN, encoding="utf-8")
        (self.root / "secrets" / "backend_token").write_text(BACKEND_TOKEN, encoding="utf-8")

        self.old_started = threading.Event()
        self.old_release = threading.Event()
        self.new_started = threading.Event()
        self.new_release = threading.Event()
        self.old_port = free_port()
        self.new_port = free_port()
        self.router_port = free_port()

        self.old_server = ThreadingHTTPServer(
            ("127.0.0.1", self.old_port),
            backend_handler("old", self.old_started, self.old_release),
        )
        self.new_server = ThreadingHTTPServer(
            ("127.0.0.1", self.new_port),
            backend_handler("new", self.new_started, self.new_release),
        )
        self.old_server.daemon_threads = True
        self.new_server.daemon_threads = True
        threading.Thread(target=self.old_server.serve_forever, daemon=True).start()
        threading.Thread(target=self.new_server.serve_forever, daemon=True).start()

        self.write_route("old-generation", self.old_port)
        env = os.environ.copy()
        env["WINDOWSBRIDGE_ROOT"] = str(self.root)
        env["WINDOWSBRIDGE_SUPERVISOR_PORT"] = str(self.router_port)
        supervisor = Path(__file__).resolve().parents[1] / "supervisor.py"
        self.process = subprocess.Popen(
            [sys.executable, str(supervisor)],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.wait_ready()

    def tearDown(self):
        self.old_release.set()
        self.new_release.set()
        self.old_server.shutdown()
        self.new_server.shutdown()
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        shutil.rmtree(self.temp, ignore_errors=True)

    def write_route(self, generation, port):
        target = self.root / "state" / "route.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(
            json.dumps({"generation": generation, "port": port}),
            encoding="utf-8",
        )
        os.replace(temporary, target)

    def call(self, path, token=ROUTER_TOKEN, method="POST"):
        body = b"{}" if method == "POST" else None
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.router_port}{path}",
            data=body,
            method=method,
            headers={"X-Bridge-Token": token, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read())

    def wait_ready(self):
        deadline = time.time() + 10
        while time.time() < deadline:
            if self.process.poll() is not None:
                stderr = self.process.stderr.read()
                self.fail(f"supervisor exited early: {stderr}")
            try:
                status, payload = self.call("/__bridge/healthz", method="GET")
                if status == 200 and payload["ok"]:
                    return
            except (OSError, urllib.error.URLError):
                time.sleep(0.05)
        self.fail("supervisor did not become ready")

    def test_atomic_switch_drains_old_request_without_restarting_supervisor(self):
        with self.assertRaises(urllib.error.HTTPError) as denied:
            self.call("/fast", token="wrong-token")
        self.assertEqual(denied.exception.code, 403)

        result = {}
        old_request = threading.Thread(
            target=lambda: result.update(response=self.call("/slow")[1]),
            daemon=True,
        )
        old_request.start()
        self.assertTrue(self.old_started.wait(5), "old request did not start")

        _, before = self.call("/__bridge/status", method="GET")
        supervisor_pid = before["pid"]
        self.assertEqual(before["active_generation"], "old-generation")
        self.assertEqual(before["inflight"]["old-generation"], 1)

        self.write_route("new-generation", self.new_port)
        _, new_response = self.call("/fast")
        self.assertEqual(new_response["backend"], "new")

        _, switched = self.call("/__bridge/status", method="GET")
        self.assertEqual(switched["pid"], supervisor_pid)
        self.assertEqual(switched["active_generation"], "new-generation")
        self.assertEqual(switched["inflight"]["old-generation"], 1)

        self.old_release.set()
        old_request.join(5)
        self.assertFalse(old_request.is_alive(), "old request did not drain")
        self.assertEqual(result["response"]["backend"], "old")

        deadline = time.time() + 5
        while time.time() < deadline:
            _, drained = self.call("/__bridge/status", method="GET")
            if drained["inflight"].get("old-generation") == 0:
                break
            time.sleep(0.05)
        self.assertEqual(drained["inflight"]["old-generation"], 0)
        self.assertEqual(drained["pid"], supervisor_pid)
        self.assertIsNone(self.process.poll())

    def test_failed_candidate_route_can_be_restored(self):
        unavailable_port = free_port()
        self.write_route("failed-candidate", unavailable_port)
        with self.assertRaises(urllib.error.HTTPError) as failed:
            self.call("/fast")
        self.assertEqual(failed.exception.code, 502)

        self.write_route("old-generation", self.old_port)
        _, restored = self.call("/fast")
        self.assertEqual(restored["backend"], "old")
        self.assertIsNone(self.process.poll())


if __name__ == "__main__":
    unittest.main()
