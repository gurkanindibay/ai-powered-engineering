#!/usr/bin/env python3
"""End-to-end API and persistence checks against a real backend and PostgreSQL.

The tool creates a throwaway database, boots the real backend binary on a free
local port (the backend applies the migrations), seeds it, and checks over HTTP:

  unauthenticated_routes_rejected  every non-public route in src/app.rs returns 401 without a token
  forged_token_rejected            tampered, unsigned and legacy-format tokens return 401
  cross_site_forbidden             a site manager gets 403 on another site's data
  webhook_signature_enforced       unsigned/forged bank webhooks get 401; a signed one is accepted
  concurrent_receipts_unique       20 concurrent payments all succeed with distinct receipt numbers
  idempotent_payment_retry         a retried payment with the same Idempotency-Key returns the first receipt
  restart_persistence              a receipt issued before a backend restart is still served after it
  sequences_survive_restart        payments and new dues still insert after a restart (no id collisions)

PostgreSQL access: set DB_HOST/DB_PORT/DB_USER/DB_PASS. SQL is run with `psql`
when it is on PATH, otherwise through `docker exec <container> psql`
(--pg-container, default sitepulse-postgres).

Exit code 0 when every selected check passes, 1 otherwise, 2 on setup errors.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import hashlib
import hmac
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
APP_RS = BACKEND / "src" / "app.rs"
TEST_SEED = BACKEND / "db" / "seed" / "02-test-seed.sql"
WEBHOOK_SECRET = "api-system-check-webhook-secret"
JWT_SECRET = "api-system-check-jwt-secret-0123456789abcdef"
ADMIN_PASSWORD = "SystemCheck-Admin-1"

# Must mirror auth::route_access: routes reachable without a bearer token.
PUBLIC_ROUTES = {
    "/health", "/api/v1/health", "/api/v1/auth/login", "/api/v1/auth/google", "/api/v1/auth/register",
    "/api/v1/home-residents/register", "/api/v1/bank/webhook/incoming-transfer", "/api/v1/site-admin/banks",
    "/api/v1/registration/submit/:slug",
}
SAMPLE_PARAMS = {"unit_id": "14", "id": "14", "site_id": "1", "resident_id": "1", "sender_iban": "TR1", "slug": "x"}

CHECKS = [
    "unauthenticated_routes_rejected", "forged_token_rejected", "cross_site_forbidden", "webhook_signature_enforced",
    "concurrent_receipts_unique", "idempotent_payment_retry", "restart_persistence", "sequences_survive_restart",
]


class SetupError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

class Psql:
    def __init__(self, container: str):
        self.user = os.environ.get("DB_USER", "sitepulse_user")
        self.password = os.environ.get("DB_PASS", "")
        self.host = os.environ.get("DB_HOST", "127.0.0.1")
        self.port = os.environ.get("DB_PORT", "5432")
        self.container = container
        if not self.password:
            raise SetupError("DB_PASS must be set")
        self.local = shutil.which("psql") is not None
        if not self.local and shutil.which("docker") is None:
            raise SetupError("Neither psql nor docker is available to reach PostgreSQL")

    def run(self, db: str, sql: str) -> str:
        if self.local:
            argv = ["psql", f"postgresql://{self.user}:{self.password}@{self.host}:{self.port}/{db}", "-v", "ON_ERROR_STOP=1", "-At", "-q"]
        else:
            argv = ["docker", "exec", "-i", self.container, "psql", "-U", self.user, "-d", db, "-v", "ON_ERROR_STOP=1", "-At", "-q"]
        proc = subprocess.run(argv, input=sql, capture_output=True, text=True, timeout=120)
        if proc.returncode != 0:
            raise SetupError(f"psql failed: {proc.stderr.strip()}")
        return proc.stdout.strip()


# ---------------------------------------------------------------------------
# Backend process
# ---------------------------------------------------------------------------

def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Backend:
    def __init__(self, db_name: str, port: int, log_dir: Path, extra_env: Optional[Dict[str, str]] = None,
                 profile: str = "debug", log_prefix: str = "api_system_check"):
        self.db_name = db_name
        self.port = port
        self.log_dir = log_dir
        self.extra_env = extra_env or {}
        self.profile = profile
        self.log_prefix = log_prefix
        self.proc: Optional[subprocess.Popen] = None
        self.boots = 0

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def binary(self) -> Path:
        path = BACKEND / "target" / self.profile / "sitepulse-backend"
        argv = ["cargo", "build", "--locked", "--bin", "sitepulse-backend"] + (["--release"] if self.profile == "release" else [])
        build = subprocess.run(argv, cwd=BACKEND, capture_output=True, text=True)
        if build.returncode != 0:
            raise SetupError("cargo build failed:\n" + build.stderr[-3000:])
        return path

    def start(self) -> None:
        self.boots += 1
        env = {
            **os.environ,
            "DB_NAME": self.db_name,
            "SITEPULSE_BIND_ADDR": f"127.0.0.1:{self.port}",
            "SITEPULSE_JWT_SECRET": JWT_SECRET,
            "SITEPULSE_BANK_WEBHOOK_SECRET": WEBHOOK_SECRET,
            "SITEPULSE_BOOTSTRAP_ADMIN_PASSWORD": ADMIN_PASSWORD,
            "SITEPULSE_ENABLE_DEV_ROUTES": "false",
            "APP_ENV": "development",
            "RUST_LOG": "warn",
            **self.extra_env,
        }
        log = open(self.log_dir / f"{self.log_prefix}_boot{self.boots}.log", "w")
        self.proc = subprocess.Popen([str(self.binary())], cwd=BACKEND, env=env, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.time() + 90
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise SetupError(f"backend exited during startup (see {log.name})")
            try:
                if http("GET", self.base + "/health")[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.3)
        raise SetupError("backend did not become healthy within 90s")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def restart(self) -> None:
        self.stop()
        self.start()


def http(method: str, url: str, token: Optional[str] = None, body: Optional[object] = None,
         headers: Optional[Dict[str, str]] = None, raw: Optional[bytes] = None) -> Tuple[int, str]:
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else (b"{}" if method in ("POST", "PUT") else None))
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def login(backend: Backend, email: str, password: str) -> str:
    status, body = http("POST", backend.base + "/api/v1/auth/login", body={"email": email, "password": password})
    if status != 200:
        raise SetupError(f"login as {email} failed: {status} {body[:200]}")
    return json.loads(body)["access_token"]


def hash_password(password: str) -> str:
    out = subprocess.run(["cargo", "run", "--quiet", "--locked", "--bin", "hash-password"], cwd=BACKEND, input=password,
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SetupError("hash-password failed: " + out.stderr[-500:])
    return out.stdout.strip()


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def routes_from_app() -> List[Tuple[str, str]]:
    text = APP_RS.read_text(encoding="utf-8")
    found: List[Tuple[str, str]] = []
    for m in re.finditer(r'\.route\(\s*"([^"]+)"(.*?)(?=\.route\(|\n\s*\}|\Z)', text, re.S):
        path, rest = m.group(1), m.group(2)
        for method in re.findall(r"\b(get|post|put|delete)\(handlers::", rest):
            found.append((method.upper(), path))
    return found


def concrete(path: str) -> str:
    return re.sub(r":([a-z_]+)", lambda m: SAMPLE_PARAMS.get(m.group(1), "1"), path)


class Context:
    def __init__(self, backend: Backend, psql: Psql):
        self.backend = backend
        self.psql = psql
        self.manager = ""
        self.other_manager = ""
        self.receipt_before_restart: Optional[int] = None
        self.unit_id: str = "1"


def check_unauthenticated(ctx: Context) -> Tuple[bool, str]:
    routes = routes_from_app()
    if len(routes) < 50:
        return False, f"only {len(routes)} routes parsed from app.rs"
    bad = []
    for method, path in routes:
        if path in PUBLIC_ROUTES:
            continue
        status, _ = http(method, ctx.backend.base + concrete(path))
        if status != 401:
            bad.append(f"{method} {path} -> {status}")
    return not bad, f"{len(routes)} routes checked" + (": " + "; ".join(bad) if bad else "")


def check_forged(ctx: Context) -> Tuple[bool, str]:
    parts = ctx.manager.split(".")
    admin = base64.urlsafe_b64encode(json.dumps({"sub": "x", "email": "x", "role": "SAAS_ADMIN", "site_id": "1", "iat": 0, "exp": 9999999999}).encode()).decode().rstrip("=")
    forged = [f"{parts[0]}.{admin}.{parts[2]}", f"{parts[0]}.{admin}.c2lnX3NpdGVwdWxzZV92ZXJpZmllZF9ydXN0", f"eyJhbGciOiJub25lIn0.{admin}.", "not-a-token"]
    results = [http("GET", ctx.backend.base + "/api/v1/saas/sites", token=t)[0] for t in forged]
    return all(s == 401 for s in results), f"statuses {results}"


def check_cross_site(ctx: Context) -> Tuple[bool, str]:
    b = ctx.backend.base
    probes = [
        http("GET", b + "/api/v1/site-admin/home-owners?site_id=1", token=ctx.other_manager)[0],
        http("GET", b + f"/api/v1/site-admin/units/{ctx.unit_id}/occupancy-history", token=ctx.other_manager)[0],
        http("GET", b + "/api/v1/site-admin/bank-account/1", token=ctx.other_manager)[0],
        http("POST", b + "/api/v1/payments/record-manual", token=ctx.other_manager, body={"site_id": "1", "unit_id": ctx.unit_id, "amount": "1.00", "payer_name": "x"})[0],
    ]
    own = http("GET", b + "/api/v1/site-admin/home-owners", token=ctx.manager)[0]
    return all(p == 403 for p in probes) and own == 200, f"foreign {probes}, own {own}"


def check_webhook(ctx: Context) -> Tuple[bool, str]:
    url = ctx.backend.base + "/api/v1/bank/webhook/incoming-transfer"
    body = json.dumps({"transaction_id": f"SYS-{int(time.time()*1000)}", "virtual_iban": "TR620020500009863791600001",
                       "amount": "5.00", "currency": "TRY", "description": "system check"}).encode()
    unsigned = http("POST", url, raw=body)[0]
    forged = http("POST", url, raw=body, headers={"X-SitePulse-Signature": hmac.new(b"wrong", body, hashlib.sha256).hexdigest()})[0]
    signed = http("POST", url, raw=body, headers={"X-SitePulse-Signature": hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()})[0]
    replay = http("POST", url, raw=body, headers={"X-SitePulse-Signature": hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()})
    dup = replay[0] == 200 and "DUPLICATE" in replay[1]
    return unsigned == 401 and forged == 401 and signed == 200 and dup, f"unsigned {unsigned}, forged {forged}, signed {signed}, replay duplicate {dup}"


def pay(ctx: Context, amount: str = "3.00", key: Optional[str] = None) -> Tuple[int, str]:
    headers = {"Idempotency-Key": key} if key else None
    return http("POST", ctx.backend.base + "/api/v1/payments/record-manual", token=ctx.manager,
                body={"unit_id": ctx.unit_id, "amount": amount, "payer_name": "System Check", "payer_role": "OWNER", "payment_channel": "MANUAL_CASH"}, headers=headers)


def check_concurrent(ctx: Context) -> Tuple[bool, str]:
    before = int(ctx.psql.run(ctx.backend.db_name, "SELECT count(*) FROM payment_receipts;") or 0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
        statuses = [f.result()[0] for f in [pool.submit(pay, ctx) for _ in range(20)]]
    row = ctx.psql.run(ctx.backend.db_name, "SELECT count(*), count(DISTINCT sequence_number), count(DISTINCT receipt_number) FROM payment_receipts;")
    total, seqs, numbers = (int(x) for x in row.split("|"))
    ok = statuses.count(201) == 20 and total == before + 20 and seqs == total and numbers == total
    return ok, f"statuses {sorted(set(statuses))}, receipts {total} (distinct seq {seqs}, distinct numbers {numbers})"


def check_idempotent(ctx: Context) -> Tuple[bool, str]:
    key = f"syscheck-{time.time_ns()}"
    first, second = pay(ctx, "2.00", key), pay(ctx, "2.00", key)
    ids = [json.loads(r[1]).get("id") if r[0] in (200, 201) else None for r in (first, second)]
    rows = ctx.psql.run(ctx.backend.db_name, f"SELECT count(*) FROM payment_idempotency_keys WHERE idempotency_key = '{key}';")
    ctx.receipt_before_restart = ids[0]
    return ids[0] is not None and ids[0] == ids[1] and rows == "1", f"receipt ids {ids}, key rows {rows}"


def check_restart(ctx: Context) -> Tuple[bool, str]:
    if ctx.receipt_before_restart is None:
        status, body = pay(ctx)
        if status != 201:
            return False, f"payment before restart failed: {status}"
        ctx.receipt_before_restart = json.loads(body)["id"]
    ctx.backend.restart()
    ctx.manager = login(ctx.backend, "mehmet.demir@begonya.com", "mehmet123")
    status, _ = http("GET", f"{ctx.backend.base}/api/v1/payments/receipts/{ctx.receipt_before_restart}", token=ctx.manager)
    return status == 200, f"receipt {ctx.receipt_before_restart} after restart -> {status}"


def check_sequences(ctx: Context) -> Tuple[bool, str]:
    if ctx.backend.boots < 2:
        ctx.backend.restart()
        ctx.manager = login(ctx.backend, "mehmet.demir@begonya.com", "mehmet123")
    status, _ = pay(ctx)
    inserted = ctx.psql.run(ctx.backend.db_name,
                            f"INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status) "
                            f"VALUES ({ctx.unit_id}, 'Restart Check ' || clock_timestamp()::text, 1, CURRENT_DATE, 'PENDING') RETURNING id;")
    return status == 201 and inserted.isdigit(), f"payment after restart {status}, new dues id {inserted}"


CHECK_FUNCS: Dict[str, Callable[[Context], Tuple[bool, str]]] = {
    "unauthenticated_routes_rejected": check_unauthenticated,
    "forged_token_rejected": check_forged,
    "cross_site_forbidden": check_cross_site,
    "webhook_signature_enforced": check_webhook,
    "concurrent_receipts_unique": check_concurrent,
    "idempotent_payment_retry": check_idempotent,
    "restart_persistence": check_restart,
    "sequences_survive_restart": check_sequences,
}


def seed(ctx: Context) -> None:
    db = ctx.backend.db_name
    ctx.psql.run(db, TEST_SEED.read_text(encoding="utf-8"))
    unit_id = ctx.psql.run(db, "SELECT id FROM units WHERE unit_number = 14 LIMIT 1;").strip()
    if unit_id:
        ctx.unit_id = unit_id
    manager2 = hash_password("OtherManager-123")
    ctx.psql.run(db, f"""
        INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
        VALUES ('System Check Site 2', 'Ankara', 'syscheck-2', 'ACTIVE', 'STANDARD', CURRENT_DATE + 365);
        INSERT INTO persons (full_name, email, person_type) VALUES ('Other Manager', 'other.manager@syscheck.test', 'SITE_MANAGER');
        INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
        SELECT s.id, p.id, 'other.manager@syscheck.test', '{manager2}', 'SITE_MANAGER', FALSE
        FROM sites s, persons p WHERE s.slug = 'syscheck-2' AND p.email = 'other.manager@syscheck.test';
        INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status)
        VALUES ({ctx.unit_id}, 'System Check Dues', 100.00, CURRENT_DATE, 'PENDING');
    """)


def run(selected: List[str], container: str, keep: bool, log_dir: Path) -> Dict[str, object]:
    psql = Psql(container)
    db_name = f"sitepulse_syscheck_{os.getpid()}"
    psql.run("postgres", f"DROP DATABASE IF EXISTS {db_name};")
    psql.run("postgres", f"CREATE DATABASE {db_name};")
    backend = Backend(db_name, free_port(), log_dir)
    ctx = Context(backend, psql)
    results: List[Dict[str, object]] = []
    try:
        backend.start()            # applies migrations
        seed(ctx)
        backend.restart()          # load the seeded data
        ctx.manager = login(backend, "mehmet.demir@begonya.com", "mehmet123")
        ctx.other_manager = login(backend, "other.manager@syscheck.test", "OtherManager-123")
        for name in CHECKS:
            if name not in selected:
                continue
            try:
                ok, detail = CHECK_FUNCS[name](ctx)
            except Exception as e:  # a crashing check is a failing check
                ok, detail = False, f"{type(e).__name__}: {e}"
            results.append({"name": name, "passed": ok, "detail": detail})
    finally:
        backend.stop()
        if not keep:
            psql.run("postgres", f"DROP DATABASE IF EXISTS {db_name};")
    return {"passed": bool(results) and all(r["passed"] for r in results), "database": db_name, "checks": results}


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", help="Comma-separated subset of checks to run")
    parser.add_argument("--json", action="store_true", help="Print a JSON report")
    parser.add_argument("--keep-db", action="store_true", help="Keep the throwaway database for debugging")
    parser.add_argument("--pg-container", default=os.environ.get("SITEPULSE_PG_CONTAINER", "sitepulse-postgres"),
                        help="Container used for psql when psql is not on PATH")
    parser.add_argument("--log-dir", type=Path, default=Path(os.environ.get("TMPDIR", "/tmp")), help="Where backend boot logs go")
    args = parser.parse_args(argv)
    selected = [c.strip() for c in args.only.split(",")] if args.only else list(CHECKS)
    unknown = [c for c in selected if c not in CHECK_FUNCS]
    if unknown:
        print(f"Unknown checks: {unknown}. Known: {CHECKS}", file=sys.stderr)
        return 2
    try:
        report = run(selected, args.pg_container, args.keep_db, args.log_dir)
    except SetupError as e:
        report = {"passed": False, "error": str(e), "checks": []}
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            print(f"Setup failed: {e}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for c in report["checks"]:
            print(f"{'PASS' if c['passed'] else 'FAIL'}  {c['name']:34} {c['detail']}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
