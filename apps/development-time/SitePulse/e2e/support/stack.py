"""Isolated E2E stack: throwaway PostgreSQL database, real backend, static web bundle.

Never touches the developer stack (backend :8080, database `sitepulse`):
- the database is `sitepulse_e2e_<pid>`, created and dropped here;
- the backend listens on E2E_API_PORT (8180) and gets test-only secrets;
- the web bundle is served on E2E_WEB_PORT (9190).

CI provides both the backend and the web bundle in SITEPULSE_E2E_PREBUILT_DIR.
Local runs build the backend with Cargo and the web bundle in flutter/build/web-e2e.

PostgreSQL access reuses scripts/api_system_check.py (DB_USER/DB_PASS/DB_HOST/
DB_PORT; `psql` on PATH or `docker exec <container> psql`).
"""
from __future__ import annotations

import functools
import hashlib
import http.server
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

SITEPULSE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SITEPULSE / "scripts"))

import api_system_check as asc  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixture_clock import fixture_instant, site_local_date  # noqa: E402

E2E_API_PORT = int(os.environ.get("E2E_API_PORT", "8180"))
E2E_WEB_PORT = int(os.environ.get("E2E_WEB_PORT", "9190"))
_prebuilt_dir = os.environ.get("SITEPULSE_E2E_PREBUILT_DIR")
PREBUILT_DIR = Path(_prebuilt_dir).resolve() if _prebuilt_dir else None
WEB_BUILD = (PREBUILT_DIR or SITEPULSE / "flutter" / "build") / "web-e2e"
FLUTTER = Path(os.environ.get("FLUTTER_ROOT", str(Path.home() / "flutter"))) / "bin" / "flutter"

# Test-only values; they exist only inside the throwaway stack.
SAAS_ADMIN_EMAIL = "admin@sitepulse.io"
SAAS_ADMIN_PASSWORD = "E2E-Bootstrap-Admin-1"
WEBHOOK_SECRET = "gui-e2e-webhook-secret"
JWT_SECRET = "gui-e2e-jwt-secret-0123456789abcdef0123"

# Tables are emptied between modules; schema bookkeeping is kept.
KEEP_TABLES = {"schema_migrations", "refinery_schema_history", "_sqlx_migrations", "audit_events", "pii_settings"}

SetupError = asc.SetupError


def api_base() -> str:
    return f"http://localhost:{E2E_API_PORT}"


def web_base() -> str:
    return f"http://localhost:{E2E_WEB_PORT}"


def build_web(force: bool = False) -> None:
    """Build the E2E web bundle (semantics on, API pointed at the E2E backend)."""
    digest = hashlib.sha256(api_base().encode())
    flutter = SITEPULSE / "flutter"
    inputs = [flutter / "pubspec.yaml", flutter / "pubspec.lock"]
    for directory in ("lib", "web", "assets"):
        inputs.extend(sorted(path for path in (flutter / directory).rglob("*") if path.is_file()))
    for path in inputs:
        if path.exists():
            digest.update(str(path.relative_to(flutter)).encode())
            digest.update(path.read_bytes())
    google_client_id = os.environ.get("GOOGLE_CLIENT_ID", "")
    digest.update(google_client_id.encode())
    fingerprint = digest.hexdigest()
    stamp = WEB_BUILD / ".source-fingerprint"
    bundle_matches = (
        (WEB_BUILD / "index.html").is_file()
        and (WEB_BUILD / "main.dart.js").is_file()
        and stamp.is_file()
        and stamp.read_text(encoding="utf-8") == fingerprint
    )
    if PREBUILT_DIR is not None:
        if force:
            raise SetupError("Cannot rebuild the E2E web bundle with SITEPULSE_E2E_PREBUILT_DIR set")
        if not bundle_matches:
            raise SetupError(f"Prebuilt E2E web bundle is missing or stale: {WEB_BUILD}")
        return
    if bundle_matches and not force:
        return
    proc = subprocess.run(
        [str(FLUTTER), "build", "web", "--dart-define=E2E=true",
         f"--dart-define=SITEPULSE_API_BASE_URL={api_base()}",
         f"--dart-define=GOOGLE_CLIENT_ID={google_client_id}", "--output", str(WEB_BUILD)],
        cwd=SITEPULSE / "flutter", capture_output=True, text=True)
    if proc.returncode != 0:
        raise SetupError("flutter build web failed:\n" + proc.stdout[-2000:] + proc.stderr[-2000:])
    stamp.write_text(fingerprint, encoding="utf-8")


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args) -> None:  # keep test output readable
        pass


