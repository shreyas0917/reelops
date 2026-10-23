"""A fake ECS agent task-protection endpoint for tests (real HTTP on loopback)."""

import json
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeAgent:
    """Records PUT /task-protection/v1/state requests; `mode` picks the reply."""

    def __init__(self):
        self.requests = []  # (method, path, content_type, body dict)
        self.protected = False
        self.mode = "ok"  # "ok" | "http_error" | "failure"
        self.url = None


@contextmanager
def fake_agent():
    agent = FakeAgent()

    class Handler(BaseHTTPRequestHandler):
        def do_PUT(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            agent.requests.append((self.command, self.path, self.headers["Content-Type"], body))
            if agent.mode == "http_error":
                return self._reply(400, {"error": {"Code": "InvalidParameterException", "Message": "bad"}})
            if agent.mode == "failure":
                return self._reply(200, {"failure": {"Reason": "AccessDeniedException"}})
            agent.protected = body["ProtectionEnabled"]
            self._reply(200, {"protection": {"ProtectionEnabled": agent.protected}})

        def _reply(self, code, payload):
            data = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):  # keep test output quiet
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    agent.url = f"http://127.0.0.1:{server.server_address[1]}"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield agent
    finally:
        server.shutdown()
        server.server_close()
