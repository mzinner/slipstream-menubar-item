#!/usr/bin/env python3
"""A stand-in Slipstream server for testing the menu bar app without a model.

Serves /health, /ready, /status and /metrics the way the real server does, with
rising token counters, so the panel's charts move. Options stage the cases that
are hard to produce on demand:

  --outage 20 35   every endpoint answers 503 from 20 s to 35 s after start (gaps)
  --busy           /ready always answers 503, as a saturated real server does
  --served 42      requests_submitted_total, so a busy server reads as loaded

To have the app treat it as a running Slipstream server, it must be found through
a serve.lock whose pid runs a script ending in server/server.py. --lock-repo does
that: it copies this script to <repo>/server/server.py, re-executes it from there
and writes <repo>/build/runtime/serve.lock. Point a test instance of the app at
that repo through a config file:

  scripts/fake-server.py --port 18090 --lock-repo /tmp/fakerepo --busy --served 42 &
  echo '{"repoPath":"/tmp/fakerepo","model":"/fake/model","port":18090}' > /tmp/fake.json
  SLIPSTREAM_MENUBAR_CONFIG=/tmp/fake.json .build/release/SlipstreamMenubar --snapshot /tmp/p.png
"""

import argparse
import http.server
import json
import os
import random
import shutil
import sys
import time
from pathlib import Path

FIXTURE = Path(__file__).resolve().parents[1] / "Tests/SlipstreamMenubarCoreTests/Fixtures/metrics.txt"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=18090)
    parser.add_argument("--outage", type=float, nargs=2, metavar=("START", "END"),
                        help="answer 503 everywhere between these seconds after start")
    parser.add_argument("--busy", action="store_true", help="/ready always answers 503")
    parser.add_argument("--served", type=int, default=0, help="requests_submitted_total to report")
    parser.add_argument("--lock-repo", type=Path, help="pose as <repo>/server/server.py with a serve.lock")
    parser.add_argument("--fixture", type=Path, default=FIXTURE, help="a /metrics capture to serve")
    args = parser.parse_args()

    if args.lock_repo:
        script = args.lock_repo / "server/server.py"
        if Path(sys.argv[0]).resolve() != script.resolve():
            script.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(__file__, script)
            # The copy cannot find the fixture relative to itself, so pass its path on.
            os.execv(sys.executable, [sys.executable, str(script), *sys.argv[1:],
                                      "--fixture", str(args.fixture.resolve())])
        lock = args.lock_repo / "build/runtime/serve.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text(json.dumps({"pid": os.getpid(), "model": "/fake/model",
                                    "port": args.port, "host": "127.0.0.1"}))

    fixture = args.fixture.read_text()
    start = time.time()
    state = {"output": 0.0, "prompt": 0.0, "last": start}

    def down():
        return bool(args.outage) and args.outage[0] <= time.time() - start < args.outage[1]

    def metrics(now):
        replacements = {
            "slipstream_v2_decode_output_tokens_total": f"{state['output']:.0f}",
            "slipstream_v2_prefill_input_tokens_total": f"{state['prompt']:.0f}",
            "slipstream_v2_kv_pages_cache": str(int((now - start) * 3)),
            "slipstream_v2_scheduler_decoding": "1",
            "slipstream_v2_requests_submitted_total": str(args.served),
        }
        lines = []
        for line in fixture.splitlines():
            name = line.split(" ", 1)[0]
            lines.append(f"{name} {replacements[name]}" if name in replacements else line)
        return "\n".join(lines) + "\n"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, status, body=b"", content_type="application/json"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            now = time.time()
            elapsed, state["last"] = now - state["last"], now
            state["output"] += elapsed * random.uniform(30, 45)  # about the real decode rate
            state["prompt"] += elapsed * random.uniform(0, 300)
            if down():
                return self.send(503, b'{"status":"unavailable"}')
            if self.path == "/health":
                return self.send(200, b'{"status":"ok"}')
            if self.path == "/ready":
                return self.send(503 if args.busy else 200,
                                 b'{"status":"unavailable"}' if args.busy else b'{"status":"ready"}')
            if self.path == "/metrics":
                return self.send(200, metrics(now).encode(), "text/plain; version=0.0.4")
            if self.path == "/status":
                return self.send(200, b'{"maximum_context_tokens": 262144, "kv": {"block_tokens": 32}}')
            self.send(404, b'{"error":"not found"}')

    print(f"fake Slipstream server on 127.0.0.1:{args.port} (pid {os.getpid()})", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
