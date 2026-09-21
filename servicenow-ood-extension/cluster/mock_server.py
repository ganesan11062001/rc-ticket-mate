#!/usr/bin/env python3
"""A stand-in for the real service, for testing the OOD reverse-proxy path.

Deliberately dependency-free (stdlib only) so it runs under the system python3
on any node, with no venv and no module loads.

Two design choices worth knowing:

* It answers **every** path with JSON. OOD's node proxy may or may not strip
  its own `/rnode/<host>/<port>` prefix before forwarding, and that differs
  between OOD versions and between the `/node/` and `/rnode/` routes. Matching
  on paths would make this test fail for a reason that has nothing to do with
  the pipeline, so it doesn't.

* It sends CORS headers and answers preflight. Strictly, the extension's
  service worker doesn't need them (host_permissions exempt it from CORS), but
  they let you test the same endpoint from a normal browser tab or a page's
  console, which is a much faster debugging loop.
"""

import argparse
import datetime
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def payload(port: int) -> dict:
    """Shaped like the eventual real response, so content.js can be tested."""
    now = datetime.datetime.now().astimezone()
    return {
        "ok": True,
        "source": "mock_server.py",
        "node": socket.gethostname(),
        "port": port,
        "slurm_job_id": os.environ.get("SLURM_JOB_ID", "not-in-a-slurm-job"),
        "served_at": now.isoformat(timespec="seconds"),
        "short_description": "[RC Copilot test] Pipeline reached the Slurm job",
        "draft_response": (
            "This text was generated on {host} (Slurm job {job}) at {when} and "
            "travelled back through the Open OnDemand proxy, the extension "
            "service worker, and into this form field.\n\n"
            "If you can read this in ServiceNow, the whole request path works "
            "and the only thing left to swap in is the real model."
        ).format(
            host=socket.gethostname(),
            job=os.environ.get("SLURM_JOB_ID", "n/a"),
            when=now.strftime("%Y-%m-%d %H:%M:%S %Z"),
        ),
        "work_notes": "Connectivity test via RC Copilot OOD pipeline. Safe to discard.",
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "RCCopilotMock/0.1"
    port_for_payload = 0

    def _cors_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Access-Control-Max-Age", "600")

    def _respond_json(self, body: dict, status: int = 200) -> None:
        raw = json.dumps(body, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self) -> None:  # noqa: N802 - stdlib naming
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self._cors_headers()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        self._respond_json(payload(self.port_for_payload))

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)  # drain, but ignore
        self._respond_json(payload(self.port_for_payload))

    def log_message(self, fmt: str, *args) -> None:
        sys.stdout.write(
            "[%s] %s - %s\n" % (self.log_date_time_string(), self.address_string(), fmt % args)
        )
        sys.stdout.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    # 0.0.0.0 is required: the OOD web node has to reach this from off-host.
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    Handler.port_for_payload = args.port
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("mock server listening on %s:%d" % (args.host, args.port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("shutting down", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
