"""Isolated E2E stack: throwaway PostgreSQL database, real backend, static web bundle.

Never touches the developer stack (backend :8080, database `sitepulse`):
- the database is `sitepulse_e2e_<pid>`, created and dropped here;
- the backend listens on E2E_API_PORT (8180) and gets test-only secrets;
- the web bundle is served from flutter/build/web-e2e on E2E_WEB_PORT (9190).

PostgreSQL access reuses scripts/api_system_check.py (DB_USER/DB_PASS/DB_HOST/
DB_PORT; `psql` on PATH or `docker exec <container> psql`).
"""
from __future__ import annotations

import functools
import http.server
import os
import subprocess
import sys
import threading
from pathlib import Path

SITEPULSE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SITEPULSE / "scripts"))

import api_system_check as asc  # noqa: E402

E2E_API_PORT = int(os.environ.get("E2E_API_PORT", "8180"))
E2E_WEB_PORT = int(os.environ.get("E2E_WEB_PORT", "9190"))
WEB_BUILD = SITEPULSE / "flutter" / "build" / "web-e2e"
FLUTTER = Path(os.environ.get("FLUTTER_ROOT", str(Path.home() / "flutter"))) / "bin" / "flutter"

# Test-only values; they exist only inside the throwaway stack.
SAAS_ADMIN_EMAIL = "admin@sitepulse.io"
SAAS_ADMIN_PASSWORD = "E2E-Bootstrap-Admin-1"
WEBHOOK_SECRET = "gui-e2e-webhook-secret"
JWT_SECRET = "gui-e2e-jwt-secret-0123456789abcdef0123"

# Tables are emptied between modules; schema bookkeeping is kept.
KEEP_TABLES = {"schema_migrations", "refinery_schema_history", "_sqlx_migrations"}

SetupError = asc.SetupError


def api_base() -> str:
    return f"http://localhost:{E2E_API_PORT}"


def web_base() -> str:
    return f"http://localhost:{E2E_WEB_PORT}"


def build_web(force: bool = False) -> None:
    """Build the E2E web bundle (semantics on, API pointed at the E2E backend)."""
    if WEB_BUILD.joinpath("main.dart.js").exists() and not force:
        return
    proc = subprocess.run(
        [str(FLUTTER), "build", "web", "--dart-define=E2E=true",
         f"--dart-define=SITEPULSE_API_BASE_URL={api_base()}", "--output", str(WEB_BUILD)],
        cwd=SITEPULSE / "flutter", capture_output=True, text=True)
    if proc.returncode != 0:
        raise SetupError("flutter build web failed:\n" + proc.stdout[-2000:] + proc.stderr[-2000:])


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args) -> None:  # keep test output readable
        pass


class WebServer:
    def __init__(self, port: int = E2E_WEB_PORT, root: Path = WEB_BUILD):
        handler = functools.partial(_QuietHandler, directory=str(root))
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


class E2EStack:
    def __init__(self, log_dir: Path, container: str = "sitepulse-postgres", keep_db: bool = False):
        self.log_dir = log_dir
        self.keep_db = keep_db
        self.psql = asc.Psql(container)
        self.db_name = f"sitepulse_e2e_{os.getpid()}"
        self.backend = asc.Backend(
            self.db_name, E2E_API_PORT, log_dir, profile="release", log_prefix="gui_e2e_backend",
            extra_env={
                "SITEPULSE_JWT_SECRET": JWT_SECRET,
                "SITEPULSE_BANK_WEBHOOK_SECRET": WEBHOOK_SECRET,
                "SITEPULSE_BOOTSTRAP_ADMIN_EMAIL": SAAS_ADMIN_EMAIL,
                "SITEPULSE_BOOTSTRAP_ADMIN_PASSWORD": SAAS_ADMIN_PASSWORD,
                "SITEPULSE_ENABLE_DEV_ROUTES": "false",
                "SITEPULSE_SEED_TEST_DATA": "false",
            })
        self.web = WebServer()

    # -- lifecycle -------------------------------------------------------
    def start(self) -> None:
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.psql.run("postgres", f"DROP DATABASE IF EXISTS {self.db_name};")
        self.psql.run("postgres", f"CREATE DATABASE {self.db_name};")
        self.backend.start()        # applies migrations + system seed
        self.reset()
        self.web.start()

    def stop(self) -> None:
        try:
            self.web.stop()
        finally:
            self.backend.stop()
            if not self.keep_db:
                self.psql.run("postgres", f"DROP DATABASE IF EXISTS {self.db_name};")

    def reset(self) -> None:
        """Empty every data table, re-apply system + test seed, restart the backend.

        The backend keeps state in memory and loads it at boot, so a restart
        is what makes the reset visible to the UI.
        """
        self.backend.stop()
        tables = [t for t in self.sql(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1;").split("\n")
            if t and t not in KEEP_TABLES]
        if tables:
            self.sql(f"TRUNCATE {', '.join(tables)} RESTART IDENTITY CASCADE;")
        seed_dir = SITEPULSE / "backend" / "db" / "seed"
        self.sql((seed_dir / "01-system-seed.sql").read_text(encoding="utf-8"))
        self.sql((seed_dir / "02-test-seed.sql").read_text(encoding="utf-8"))
        self.backend.start()

    def restart_backend(self) -> None:
        """Reload backend memory after an Arrange step wrote SQL directly."""
        self.backend.restart()

    # -- helpers -----------------------------------------------------------
    def sql(self, statement: str) -> str:
        return self.psql.run(self.db_name, statement)

    def wait_sql(self, statement: str, expected: str, timeout_s: float = 10.0) -> str:
        """Poll a query until it returns `expected` (UI actions persist asynchronously); returns the last value."""
        import time
        deadline = time.monotonic() + timeout_s
        value = self.sql(statement)
        while value != expected and time.monotonic() < deadline:
            time.sleep(0.3)
            value = self.sql(statement)
        return value