class WebServer:
    def __init__(self, port: int = E2E_WEB_PORT, root: Path = WEB_BUILD):
        handler = functools.partial(_QuietHandler, directory=str(root))
        for attempt in range(10):
            try:
                self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
                break
            except OSError as err:
                if attempt == 9 or err.errno != 98:
                    raise
                time.sleep(1.0)
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
            features=("e2e",),
            prebuilt_binary=PREBUILT_DIR / "sitepulse-backend" if PREBUILT_DIR else None,
            extra_env={
                "SITEPULSE_JWT_SECRET": JWT_SECRET,
                "SITEPULSE_BANK_WEBHOOK_SECRET": WEBHOOK_SECRET,
                "SITEPULSE_BOOTSTRAP_ADMIN_EMAIL": SAAS_ADMIN_EMAIL,
                "SITEPULSE_BOOTSTRAP_ADMIN_PASSWORD": SAAS_ADMIN_PASSWORD,
                "SITEPULSE_ENABLE_DEV_ROUTES": "false",
                "SITEPULSE_E2E": "true",
                "SITEPULSE_SEED_TEST_DATA": "false",
            })
        self.web = WebServer()
        self.e2e_clock_override: dict[str, str] | None = None
        self.fixture_instant = fixture_instant()
        self.fixture_today = site_local_date(self.fixture_instant).isoformat()

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
        self.e2e_clock_override = None
        self.backend.stop()
        tables = [t for t in self.sql(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1;").split("\n")
            if t and t not in KEEP_TABLES]
        if tables:
            self.sql(f"TRUNCATE {', '.join(tables)} RESTART IDENTITY CASCADE;")
        seed_dir = SITEPULSE / "backend" / "db" / "seed"
        self.sql((seed_dir / "01-system-seed.sql").read_text(encoding="utf-8"))
        self.sql((seed_dir / "02-test-seed.sql").read_text(encoding="utf-8"))
        self.sql("INSERT INTO pii_settings (hmac_key) VALUES (gen_random_bytes(32)) ON CONFLICT (id) DO NOTHING;")
        self.backend.start()
        self.pin_fixture_clock()
        # Seed actors have permanent test passwords. Temporary-account password
        # change scenarios create their own accounts after this fixture reset.
        self.sql("UPDATE users SET must_change_password=false;")

    def reset_empty(self) -> None:
        """Prepare a genuinely empty site list in the throwaway E2E database.

        This database is created and dropped by E2EStack, separate from the
        developer database. Restore only system configuration and let backend
        startup create the SaaS administrator; do not invoke a global reset API.
        """
        if not self.db_name.startswith("sitepulse_e2e_"):
            raise RuntimeError(f"Refusing to empty a non-E2E database: {self.db_name}")
        self.e2e_clock_override = None
        self.backend.stop()
        tables = [t for t in self.sql(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1;").split("\n")
            if t and t not in KEEP_TABLES]
        if tables:
            self.sql(f"TRUNCATE {', '.join(tables)} RESTART IDENTITY CASCADE;")
        seed_dir = SITEPULSE / "backend" / "db" / "seed"
        self.sql((seed_dir / "01-system-seed.sql").read_text(encoding="utf-8"))
        self.sql("INSERT INTO pii_settings (hmac_key) VALUES (gen_random_bytes(32)) ON CONFLICT (id) DO NOTHING;")
        self.backend.start()
        self.pin_fixture_clock()
        self.sql("UPDATE users SET must_change_password=false;")

    def restart_backend(self, *, preserve_e2e_clock: bool = True) -> None:
        """Reload backend memory after an Arrange step wrote SQL directly."""
        if not preserve_e2e_clock:
            self.e2e_clock_override = None
        self.backend.restart()
        self.pin_fixture_clock()

    def pin_fixture_clock(self) -> None:
        """Freeze the backend clock so SQL arrange steps, expected values and the app share one date.

        Without this the backend reads the wall clock per request, so a run that crosses midnight in
        the site's time zone grows every late penalty by a day mid-test. A test that set its own
        date keeps it across restarts (`e2e_clock_override`); otherwise the stack-wide fixture
        instant (`SITEPULSE_E2E_NOW` or the start of the run) applies.
        """
        command = self.e2e_clock_override or {"action": "set_instant", "at": self.fixture_instant_text}
        status, body = asc.http("POST", self.backend.base + "/__e2e/clock", body=command)
        if status != 200:
            raise SetupError(f"could not pin the E2E clock: {status} {body[:200]}")

    @property
    def fixture_instant_text(self) -> str:
        return self.fixture_instant.strftime("%Y-%m-%dT%H:%M:%SZ")

    def remember_e2e_clock(self, command: dict[str, object]) -> None:
        """Keep the current deterministic instant available across backend restarts."""
        action = command.get("action")
        if action == "clear":
            self.e2e_clock_override = None
        elif action in {"set_date", "advance_to"}:
            date = command.get("date")
            if isinstance(date, str):
                # Both backend commands normalize dates through e2e_clock::midnight_utc.
                self.e2e_clock_override = {
                    "action": "set_instant",
                    "at": f"{date}T00:00:00Z",
                }
        elif action == "set_instant":
            instant = command.get("at")
            if isinstance(instant, str):
                self.e2e_clock_override = {"action": "set_instant", "at": instant}

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
