#!/usr/bin/env python3
"""Run Cucumber.js suite against an isolated SitePulse E2E stack with reset support."""
from __future__ import annotations

import http.server
import os
from pathlib import Path
import subprocess
import sys
import threading

CUCUMBER_DIR = Path(__file__).resolve().parents[1]
SITEPULSE = CUCUMBER_DIR.parent
E2E_DIR = SITEPULSE / "e2e"

sys.path.insert(0, str(E2E_DIR))
from support import stack as st  # noqa: E402


class ResetHandler(http.server.BaseHTTPRequestHandler):
    stack_ref: st.E2EStack | None = None

    def do_POST(self):
        if self.path == "/reset":
            try:
                if self.stack_ref:
                    self.stack_ref.reset()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"OK\n")
            except Exception as e:
                self.send_response(500)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(f"ERR: {e}\n".encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Quiet reset handler logging
        pass


def main() -> int:
    os.environ.setdefault("DB_PASS", "sitepulse_secret")
    os.environ.setdefault("DB_USER", "sitepulse_user")
    os.environ.setdefault("DB_HOST", "127.0.0.1")
    os.environ.setdefault("DB_PORT", "5432")

    artifacts = E2E_DIR / ".artifacts"
    artifacts.mkdir(parents=True, exist_ok=True)
    stack = st.E2EStack(artifacts / "logs")
    ResetHandler.stack_ref = stack

    import shutil
    serenity_target = CUCUMBER_DIR / "target" / "site" / "serenity"
    if serenity_target.exists():
        shutil.rmtree(serenity_target)

    reset_server = http.server.ThreadingHTTPServer(("127.0.0.1", 8189), ResetHandler)
    server_thread = threading.Thread(target=reset_server.serve_forever, daemon=True)

    print("[run_pilot] Starting SitePulse E2E stack (Postgres + Backend :8180 + Web :9190)...")
    stack.start()
    server_thread.start()
    print(f"[run_pilot] E2E stack ready. DB={stack.db_name}. Reset server at 127.0.0.1:8189")

    cmd = sys.argv[1:] if len(sys.argv) > 1 else ["npm", "test"]
    env = {
        **os.environ,
        "E2E_API_PORT": "8180",
        "E2E_WEB_PORT": "9190",
        "DB_NAME": stack.db_name,
        "E2E_DB_NAME": stack.db_name,
        "DB_PASS": os.environ["DB_PASS"],
        "DB_USER": os.environ["DB_USER"],
        "DB_HOST": os.environ["DB_HOST"],
        "DB_PORT": os.environ["DB_PORT"],
    }

    try:
        print(f"[run_pilot] Executing: {' '.join(cmd)}")
        proc = subprocess.run(cmd, cwd=CUCUMBER_DIR, env=env)
        serenity_cli = CUCUMBER_DIR / "node_modules" / ".bin" / "serenity-bdd"
        serenity_target = CUCUMBER_DIR / "target" / "site" / "serenity"
        if serenity_cli.exists() and serenity_target.exists():
            print("[run_pilot] Generating Serenity BDD HTML living documentation report...")
            subprocess.run([str(serenity_cli), "run", "--features", "../.specify/features"], cwd=CUCUMBER_DIR)
        return proc.returncode
    finally:
        print("[run_pilot] Stopping E2E stack...")
        reset_server.shutdown()
        stack.stop()
        print("[run_pilot] Cleaned up.")


if __name__ == "__main__":
    sys.exit(main())
