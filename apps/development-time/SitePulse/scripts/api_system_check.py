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
  match_all_settles_in_place       match-all settles an UNMATCHED row in place, with receipt and allocations (SPEC-005)
  payer_identity_recorded          a payment records the payer person on its entry and receipt (V16)
  site_purge_is_atomic             the non-production purge removes a site with ledger history (V16 guard)
  tenant_surplus_virman            a tenant surplus is TENANT credit; a TENANT -> OWNER virman pays owner capital dues (SPEC-006 O-1)
  reversal_restores_ledger         a reversal issues an IAD receipt, a contra entry, un-allocates and refunds advance (O-2)
  webhook_claim_scoped             webhook claims record account, receipt and payload hash; a reused id with other content is 409 (O-3)
  issuer_snapshot_on_receipt       the site tax id is validated and snapshotted on new receipts (O-5)
  debt_aging_snapshot_persisted    the aging snapshot writes one row per unit/debtor per day, idempotently (O-8)
  virman_reversal_restores_advance a reversed virman reopens its dues and credits VIRMAN_REVERSAL to the source (SPEC-007 R1)
  resident_statement_scoped        the statement ages open items; another site's manager gets 403 (R2)
  receipt_pdf_and_verification     a receipt downloads as a PDF; the public QR check confirms it without payer data (R3)
  card_payment_via_provider        a sandbox card payment is captured through the signed webhook exactly once (R4)
  budget_accrual_legal_basis       accrual from an approved işletme projesi records the budget on each liability (R5)
  finance_desk_over_http           SPEC-009: balanced ledger, dunning, analytics, four-eyes invoices, isolation, lawyer token
  exit_settlement_self_approval_audited requester self-approval is denied, preserves advance, and writes an AUTHZ_DENIED event
  person_records_and_import        person F7-F10: hashed national ID (step-up, audited), preferences, duplicates, CSV import
  ledger_integrity_clean           v_integrity_violations is empty after all checks

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
from decimal import Decimal
from typing import Callable, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
APP_RS = BACKEND / "src" / "app.rs"
TEST_SEED = BACKEND / "db" / "seed" / "02-test-seed.sql"
WEBHOOK_SECRET = "api-system-check-webhook-secret"
JWT_SECRET = "api-system-check-jwt-secret-0123456789abcdef"
ADMIN_PASSWORD = "SystemCheck-Admin-1"
PAYMENT_WEBHOOK_SECRET = "api-system-check-payment-secret"

# Must mirror auth::route_access: routes reachable without a bearer token.
PUBLIC_ROUTES = {
    "/health", "/api/v1/health", "/api/v1/auth/login", "/api/v1/auth/google", "/api/v1/auth/register", "/api/v1/auth/refresh",
    "/api/v1/auth/activate", "/api/v1/auth/confirm-email",
    "/api/v1/home-residents/register", "/api/v1/bank/webhook/incoming-transfer", "/api/v1/site-admin/banks",
    "/api/v1/registration/submit/{slug}",
    "/api/v1/public/receipts/verify", "/api/v1/payments/provider/webhook",
    "/api/v1/payment-provider/sandbox/checkout/{reference}", "/api/v1/payment-provider/sandbox/checkout/{reference}/complete",
    # SPEC-009 R8: the lawyer's evidence pack is authenticated by its one-time token.
    "/api/v1/public/collection-cases/pack",
    # API documentation: the OpenAPI spec and its Swagger UI / Scalar viewers.
    "/api-docs/openapi.json", "/api/v1/openapi.json", "/openapi.json",
    "/swagger-ui", "/swagger-ui/", "/swagger-ui/index.html", "/docs", "/scalar",
}
SAMPLE_PARAMS = {"unit_id": "14", "id": "14", "site_id": "1", "resident_id": "1", "sender_iban": "TR1", "slug": "x",
                 "reference": "SBX-x", "intent_id": "1", "objection_id": "1"}

CHECKS = [
    "unauthenticated_routes_rejected", "forged_token_rejected", "cross_site_forbidden", "webhook_signature_enforced",
    "concurrent_receipts_unique", "idempotent_payment_retry", "restart_persistence", "sequences_survive_restart",
    "match_all_settles_in_place", "payer_identity_recorded", "site_purge_is_atomic",
    "tenant_surplus_virman", "reversal_restores_ledger", "webhook_claim_scoped", "issuer_snapshot_on_receipt",
    "debt_aging_snapshot_persisted", "virman_reversal_restores_advance", "resident_statement_scoped",
    "receipt_pdf_and_verification", "card_payment_via_provider", "budget_accrual_legal_basis", "ledger_integrity_clean",
    "security_session_lifecycle", "transactional_audit", "audit_scope_and_privileges", "registration_repository_scope", "support_grant_lifecycle", "household_members_persisted", "invitation_atomic_registration",
    "finance_desk_over_http", "exit_settlement_self_approval_audited",
    "person_tenant_isolation", "person_activation_lifecycle", "person_directory_and_export",
    "person_records_and_import",
]


class SetupError(RuntimeError):
    pass


def load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

class Psql:
    def __init__(self, container: str):
        if not os.environ.get("DB_PASS"):
            load_env_file(BACKEND / ".env")
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

    def run_status(self, db: str, sql: str) -> int:
        """Run SQL that is expected to be refused; returns psql's exit code (0 = it succeeded)."""
        try:
            self.run(db, sql)
            return 0
        except SetupError:
            return 1


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
            "SITEPULSE_PAYMENT_WEBHOOK_SECRET": PAYMENT_WEBHOOK_SECRET,
            "SITEPULSE_PUBLIC_BASE_URL": self.base,
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
    passwords = getattr(backend, "passwords", {})
    effective = passwords.get(email, password)
    status, body = http("POST", backend.base + "/api/v1/auth/login", body={"email": email, "password": effective})
    if status != 200:
        raise SetupError(f"login as {email} failed: {status} {body[:200]}")
    result = json.loads(body)
    if result["user"]["must_change_password"]:
        changed = effective + "-Changed"
        status, body = http("POST", backend.base + "/api/v1/auth/change-password", token=result["access_token"],
                            body={"email": email, "current_password": effective, "new_password": changed})
        if status != 200:
            raise SetupError(f"mandatory password change failed: {status}")
        result = json.loads(body)
        passwords[email] = changed
        backend.passwords = passwords
        effective = changed
    status, _ = http("POST", backend.base + "/api/v1/auth/step-up", token=result["access_token"], body={"password": effective})
    if status != 200:
        raise SetupError(f"password step-up failed: {status}")
    return result["access_token"]


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
    return [(method.upper(), path) for method, path in
            re.findall(r'(?m)^\s*(get|post|put|delete)\s+"([^"\n]+)"\s*=>', text)]


def public_routes_from_app(text: Optional[str] = None) -> set:
    """Paths whose route policy in src/app.rs is `Public` (reachable without a bearer token)."""
    source = APP_RS.read_text(encoding="utf-8") if text is None else text
    return set(re.findall(r'(?m)^\s*(?:get|post|put|delete)\s+"([^"\n]+)"\s*=>\s*[\w:]+\s*,\s*Public\s*;', source))


def public_route_drift(text: Optional[str] = None) -> Tuple[List[str], List[str]]:
    """(declared Public in app.rs but not mirrored, mirrored but not Public in app.rs)."""
    declared = public_routes_from_app(text)
    return sorted(declared - PUBLIC_ROUTES), sorted(PUBLIC_ROUTES - declared)


def concrete(path: str) -> str:
    return re.sub(r"[:{]([a-z_]+)\}?", lambda m: SAMPLE_PARAMS.get(m.group(1), "1"), path)


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
    unmirrored, stale = public_route_drift()
    if unmirrored or stale:
        return False, (f"PUBLIC_ROUTES out of sync with app.rs: Public but not mirrored {unmirrored}; "
                       f"mirrored but not Public {stale}")
    bad = []
    for method, path in routes:
        if path in PUBLIC_ROUTES or path.startswith("/api/v1/system/"):
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
    return all(p == 404 for p in probes) and own == 200, f"foreign {probes}, own {own}"


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


def check_match_all_in_place(ctx: Context) -> Tuple[bool, str]:
    """SPEC-005 R2: match-all turns the UNMATCHED row into the settled entry (no duplicate)."""
    db = ctx.backend.db_name
    site = ctx.psql.run(db, f"SELECT site_id FROM units WHERE id = {ctx.unit_id};")
    ref = f"SYS-UNM-{time.time_ns()}"
    entry_id = ctx.psql.run(db, (
        "INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel,"
        f" settlement_status, external_reference) VALUES ({site}, {ctx.unit_id}, 'Bank Sender', 'OWNER', 4.00,"
        f" 'BANK_TRANSFER', 'UNMATCHED', '{ref}') RETURNING id;"))
    before = ctx.psql.run(db, "SELECT count(*) FROM payment_entries;")
    ctx.backend.restart()  # the pending row is loaded from PostgreSQL
    ctx.manager = login(ctx.backend, "mehmet.demir@begonya.com", "mehmet123")
    status, body = http("POST", ctx.backend.base + "/api/v1/payments/match-all", token=ctx.manager, body={"site_id": site})
    after = ctx.psql.run(db, "SELECT count(*) FROM payment_entries;")
    row = ctx.psql.run(db, f"SELECT settlement_status || '|' || (receipt_id IS NOT NULL) FROM payment_entries WHERE id = {entry_id};")
    allocations = ctx.psql.run(db, f"SELECT count(*) FROM payment_allocations WHERE payment_entry_id = {entry_id};")
    ok = status == 200 and after == before and row == "SETTLED|true" and int(allocations or 0) >= 1
    return ok, f"status {status}, entries {before}->{after}, entry {entry_id} {row}, allocations {allocations}"


def check_payer_identity(ctx: Context) -> Tuple[bool, str]:
    """V16 P-02: canonical payments record the payer person on entry and receipt."""
    status, body = pay(ctx, "1.00")
    if status != 201:
        return False, f"payment failed: {status} {body[:200]}"
    receipt_id = json.loads(body)["id"]
    row = ctx.psql.run(ctx.backend.db_name, (
        "SELECT (e.payer_person_id IS NOT NULL) || '|' || (r.payer_person_id IS NOT NULL) || '|' ||"
        " (e.payer_person_id = u.owner_person_id) FROM payment_entries e JOIN payment_receipts r ON r.id = e.receipt_id"
        f" JOIN units u ON u.id = e.unit_id WHERE r.id = {receipt_id};"))
    return row == "true|true|true", f"receipt {receipt_id}: entry/receipt payer set, matches owner -> {row}"


def check_site_purge(ctx: Context) -> Tuple[bool, str]:
    """V16 P-06: the non-production purge removes a site with ledger history in one transaction."""
    db = ctx.backend.db_name
    site = ctx.psql.run(db, "SELECT id FROM sites WHERE slug = 'syscheck-2';")
    ctx.psql.run(db, f"""
        INSERT INTO blocks (site_id, block_name, total_floors) VALUES ({site}, 'P', 1);
        INSERT INTO units (block_id, site_id, unit_number, floor, land_share)
            SELECT id, {site}, 1, 1, 10 FROM blocks WHERE site_id = {site};
        INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role,
                                      total_amount, allocated_advance, advance_debtor_type, payment_channel, verification_hash)
            SELECT {site}, id, 'PURGE-1', 1, 'P', 'OWNER', 5, 5, 'OWNER', 'MANUAL_CASH', 'h' FROM units WHERE site_id = {site};
        INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, receipt_id)
            SELECT {site}, unit_id, 'P', 'OWNER', 5, 'MANUAL_CASH', id FROM payment_receipts WHERE receipt_number = 'PURGE-1';
        INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount)
            SELECT id, 'OWNER', 'PAYMENT_SURPLUS', 5 FROM units WHERE site_id = {site};
    """)
    # The purge is a dev route: enabled for this check only, then switched off again.
    ctx.backend.extra_env["SITEPULSE_ENABLE_DEV_ROUTES"] = "true"
    ctx.backend.restart()
    try:
        admin = login(ctx.backend, "admin@sitepulse.io", ADMIN_PASSWORD)
        status, body = http("POST", f"{ctx.backend.base}/api/v1/system/purge-site/{site}", token=admin)
    finally:
        ctx.backend.extra_env.pop("SITEPULSE_ENABLE_DEV_ROUTES", None)
        ctx.backend.restart()
        ctx.manager = login(ctx.backend, "mehmet.demir@begonya.com", "mehmet123")
    left = ctx.psql.run(db, (
        f"SELECT (SELECT count(*) FROM sites WHERE id = {site}) + (SELECT count(*) FROM payment_receipts WHERE site_id = {site})"
        f" + (SELECT count(*) FROM payment_entries WHERE site_id = {site});"))
    guard = ctx.psql.run(db, "SELECT coalesce(current_setting('sitepulse.allow_ledger_purge', true), '');")
    return status == 200 and left == "0" and guard != "on", f"status {status}, rows left {left}, guard after '{guard}'"


def relogin(ctx: Context) -> None:
    ctx.backend.restart()
    ctx.manager = login(ctx.backend, "mehmet.demir@begonya.com", "mehmet123")


def check_tenant_surplus_virman(ctx: Context) -> Tuple[bool, str]:
    """SPEC-006 O-1: per-debtor advance in PostgreSQL, and the TENANT -> OWNER virman."""
    db, b = ctx.backend.db_name, ctx.backend.base
    status, body = http("POST", b + "/api/v1/payments/record-manual", token=ctx.manager, body={
        "unit_id": ctx.unit_id, "amount": "500.00", "payer_name": "Tenant Payer", "payer_role": "TENANT",
        "payment_channel": "MANUAL_CASH"})
    if status != 201:
        return False, f"tenant payment failed: {status} {body[:200]}"
    receipt = json.loads(body)
    surplus = receipt["allocated_advance"]
    tenant_before = ctx.psql.run(db, f"SELECT balance FROM advance_balances WHERE unit_id = {ctx.unit_id} AND debtor_type = 'TENANT';")
    period = f"SYS-CAP-{time.time_ns()}"
    ctx.psql.run(db, f"INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type, expense_type)"
                     f" VALUES ({ctx.unit_id}, '{period}', 6.00, CURRENT_DATE + 10, 'PENDING', 'OWNER', 'CAPITAL_DUES');")
    relogin(ctx)  # the new capital due and the per-debtor balances are loaded from PostgreSQL
    v_status, v_body = http("POST", b + "/api/v1/payments/inter-ledger-transfer", token=ctx.manager, body={
        "unit_id": ctx.unit_id, "amount": "6.00", "source_debtor": "TENANT", "target_debtor": "OWNER"})
    row = ctx.psql.run(db, (
        f"SELECT d.status || '|' || (SELECT balance FROM advance_balances WHERE unit_id = {ctx.unit_id} AND debtor_type = 'TENANT')"
        f" || '|' || (SELECT count(*) FROM advance_ledger_entries WHERE unit_id = {ctx.unit_id} AND debtor_type = 'TENANT'"
        f"            AND entry_type = 'VIRMAN_DEBIT' AND amount = 6.00)"
        f" FROM dues_liabilities d WHERE d.period = '{period}';"))
    debtor = ctx.psql.run(db, f"SELECT advance_debtor_type FROM payment_receipts WHERE id = {receipt['id']};")
    expected = f"PAID|{float(tenant_before) - 6:.2f}|1"
    ok = (float(surplus) > 0 and debtor == "TENANT" and v_status == 200 and row == expected)
    return ok, f"surplus {surplus} -> {debtor}, virman {v_status} {v_body[:120] if v_status != 200 else ''}, due|tenant advance|debits {row} (want {expected})"


def check_reversal(ctx: Context) -> Tuple[bool, str]:
    """SPEC-006 O-2: reversal in PostgreSQL, surviving a restart, idempotent."""
    db, b = ctx.backend.db_name, ctx.backend.base
    ctx.psql.run(db, f"INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type)"
                     f" VALUES ({ctx.unit_id}, 'SYS-REV-{time.time_ns()}', 8.00, CURRENT_DATE + 10, 'PENDING', 'OWNER');")
    relogin(ctx)
    status, body = http("POST", b + "/api/v1/payments/record-manual", token=ctx.manager, body={
        "unit_id": ctx.unit_id, "amount": "100000.00", "payer_name": "Owner Payer", "payer_role": "OWNER",
        "payment_channel": "BANK_TRANSFER", "external_reference": f"SYS-REV-{time.time_ns()}"})
    if status != 201:
        return False, f"payment failed: {status} {body[:200]}"
    original = json.loads(body)
    paid_before = ctx.psql.run(db, "SELECT sum(paid_principal + paid_penalty) FROM dues_liabilities;")
    no_reason = http("POST", b + "/api/v1/payments/reverse", token=ctx.manager, body={"receipt": original["receipt_number"], "reason": ""})[0]
    r_status, r_body = http("POST", b + "/api/v1/payments/reverse", token=ctx.manager,
                            body={"receipt": original["receipt_number"], "reason": "System check: bounced transfer"})
    if r_status != 201:
        return False, f"reversal failed: {r_status} {r_body[:200]}"
    rev = json.loads(r_body)["reversal_receipt"]
    paid_after = ctx.psql.run(db, "SELECT sum(paid_principal + paid_penalty) FROM dues_liabilities;")
    unallocated = float(original["allocated_principal"]) + float(original["allocated_penalty"])
    row = ctx.psql.run(db, (
        "SELECT o.settlement_status || '|' || c.settlement_status || '|' || c.entry_type || '|' || (c.recorded_by = (SELECT id::text FROM users WHERE email='mehmet.demir@begonya.com'))"
        " || '|' || (SELECT count(*) FROM advance_ledger_entries WHERE entry_type = 'REFUND' AND reference_id = rr.receipt_number"
        f"            AND amount = {original['allocated_advance']})"
        " FROM payment_entries o JOIN payment_entries c ON c.reverses_entry_id = o.id JOIN payment_receipts rr ON rr.id = c.receipt_id"
        f" WHERE o.receipt_id = {original['id']};"))
    relogin(ctx)
    again = http("POST", b + "/api/v1/payments/reverse", token=ctx.manager,
                 body={"receipt": original["receipt_number"], "reason": "System check: bounced transfer"})
    same = again[0] == 201 and json.loads(again[1])["reversal_receipt"]["receipt_number"] == rev["receipt_number"]
    served = http("GET", f"{b}/api/v1/payments/receipts/{rev['receipt_number']}", token=ctx.manager)[0]
    ok = (no_reason == 400 and rev["receipt_number"].startswith("IAD-") and row == "REVERSED|REVERSED|REVERSAL|true|1"
          and abs(float(paid_before) - float(paid_after) - unallocated) < 0.001 and same and served == 200)
    return ok, (f"no-reason {no_reason}, {rev['receipt_number']}, entries {row}, paid {paid_before}->{paid_after}"
                f" (unallocated {unallocated:.2f}), retry same {same}, served after restart {served}")


def signed_webhook(ctx: Context, payload: Dict[str, str]) -> Tuple[int, str]:
    body = json.dumps(payload).encode()
    return http("POST", ctx.backend.base + "/api/v1/bank/webhook/incoming-transfer", raw=body,
                headers={"X-SitePulse-Signature": hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()})


def check_webhook_claim(ctx: Context) -> Tuple[bool, str]:
    """SPEC-006 O-3: scoped webhook claims with receipt link and payload hash."""
    db = ctx.backend.db_name
    iban = ctx.psql.run(db, f"SELECT virtual_iban FROM units WHERE id = {ctx.unit_id};") or "TR620020500009863791600001"
    txn = f"SYS-CLAIM-{time.time_ns()}"
    payload = {"transaction_id": txn, "virtual_iban": iban, "amount": "7.00", "currency": "TRY", "description": "claim check"}
    first = signed_webhook(ctx, payload)
    row = ctx.psql.run(db, (
        "SELECT (w.site_id IS NOT NULL) || '|' || (w.site_bank_account_id IS NOT NULL) || '|' || coalesce(r.receipt_number, '-')"
        f" || '|' || length(w.payload_hash) FROM processed_bank_webhooks w LEFT JOIN payment_receipts r ON r.id = w.receipt_id"
        f" WHERE w.transaction_id = '{txn}';"))
    receipt_no = json.loads(first[1]).get("receipt_id") if first[0] == 200 else None
    replay = signed_webhook(ctx, payload)
    conflict = signed_webhook(ctx, {**payload, "amount": "8.00"})[0]
    replay_receipt = json.loads(replay[1]).get("receipt_id") if replay[0] == 200 else None
    ok = (first[0] == 200 and row == f"true|true|{receipt_no}|64" and replay_receipt == receipt_no
          and "DUPLICATE" in replay[1] and conflict == 409)
    return ok, f"first {first[0]} {receipt_no}, claim {row}, replay -> {replay_receipt}, reused id with other amount -> {conflict}"


def check_issuer_snapshot(ctx: Context) -> Tuple[bool, str]:
    """SPEC-006 O-5: sites.tax_id is validated and copied onto new receipts."""
    db, b = ctx.backend.db_name, ctx.backend.base
    site = ctx.psql.run(db, f"SELECT site_id FROM units WHERE id = {ctx.unit_id};")
    admin = login(ctx.backend, "admin@sitepulse.io", ADMIN_PASSWORD)
    bad = http("PUT", f"{b}/api/v1/saas/sites/{site}", token=admin, body={"tax_id": "12AB"})[0]
    good = http("PUT", f"{b}/api/v1/saas/sites/{site}", token=admin, body={"tax_id": "1234567890", "tax_office": "Atasehir"})[0]
    status, body = pay(ctx, "1.50")
    if status != 201:
        return False, f"payment failed: {status} {body[:200]}"
    rid = json.loads(body)["id"]
    row = ctx.psql.run(db, (
        "SELECT coalesce(r.issuer_tax_id, '-') || '|' || coalesce(r.issuer_tax_office, '-') || '|' || (r.issuer_name = s.name)"
        f" FROM payment_receipts r JOIN sites s ON s.id = r.site_id WHERE r.id = {rid};"))
    return bad == 400 and good == 200 and row == "1234567890|Atasehir|true", f"bad {bad}, good {good}, receipt {rid}: {row}"


def check_aging_snapshot(ctx: Context) -> Tuple[bool, str]:
    """SPEC-006 O-8: debt_aging_snapshots is written (once per unit/debtor/day)."""
    db, url = ctx.backend.db_name, ctx.backend.base + "/api/v1/payments/debt-aging/snapshot"
    site = ctx.psql.run(db, f"SELECT site_id FROM units WHERE id = {ctx.unit_id};")
    # An open liability so the unit appears in today's report.
    ctx.psql.run(db, f"INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type)"
                     f" VALUES ({ctx.unit_id}, 'SYS-AGING-{time.time_ns()}', 12.00, CURRENT_DATE - 45, 'PENDING', 'OWNER');")
    relogin(ctx)
    count_sql = f"SELECT count(*) FROM debt_aging_snapshots WHERE as_of_date = CURRENT_DATE AND site_id = {site};"
    first = http("POST", url, token=ctx.manager)
    count1 = ctx.psql.run(db, count_sql)
    second = http("POST", url, token=ctx.manager)
    count2 = ctx.psql.run(db, count_sql)
    rows = json.loads(first[1]).get("rows") if first[0] == 200 else None
    ok = first[0] == 200 and second[0] == 200 and int(count1 or 0) > 0 and count1 == count2 and rows == int(count1)
    return ok, f"status {first[0]}/{second[0]}, rows {rows}, table {count1} -> {count2}"


def http_bytes(url: str, token: Optional[str] = None) -> Tuple[int, bytes, str]:
    req = urllib.request.Request(url, method="GET")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read(), resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("Content-Type", "")


def check_virman_reversal(ctx: Context) -> Tuple[bool, str]:
    """SPEC-007 R1: reversing a virman reopens its dues and credits the source advance back."""
    db, b = ctx.backend.db_name, ctx.backend.base
    status, body = http("POST", b + "/api/v1/payments/record-manual", token=ctx.manager, body={
        "unit_id": ctx.unit_id, "amount": "100000.00", "payer_name": "Owner Payer", "payer_role": "OWNER",
        "payment_channel": "BANK_TRANSFER", "external_reference": f"SYS-VR-{time.time_ns()}"})
    if status != 201:
        return False, f"surplus payment failed: {status} {body[:200]}"
    period = f"SYS-VR-CAP-{time.time_ns()}"
    ctx.psql.run(db, f"INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type, expense_type)"
                     f" VALUES ({ctx.unit_id}, '{period}', 9.00, CURRENT_DATE + 10, 'PENDING', 'OWNER', 'CAPITAL_DUES');")
    relogin(ctx)
    before = ctx.psql.run(db, f"SELECT balance FROM advance_balances WHERE unit_id = {ctx.unit_id} AND debtor_type = 'OWNER';")
    v_status, v_body = http("POST", b + "/api/v1/payments/inter-ledger-transfer", token=ctx.manager, body={
        "unit_id": ctx.unit_id, "amount": "9.00"})
    if v_status != 200:
        return False, f"virman failed: {v_status} {v_body[:200]}"
    virman_no = json.loads(v_body)["receipt_number"]
    r_status, r_body = http("POST", b + "/api/v1/payments/reverse", token=ctx.manager,
                            body={"receipt": virman_no, "reason": "System check: wrong virman"})
    if r_status != 201:
        return False, f"virman reversal failed: {r_status} {r_body[:200]}"
    rev = json.loads(r_body)
    row = ctx.psql.run(db, (
        f"SELECT d.status || '|' || d.paid_principal || '|' || (SELECT balance FROM advance_balances WHERE unit_id = {ctx.unit_id}"
        f" AND debtor_type = 'OWNER') || '|' || (SELECT count(*) FROM advance_ledger_entries WHERE entry_type = 'VIRMAN_REVERSAL'"
        f" AND reference_id = '{rev['reversal_receipt']['receipt_number']}' AND amount = 9.00)"
        f" FROM dues_liabilities d WHERE d.period = '{period}';"))
    expected = f"PENDING|0.00|{Decimal(before):.2f}|1"
    ok = row == expected and Decimal(str(rev.get("restored_advance", 0))) == Decimal("9.00")
    return ok, f"{virman_no} -> {rev['reversal_receipt']['receipt_number']}, due|paid|advance|ledger {row} (want {expected})"


def check_resident_statement(ctx: Context) -> Tuple[bool, str]:
    """SPEC-007 R2: the statement is served for the unit and scoped to its site."""
    b = ctx.backend.base
    status, body = http("GET", f"{b}/api/v1/residents/{ctx.unit_id}/statement", token=ctx.manager)
    # The earlier purge intentionally deleted the original second site and actor.
    # Provision a live foreign actor so this assertion tests scope, not revocation.
    suffix = str(time.time_ns())
    foreign_site = ctx.psql.run(ctx.backend.db_name, f"INSERT INTO sites(name,slug,address,status,plan_type) VALUES ('Foreign Site','scope-{suffix}','Test','ACTIVE','STANDARD') RETURNING id;")
    foreign_hash = hash_password("Scope-Manager-123")
    ctx.psql.run(ctx.backend.db_name, f"INSERT INTO users(site_id,email,password_hash,role,must_change_password) VALUES ({foreign_site},'scope-{suffix}@example.com','{foreign_hash}','SITE_MANAGER',false);")
    foreign_token = login(ctx.backend, f"scope-{suffix}@example.com", "Scope-Manager-123")
    other = http("GET", f"{b}/api/v1/residents/{ctx.unit_id}/statement", token=foreign_token)[0]
    if status != 200:
        return False, f"statement {status} {body[:200]}"
    st = json.loads(body)
    owner = next((d for d in st["debtors"] if d["debtor_type"] == "OWNER"), None)
    buckets = owner and sum(Decimal(owner[k]) for k in ("current_due", "overdue_1_30_days", "overdue_31_60_days",
                                                      "overdue_61_90_days", "overdue_90_plus_days"))
    ok = owner is not None and buckets == Decimal(owner["principal_outstanding"]) and other == 404
    return ok, f"owner principal {owner and owner['principal_outstanding']} = buckets {buckets}, receipts {len(st['receipts'])}, other site {other}"


# covers: SC-11-07-03
def check_finance_desk(ctx: Context) -> Tuple[bool, str]:
    """SPEC-009 over HTTP and PostgreSQL: the derived ledger balances, dunning and
    analytics run, the debtor export is named for staff, an invoice is never
    approved by the person who recorded it, another site sees none of it, a
    forged lawyer token is refused, and the SPEC-009 integrity view is clean."""
    db, b = ctx.backend.db_name, ctx.backend.base
    tb_status, tb_body = http("GET", f"{b}/api/v1/accounting/trial-balance", token=ctx.manager)
    balanced = tb_status == 200 and json.loads(tb_body).get("balanced") is True
    dunning = http("POST", f"{b}/api/v1/dunning/run", token=ctx.manager)[0]
    analytics = http("GET", f"{b}/api/v1/analytics/collections?months=3", token=ctx.manager)[0]
    ex_status, ex_body = http("GET", f"{b}/api/v1/kvkk/debtor-export", token=ctx.manager)
    named = ex_status == 200 and json.loads(ex_body).get("masked") is False
    vendor_status, vendor_body = http("POST", f"{b}/api/v1/accounting/vendors", token=ctx.manager,
                                      body={"name": "Syscheck Temizlik", "tax_id": "0010180009"})
    if vendor_status == 409:
        vendors = json.loads(http("GET", f"{b}/api/v1/accounting/vendors", token=ctx.manager)[1])
        vendor_id = next(v["id"] for v in vendors if v["tax_id"] == "0010180009")
    elif vendor_status == 201:
        vendor_id = json.loads(vendor_body)["id"]
    else:
        return False, f"vendor {vendor_status} {vendor_body[:200]}"
    inv_status, inv_body = http("POST", f"{b}/api/v1/accounting/expenses", token=ctx.manager, body={
        "vendor_id": vendor_id, "invoice_number": f"SYS-{time.time_ns()}", "invoice_date": time.strftime("%Y-%m-%d"),
        "category": "CLEANING", "net_amount": "100.00"})
    if inv_status != 201:
        return False, f"expense {inv_status} {inv_body[:200]}"
    self_approve = http("POST", f"{b}/api/v1/accounting/expenses/{json.loads(inv_body)['id']}/approve", token=ctx.manager)[0]
    # Earlier checks purge the second site, so a live foreign manager is provisioned here.
    suffix = str(time.time_ns())
    foreign_site = ctx.psql.run(db, f"INSERT INTO sites(name,slug,address,status,plan_type) VALUES ('Finance Foreign','fin-{suffix}','Test','ACTIVE','STANDARD') RETURNING id;")
    ctx.psql.run(db, f"INSERT INTO users(site_id,email,password_hash,role,must_change_password) VALUES ({foreign_site},'fin-{suffix}@example.com','{hash_password('Finance-Foreign-123')}','SITE_MANAGER',false);")
    foreign_token = login(ctx.backend, f"fin-{suffix}@example.com", "Finance-Foreign-123")
    foreign = http("GET", f"{b}/api/v1/accounting/vendors", token=foreign_token)
    isolated = foreign[0] == 200 and json.loads(foreign[1]) == []
    lawyer = http("GET", f"{b}/api/v1/public/collection-cases/pack?token=forged")[0]
    violations = ctx.psql.run(db, "SELECT count(*) FROM v_finance_integrity_violations;").strip()
    ok = (balanced and dunning == 200 and analytics == 200 and named and self_approve == 403
          and isolated and lawyer == 403 and violations == "0")
    return ok, (f"trial balance {tb_status}/{balanced}, dunning {dunning}, analytics {analytics}, export named {named}, "
                f"self-approval {self_approve}, foreign isolated {isolated}, forged lawyer token {lawyer}, violations {violations}")


def check_exit_settlement_self_approval_audited(ctx: Context) -> Tuple[bool, str]:
    """A requester cannot approve their own exit settlement; middleware audits the denial."""
    db, b = ctx.backend.db_name, ctx.backend.base
    payment_status, payment_body = pay(ctx, "100.00")
    if payment_status != 201:
        return False, f"advance seed payment failed: {payment_status} {payment_body[:160]}"
    identity = ctx.psql.run(
        db,
        "SELECT owner_person_id || '|' || site_id FROM units WHERE unit_number = 14 LIMIT 1;",
    ).strip()
    if not identity or "|" not in identity:
        return False, "seed owner identity is unavailable"
    person_id, _ = identity.split("|", 1)
    unit = ctx.unit_id
    request_status, request_body = http(
        "POST",
        f"{b}/api/v1/site-admin/units/{unit}/advance-exit-settlements",
        token=ctx.manager,
        body={
            "request_key": f"self-approval-{time.time_ns()}",
            "kind": "PAYOUT",
            "source_debtor": "OWNER",
            "target_debtor": None,
            "amount": "25.00",
            "beneficiary_name": "Seed Owner",
            "beneficiary_person_id": person_id,
            "note": "API system check",
        },
    )
    if request_status != 201:
        return False, f"settlement request failed: {request_status} {request_body[:160]}"
    settlement_id = json.loads(request_body)["id"]
    before = ctx.psql.run(
        db,
        f"SELECT balance FROM advance_balances WHERE unit_id={unit} AND debtor_type='OWNER';",
    ).strip()
    decision_status, _ = http(
        "POST",
        f"{b}/api/v1/site-admin/advance-exit-settlements/{settlement_id}/decide",
        token=ctx.manager,
        body={"approve": True, "payment_reference": "self-approval-check", "note": None},
    )
    after = ctx.psql.run(
        db,
        f"SELECT balance FROM advance_balances WHERE unit_id={unit} AND debtor_type='OWNER';",
    ).strip()
    user_id = ctx.psql.run(
        db, "SELECT id FROM users WHERE lower(email)=lower('mehmet.demir@begonya.com') LIMIT 1;"
    ).strip()
    audited = ctx.psql.run(
        db,
        "SELECT count(*) > 0 FROM audit_events "
        "WHERE action='AUTHZ_DENIED' AND outcome='DENIED' "
        "AND resource_type='http_request' "
        "AND resource_id='/api/v1/site-admin/advance-exit-settlements/{id}/decide' "
        f"AND actor_id='{user_id}' AND request_id <> 'database';",
    ).strip() == "t"
    ok = decision_status == 403 and before == after and audited
    return ok, f"self-approval {decision_status}, balance unchanged {before == after}, denied audit event {audited}"


def check_receipt_pdf(ctx: Context) -> Tuple[bool, str]:
    """SPEC-007 R3: PDF download and public verification without payer data."""
    db, b = ctx.backend.db_name, ctx.backend.base
    status, body = pay(ctx, "2.25")
    if status != 201:
        return False, f"payment failed: {status} {body[:200]}"
    receipt = json.loads(body)
    p_status, pdf, ctype = http_bytes(f"{b}/api/v1/payments/receipts/{receipt['receipt_number']}/pdf", token=ctx.manager)
    h = ctx.psql.run(db, f"SELECT verification_hash FROM payment_receipts WHERE id = {receipt['id']};")
    v_status, v_body = http("GET", f"{b}/api/v1/public/receipts/verify?no={receipt['receipt_number']}&h={h}")
    bad = json.loads(http("GET", f"{b}/api/v1/public/receipts/verify?no={receipt['receipt_number']}&h={'0' * 64}")[1])
    verified = json.loads(v_body) if v_status == 200 else {}
    ok = (p_status == 200 and pdf.startswith(b"%PDF") and "application/pdf" in ctype and verified.get("valid") is True
          and receipt["payer_name"] not in v_body and bad.get("valid") is False)
    return ok, f"pdf {p_status} {len(pdf)} bytes {ctype}, verify {v_status} valid={verified.get('valid')}, wrong code valid={bad.get('valid')}"


def check_card_payment(ctx: Context) -> Tuple[bool, str]:
    """SPEC-007 R4: sandbox hosted page -> signed notifications -> one receipt; forged notifications rejected."""
    db, b = ctx.backend.db_name, ctx.backend.base
    owner_hash = hash_password("CardOwner-123")
    owner_email = ctx.psql.run(db, f"UPDATE users SET password_hash='{owner_hash}',must_change_password=false WHERE person_id=(SELECT owner_person_id FROM units WHERE id={int(ctx.unit_id)}) AND role='HOME_OWNER' RETURNING email;")
    owner_token = login(ctx.backend, owner_email, "CardOwner-123")
    status, body = http("POST", f"{b}/api/v1/residents/{ctx.unit_id}/payment-intents", token=owner_token,
                        body={"amount": "9.50", "debtor_type": "OWNER"})
    if status != 201:
        return False, f"intent {status} {body[:200]}"
    intent = json.loads(body)
    page_status, page = http("GET", intent["checkout_url"])
    no_card_fields = "<input" not in page.lower()
    done_status, _ = http("POST", intent["checkout_url"] + "/complete", raw=b"outcome=APPROVE",
                          headers={"Content-Type": "application/x-www-form-urlencoded"})
    event = {"provider": intent["provider"], "provider_ref": intent["provider_ref"], "status": "CAPTURED", "amount": "9.50"}
    raw = json.dumps(event).encode()
    forged = http("POST", b + "/api/v1/payments/provider/webhook", raw=raw, headers={"X-Provider-Signature": "00" * 32})[0]
    sig = hmac.new(PAYMENT_WEBHOOK_SECRET.encode(), raw, hashlib.sha256).hexdigest()
    replay_status, replay = http("POST", b + "/api/v1/payments/provider/webhook", raw=raw, headers={"X-Provider-Signature": sig})
    row = ctx.psql.run(db, (
        "SELECT pi.status || '|' || r.payment_channel || '|' || r.total_amount || '|' ||"
        " (SELECT count(*) FROM payment_entries e WHERE e.site_id = pi.site_id AND e.external_reference = pi.provider_ref)"
        f" FROM payment_intents pi JOIN payment_receipts r ON r.site_id = pi.site_id AND r.receipt_number = pi.receipt_number"
        f" WHERE pi.id = {intent['id']};"))
    same = replay_status == 200 and json.loads(replay).get("receipt_number") is not None
    ok = (page_status == 200 and no_card_fields and done_status == 200 and forged == 401 and same
          and row == "CAPTURED|CREDIT_CARD|9.50|1")
    return ok, (f"page {page_status} (no card inputs {no_card_fields}), complete {done_status}, forged {forged}, "
                f"signed replay {replay_status}, intent|channel|amount|receipts {row}")


def check_budget_accrual(ctx: Context) -> Tuple[bool, str]:
    """SPEC-007 R5: approved budget -> accrual from unit shares, legal basis recorded, survives a restart."""
    db, b = ctx.backend.db_name, ctx.backend.base
    site = ctx.psql.run(db, f"SELECT site_id FROM units WHERE id = {ctx.unit_id};")
    year = int(ctx.psql.run(db, "SELECT extract(year FROM CURRENT_DATE)::int;"))
    status, body = http("POST", f"{b}/api/v1/operating-budgets", token=ctx.manager, body={
        "fiscal_year": year, "lines": [{"category": "CLEANING", "annual_amount": "120000.00", "allocation_key": "LAND_SHARE"},
                                       {"category": "MANAGEMENT_FEE", "annual_amount": "6000.00", "allocation_key": "EQUAL"}]})
    if status != 201:
        return False, f"create {status} {body[:200]}"
    budget = json.loads(body)
    a_status, a_body = http("POST", f"{b}/api/v1/operating-budgets/{budget['id']}/approve", token=ctx.manager, body={
        "assembly_decision_ref": "Karar 2026/SYS", "assembly_decision_date": time.strftime("%Y-%m-%d")})
    if a_status != 200:
        return False, f"approve {a_status} {a_body[:200]}"
    relogin(ctx)  # the budget is reloaded from PostgreSQL
    g_status, g_body = http("GET", f"{b}/api/v1/operating-budgets/{budget['id']}", token=ctx.manager)
    reloaded = json.loads(g_body) if g_status == 200 else {}
    share = next((s for s in reloaded.get("unit_shares", []) if s["unit_id"] == ctx.unit_id), None)
    period = f"SYS-BUDGET-{time.time_ns()}"
    due = ctx.psql.run(db, "SELECT (CURRENT_DATE + 10)::text;")
    acc_status, acc_body = http("POST", f"{b}/api/v1/dues/accrue-period", token=ctx.manager, body={
        "site_id": site, "period": period, "amount": "0", "due_date": due})
    typed = http("POST", f"{b}/api/v1/dues/accrue-period", token=ctx.manager, body={
        "site_id": site, "period": period + "-X", "amount": "5.00", "due_date": due})[0]
    row = ctx.psql.run(db, (
        f"SELECT count(*) || '|' || count(*) FILTER (WHERE operating_budget_id = {budget['id']}) || '|' ||"
        f" coalesce(max(principal_amount) FILTER (WHERE unit_id = {ctx.unit_id}), 0) || '|' ||"
        f" count(*) FILTER (WHERE debtor_type = 'OWNER' AND unit_id IN (SELECT id FROM units WHERE tenant_person_id IS NULL))"
        f" FROM dues_liabilities WHERE period = '{period}';"))
    count, linked, amount, owner_rows = (row.split("|") + ["", "", "", ""])[:4]
    ok = (reloaded.get("status") == "APPROVED" and share is not None and acc_status == 200 and typed == 409
          and count == linked and int(count or 0) > 0 and Decimal(amount) == Decimal(share["monthly_amount"])
          and int(owner_rows or 0) > 0)
    return ok, (f"budget {budget['id']} reloaded {reloaded.get('status')}, accrue {acc_status}, typed amount {typed}, "
                f"rows|linked|unit amount|owner rows {row} (share {share and share['monthly_amount']})")


def check_ledger_integrity(ctx: Context) -> Tuple[bool, str]:
    """After every other check: no drift reported by v_integrity_violations."""
    rows = ctx.psql.run(ctx.backend.db_name, "SELECT check_name || ':' || subject FROM v_integrity_violations;")
    return rows == "", f"violations: {rows.replace(chr(10), ', ') or 'none'}"


def check_security_session_lifecycle(ctx: Context) -> Tuple[bool, str]:
    base = ctx.backend.base
    email = "mehmet.demir@begonya.com"
    password = getattr(ctx.backend, "passwords", {}).get(email, "mehmet123")
    status, body = http("POST", base + "/api/v1/auth/login", body={"email": email, "password": password})
    if status != 200:
        return False, f"sign-in {status}"
    credentials = json.loads(body)
    status, body = http("POST", base + "/api/v1/auth/refresh", body={"refresh_token": credentials["refresh_token"]})
    if status != 200:
        return False, f"refresh {status}"
    rotated = json.loads(body)
    reused, _ = http("POST", base + "/api/v1/auth/refresh", body={"refresh_token": credentials["refresh_token"]})
    revoked, _ = http("GET", base + "/api/v1/auth/me", token=rotated["access_token"])
    separate = login(ctx.backend, email, "mehmet123")
    logout, _ = http("POST", base + "/api/v1/auth/logout", token=separate)
    copied, _ = http("GET", base + "/api/v1/auth/me", token=separate)
    return (reused, revoked, logout, copied) == (401, 401, 200, 401), f"reuse {reused}, family {revoked}, logout {logout}, copied JWT {copied}"


def check_transactional_audit(ctx: Context) -> Tuple[bool, str]:
    base, db = ctx.backend.base, ctx.backend.db_name
    status, body = pay(ctx, key="AAA-AUDIT-RECORDED")
    receipt = json.loads(body) if status == 201 else {}
    if status != 201:
        return False, f"payment {status}"
    event = ctx.psql.run(db, f"SELECT count(*)>0 FROM audit_events WHERE resource_type='payment_receipts' AND resource_id='{int(receipt['id'])}' AND actor_kind='USER' AND actor_id IS NOT NULL AND request_id<>'database';")
    before = ctx.psql.run(db, "SELECT count(*) FROM payment_receipts;")
    ctx.psql.run(db, """
        CREATE FUNCTION sp_aaa_test_audit_failure() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN IF NEW.resource_type='payment_receipts' THEN RAISE EXCEPTION 'Injected audit failure'; END IF; RETURN NEW; END $$;
        CREATE TRIGGER aaa_test_audit_failure BEFORE INSERT ON audit_events FOR EACH ROW EXECUTE FUNCTION sp_aaa_test_audit_failure();
    """)
    try:
        failed, _ = pay(ctx, key="AAA-AUDIT-ROLLBACK")
    finally:
        ctx.psql.run(db, "DROP TRIGGER aaa_test_audit_failure ON audit_events; DROP FUNCTION sp_aaa_test_audit_failure();")
    after = ctx.psql.run(db, "SELECT count(*) FROM payment_receipts;")
    clean = ctx.psql.run(db, "SELECT NOT EXISTS(SELECT 1 FROM audit_events WHERE changes::text LIKE '%$argon2%' OR changes::text LIKE '%SuperSecretPassword%');")
    return event == "t" and failed >= 400 and before == after and clean == "t", f"attribution {event}, injected failure {failed}, receipts {before}->{after}, redaction {clean}"


def check_audit_scope_and_privileges(ctx: Context) -> Tuple[bool, str]:
    base, db = ctx.backend.base, ctx.backend.db_name
    own_status, body = http("GET", base + "/api/v1/audit/events?limit=25", token=ctx.manager)
    own = json.loads(body).get("events", []) if own_status == 200 else []
    manager_site = ctx.psql.run(db, "SELECT site_id FROM users WHERE email='mehmet.demir@begonya.com';")
    isolated = all(str(row['site_id']) == manager_site for row in own)
    foreign_status, _ = http("GET", base + "/api/v1/audit/events?site_id=2", token=ctx.manager)
    export_status, _ = http("GET", base + "/api/v1/audit/export?limit=1", token=ctx.manager)
    # A non-owner role proves RLS and append-only behavior independently of the owner API connection.
    role = f"sitepulse_aaa_probe_{os.getpid()}"
    try:
        ctx.psql.run(db, f"CREATE ROLE {role} NOLOGIN; GRANT USAGE ON SCHEMA public TO {role}; GRANT SELECT,UPDATE,DELETE ON audit_events TO {role};")
        visible = ctx.psql.run(db, f"SET ROLE {role}; SELECT set_config('sitepulse.audit_context','{{\"site_id\":\"{manager_site}\",\"actor_role\":\"SITE_MANAGER\",\"permissions\":[\"AUDIT_LOG_READ\"]}}',false); SELECT NOT EXISTS(SELECT 1 FROM audit_events WHERE site_id IS DISTINCT FROM {int(manager_site)});").splitlines()[-1]
        immutable = False
        try:
            ctx.psql.run(db, f"SET ROLE {role}; UPDATE audit_events SET action='TAMPERED'; DELETE FROM audit_events;")
            immutable = ctx.psql.run(db, "SELECT NOT EXISTS(SELECT 1 FROM audit_events WHERE action='TAMPERED');") == "t"
        except SetupError:
            immutable = True
    finally:
        ctx.psql.run(db, f"DROP OWNED BY {role}; DROP ROLE {role};")
    return own_status == 200 and isolated and foreign_status == 404 and export_status == 200 and visible == "t" and immutable, f"read {own_status}, scoped {isolated}, foreign {foreign_status}, export {export_status}, RLS {visible}, immutable {immutable}"


def check_registration_repository_scope(ctx: Context) -> Tuple[bool, str]:
    db, base = ctx.backend.db_name, ctx.backend.base
    # The earlier purge check deliberately removed the original second site.
    # Create a fresh actor and site, without restarting or populating the cache.
    hashed = hash_password("ScopeManager-123")
    ctx.psql.run(db, f"INSERT INTO sites(name,address,slug) VALUES ('AAA scope site','Test','aaa-scope-site'); INSERT INTO users(site_id,email,password_hash,role) SELECT id,'aaa-scope-manager@example.com','{hashed}','SITE_MANAGER' FROM sites WHERE slug='aaa-scope-site';")
    other_manager = login(ctx.backend,"aaa-scope-manager@example.com","ScopeManager-123")
    ctx.psql.run(db, """INSERT INTO pending_registrations(request_id,site_id,block,unit_no,floor,full_name,email,phone,is_resident)
        SELECT 'aaa-db-only',site_id,'A Blok',1,1,'AAA Review','aaa-review@example.com','',true FROM users WHERE email='aaa-scope-manager@example.com';""")
    rejected, _ = http("POST", base + "/api/v1/registration/reject/aaa-db-only", token=ctx.manager)
    approved, _ = http("POST", base + "/api/v1/registration/approve/aaa-db-only", token=ctx.manager)
    unchanged = ctx.psql.run(db, "SELECT status FROM pending_registrations WHERE request_id='aaa-db-only';")
    own, _ = http("POST", base + "/api/v1/registration/reject/aaa-db-only", token=other_manager)
    return (rejected, approved, unchanged, own) == (404, 404, "PENDING", 200), f"foreign reject/approve {rejected}/{approved}, unchanged {unchanged}, authorized reject {own}"


def check_support_grant_lifecycle(ctx: Context) -> Tuple[bool, str]:
    db, base = ctx.backend.db_name, ctx.backend.base
    first = login(ctx.backend,"admin@sitepulse.io",ADMIN_PASSWORD)
    hashed = hash_password("Approver-Password-123")
    ctx.psql.run(db, f"INSERT INTO users(email,password_hash,role) VALUES ('aaa-approver@example.com','{hashed}','SAAS_ADMIN');")
    second = login(ctx.backend,"aaa-approver@example.com","Approver-Password-123")
    operator = ctx.psql.run(db,"SELECT id FROM users WHERE email='admin@sitepulse.io';")
    create, body = http("POST",base+"/api/v1/support/grants",token=first,body={"site_id":"1","operator_user_id":operator,"permissions":["SITE_MANAGE","PERSON_READ","AUDIT_LOG_READ","UNIT_READ"],"reason":"Investigate a support ticket","minutes":5})
    if create != 200:
        return False,f"request {create}"
    grant = json.loads(body)["id"]
    header = {"X-SitePulse-Support-Grant":grant}
    self_approve, _ = http("POST",base+"/api/v1/support/grants/approve",token=first,body={"id":grant})
    pending, _ = http("GET",base+"/api/v1/site-admin/home-owners",token=first,headers=header)
    approve, _ = http("POST",base+"/api/v1/support/grants/approve",token=second,body={"id":grant})
    allowed, _ = http("GET",base+"/api/v1/site-admin/home-owners",token=first,headers=header)
    ordinary, _ = http("GET",base+"/api/v1/site-admin/home-owners",token=first)
    receipt_status, receipt_body = pay(ctx, key="SUPPORT-RECEIPT")
    receipt_id = json.loads(receipt_body).get("id",0) if receipt_status==201 else 0
    receipt_access, _ = http("GET",base+f"/api/v1/payments/receipts/{receipt_id}",token=first,headers=header)
    used = ctx.psql.run(db,f"SELECT count(*) FROM audit_events WHERE action='SUPPORT_GRANT_USED' AND support_grant_id='{grant}';")
    revoke, _ = http("POST",base+"/api/v1/support/grants/revoke",token=second,body={"id":grant})
    revoked, _ = http("GET",base+"/api/v1/site-admin/home-owners",token=first,headers=header)
    return self_approve==404 and receipt_access==200 and int(used)>=2 and (pending,approve,allowed,ordinary,revoke,revoked)==(403,200,200,403,200,403), f"self {self_approve}, pending {pending}, approve {approve}, granted {allowed}, receipt {receipt_access}, audited uses {used}, ordinary {ordinary}, revoke {revoke}/{revoked}"


def check_household_members(ctx: Context) -> Tuple[bool, str]:
    """Manager household entries persist and failed evidence rolls identity writes back."""
    db, base = ctx.backend.db_name, ctx.backend.base
    suffix = str(time.time_ns())
    email = f"household-{suffix}@example.com"
    path = f"/api/v1/home-residents/members/{ctx.unit_id}"
    status, body = http("POST", base + path, token=ctx.manager, body={
        "person": {"kind": "new", "card": {"full_name": "Household Verifier", "email": email}},
        "relationship": "Family"})
    if status != 201:
        return False, f"creation {status} {body[:160]}"
    member = json.loads(body)
    relogin(ctx)
    read_status, read_body = http("GET", base + path, token=ctx.manager)
    members = json.loads(read_body) if read_status == 200 else []
    persisted = any(m["resident_id"] == member["resident_id"] and m["email"] == email and not m["is_owner"] for m in members)
    ctx.psql.run(db, """CREATE FUNCTION reject_household_evidence() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Injected household failure'; END $$;
        CREATE TRIGGER reject_household_evidence BEFORE INSERT ON occupancy_members FOR EACH ROW EXECUTE FUNCTION reject_household_evidence();""")
    rejected_email = f"rejected-{suffix}@example.com"
    try:
        rejected, _ = http("POST", base + path, token=ctx.manager, body={
            "person": {"kind": "new", "card": {"full_name": "Rejected Household", "email": rejected_email}},
            "relationship": "Family"})
    finally:
        ctx.psql.run(db, "DROP TRIGGER reject_household_evidence ON occupancy_members; DROP FUNCTION reject_household_evidence();")
    count = ctx.psql.run(db, f"SELECT count(*) FROM persons WHERE email='{rejected_email}';")
    evidence = ctx.psql.run(db, f"SELECT count(*) FROM audit_events WHERE resource_type='occupancy_members' AND resource_id='{int(member['resident_id'])}';")
    ok = persisted and int(member["resident_id"]) > 0 and rejected == 503 and count == "0" and int(evidence) > 0
    return ok, f"persistent {persisted}, audited {evidence}, injected failure {rejected}, orphan persons {count}"


def check_invitation_atomic_registration(ctx: Context) -> Tuple[bool, str]:
    db, base = ctx.backend.db_name, ctx.backend.base
    hashed = hash_password("InviteOwner-123")
    email = ctx.psql.run(db, f"UPDATE users SET password_hash='{hashed}',must_change_password=false WHERE person_id=(SELECT owner_person_id FROM units WHERE id={int(ctx.unit_id)}) AND role='HOME_OWNER' RETURNING email;")
    owner = login(ctx.backend,email,"InviteOwner-123")
    status, body = http("GET",base+f"/api/v1/home-residents/invite-link/{ctx.unit_id}",token=owner)
    if status != 200:
        return False,f"invitation {status}"
    invitation = json.loads(body)["token"]
    def register(index: int):
        return http("POST",base+"/api/v1/auth/register",body={"full_name":f"Invited Member {index}","email":f"aaa-invited-{index}@example.com","password":"Invited-Password-123","unit_invite_token":invitation})
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(register,[1,2]))
    statuses = sorted(result[0] for result in results)
    winner = next((json.loads(body) for code, body in results if code == 201),{})
    scoped = http("GET",base+f"/api/v1/residents/{ctx.unit_id}/dashboard",token=winner.get("access_token"))[0]
    count = ctx.psql.run(db,"SELECT count(*) FROM users WHERE email LIKE 'aaa-invited-%@example.com';")
    # A failure after token consumption must restore the invitation and all identity rows.
    _, body = http("GET",base+f"/api/v1/home-residents/invite-link/{ctx.unit_id}",token=owner)
    rollback_token = json.loads(body)["token"]
    request = {"full_name":"Rollback Member","email":"aaa-invite-rollback@example.com","password":"Invited-Password-123","unit_invite_token":rollback_token}
    ctx.psql.run(db,"CREATE FUNCTION sp_aaa_invite_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.resource_type='occupancy_members' THEN RAISE EXCEPTION 'Injected membership audit failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER aaa_invite_failure BEFORE INSERT ON audit_events FOR EACH ROW EXECUTE FUNCTION sp_aaa_invite_failure();")
    try:
        failed, _ = http("POST",base+"/api/v1/auth/register",body=request)
    finally:
        ctx.psql.run(db,"DROP TRIGGER aaa_invite_failure ON audit_events; DROP FUNCTION sp_aaa_invite_failure();")
    absent = ctx.psql.run(db,"SELECT NOT EXISTS(SELECT 1 FROM users WHERE email='aaa-invite-rollback@example.com') AND NOT EXISTS(SELECT 1 FROM persons WHERE email='aaa-invite-rollback@example.com');")
    retry, _ = http("POST",base+"/api/v1/auth/register",body=request)
    return statuses==[201,400] and scoped==200 and count=="1" and failed>=400 and absent=="t" and retry==201, f"concurrent {statuses}, current unit {scoped}, accounts {count}, failed {failed}, rollback {absent}, retry {retry}"


def _owner_body(unit_no: int, email: str, name: str = "Isolation Owner") -> Dict[str, object]:
    return {"block": "S Blok", "unit_no": unit_no, "floor": 1, "owner_full_name": name, "email": email,
            "phone": "+90 532 000 11 22", "land_share": "1/24", "monthly_dues": "100.00", "house_type": "2+1",
            "is_resident": True, "role": "OWNER"}


def check_person_tenant_isolation(ctx: Context) -> Tuple[bool, str]:
    """S1/F11/S8: persons are per site, registration is atomic and errors do not echo addresses."""
    db, base = ctx.backend.db_name, ctx.backend.base
    suffix = str(time.time_ns())[-9:]
    shared = f"shared-{suffix}@example.com"
    # A site of its own: earlier checks may purge the shared second site.
    other_site = ctx.psql.run(db, f"""INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
        VALUES ('Isolation Site {suffix}', 'Izmir', 'isolation-{suffix}', 'ACTIVE', 'STANDARD', CURRENT_DATE + 365) RETURNING id;""").strip()
    # A contact-only person of site 2 with the address site 1 is about to register.
    ctx.psql.run(db, f"INSERT INTO persons (full_name, email, person_type, site_id) VALUES ('Site Two Person', '{shared}', 'HOME_OWNER', {other_site});")
    status, body = http("POST", base + "/api/v1/site-admin/home-owners", token=ctx.manager,
                        body=_owner_body(700 + int(suffix[-2:]), shared))
    site_two_untouched = ctx.psql.run(
        db, f"SELECT full_name FROM persons WHERE lower(email)='{shared}' AND site_id={other_site};") == "Site Two Person"
    separate = status == 201 and ctx.psql.run(db, f"SELECT count(DISTINCT site_id) FROM persons WHERE lower(email)='{shared}';") == "2"
    no_secret = "temporary_password" not in body and "SP-SAKIN" not in body
    # F6: the role is derived from what the person holds (V23), not the stored type.
    derived = ctx.psql.run(db, f"SELECT r.derived_role FROM v_person_roles r JOIN persons p ON p.id = r.person_id WHERE lower(p.email)='{shared}' AND p.site_id <> {other_site};")

    # Cross-site linking is refused by the database itself.
    site_one_person = ctx.psql.run(db, f"SELECT id FROM persons WHERE lower(email)='{shared}' AND site_id <> {other_site};").strip()
    guard = ctx.psql.run_status(db, f"""INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
        VALUES ({other_site}, {site_one_person}, 'cross-{suffix}@example.com', NULL, 'HOME_OWNER', TRUE);""")

    # F11: a failure late in registration leaves no person, account or unit behind.
    rolled = f"rolled-{suffix}@example.com"
    ctx.psql.run(db, """CREATE FUNCTION reject_registration_dues() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Injected dues failure'; END $$;
        CREATE TRIGGER reject_registration_dues BEFORE INSERT ON dues_liabilities FOR EACH ROW EXECUTE FUNCTION reject_registration_dues();""")
    try:
        failed, failed_body = http("POST", base + "/api/v1/site-admin/home-owners", token=ctx.manager,
                                   body=_owner_body(800 + int(suffix[-2:]), rolled))
    finally:
        ctx.psql.run(db, "DROP TRIGGER reject_registration_dues ON dues_liabilities; DROP FUNCTION reject_registration_dues();")
    orphans = ctx.psql.run(db, f"SELECT (SELECT count(*) FROM persons WHERE email='{rolled}') + (SELECT count(*) FROM users WHERE email='{rolled}');")
    generic = "Injected" not in failed_body and "db error" not in failed_body

    # S8: a taken login address is refused without being echoed.
    dup, dup_body = http("POST", base + "/api/v1/site-admin/home-owners", token=ctx.manager,
                         body=_owner_body(900 + int(suffix[-2:]), shared))
    ok = (separate and site_two_untouched and no_secret and derived == "HOME_OWNER" and guard != 0 and failed >= 500 and orphans == "0"
          and generic and dup == 409 and shared not in dup_body)
    return ok, (f"registered {status}, per-site persons {separate}, site-2 untouched {site_two_untouched}, no secret {no_secret}, derived role {derived}, "
                f"cross-site link exit {guard}, injected failure {failed} generic {generic}, orphans {orphans}, duplicate {dup}")


def check_person_activation_lifecycle(ctx: Context) -> Tuple[bool, str]:
    """S2/S3/S5/S9: activation, staged email change, archival and immediate identity reuse."""
    db, base = ctx.backend.db_name, ctx.backend.base
    suffix = str(time.time_ns())[-9:]
    email = f"activate-{suffix}@example.com"
    status, body = http("POST", base + "/api/v1/site-admin/home-owners", token=ctx.manager,
                        body=_owner_body(600 + int(suffix[-2:]), email, "Activation Owner"))
    if status != 201:
        return False, f"registration {status} {body[:160]}"
    created = json.loads(body)
    unit = created["unit_id"]
    no_password = ctx.psql.run(db, f"SELECT password_hash IS NULL FROM users WHERE email='{email}';") == "t"
    sent = (created.get("activation") or {}).get("status") == "SENT"
    blocked = http("POST", base + "/api/v1/auth/login", body={"email": email, "password": "Anything-2026!"})[0]

    # The person's link: plant a known token the way the service stores it (SHA-256 only).
    token = "a" * 40 + suffix.rjust(24, "0")
    digest = hashlib.sha256(token.encode()).hexdigest()
    ctx.psql.run(db, f"""INSERT INTO account_activations (token_hash, user_id, site_id, purpose, expires_at)
        SELECT '{digest}', id, site_id, 'ACTIVATE', now() + interval '1 hour' FROM users WHERE email='{email}';""")
    activated = http("POST", base + "/api/v1/auth/activate", body={"token": token, "new_password": "Owner-Chosen-2026!"})[0]
    reused = http("POST", base + "/api/v1/auth/activate", body={"token": token, "new_password": "Another-Pass-2026!"})[0]
    logged_in = http("POST", base + "/api/v1/auth/login", body={"email": email, "password": "Owner-Chosen-2026!"})[0]
    resend_active = http("POST", base + f"/api/v1/site-admin/home-owners/{unit}/resend-activation", token=ctx.manager, body={})[0]

    # S5: a login email change waits for the new address.
    new_email = f"moved-{suffix}@example.com"
    updated, updated_body = http("PUT", base + f"/api/v1/site-admin/home-owners/{unit}", token=ctx.manager, body={"email": new_email})
    still_old = ctx.psql.run(db, f"SELECT count(*) FROM users WHERE email='{email}';") == "1"
    pending = updated == 200 and json.loads(updated_body).get("pending_email_changes", [{}])[0].get("new_email") == new_email

    # S9: archiving deactivates the account instead of deleting it.
    removed = http("DELETE", base + f"/api/v1/site-admin/home-owners/{unit}", token=ctx.manager)[0]
    kept = ctx.psql.run(db, f"SELECT is_active::text FROM users WHERE email='{email}';")
    # Reusing the retired identity must work before any read-model reload or restart.
    replacement, _ = http("POST", base + "/api/v1/site-admin/home-owners", token=ctx.manager,
                          body=_owner_body(800 + int(suffix[-2:]), email, "Replacement Owner"))
    active_accounts = ctx.psql.run(db, f"SELECT count(*) FROM users WHERE lower(email)='{email}' AND is_active;")
    archived_people = ctx.psql.run(db, f"SELECT count(*) FROM persons WHERE lower(email)='{email}' AND deleted_at IS NOT NULL;")
    ok = (no_password and sent and blocked == 401 and activated == 204 and reused == 400 and logged_in == 200
          and resend_active == 409 and pending and still_old and removed == 204 and kept == "false" and replacement == 201 and active_accounts == "1" and archived_people == "1")
    return ok, (f"no password {no_password}, sent {sent}, pre-activation login {blocked}, activate {activated}, reuse {reused}, "
                f"login {logged_in}, resend on active {resend_active}, email change pending {pending} old kept {still_old}, "
                f"archive {removed} account kept inactive {kept}, replacement {replacement}, active accounts {active_accounts}, archived people {archived_people}")


def check_person_directory_and_export(ctx: Context) -> Tuple[bool, str]:
    """F1/U3/F8: directory search and paging, site-scoped profile, step-up audited export."""
    db, base = ctx.backend.db_name, ctx.backend.base
    suffix = str(time.time_ns())[-9:]
    email = f"directory-{suffix}@example.com"
    status, body = http("POST", base + "/api/v1/site-admin/home-owners", token=ctx.manager,
                        body=_owner_body(500 + int(suffix[-2:]), email, f"Directory Person {suffix}"))
    if status != 201:
        return False, f"registration {status} {body[:160]}"
    found_status, found_body = http("GET", base + f"/api/v1/site-admin/persons?q=directory-{suffix}&page_size=5", token=ctx.manager)
    page = json.loads(found_body) if found_status == 200 else {}
    items = page.get("items", [])
    found = len(items) == 1 and items[0]["email"] == email and items[0]["login"] == "PENDING" and items[0]["role"] == "HOME_OWNER"
    pending_filter = http("GET", base + "/api/v1/site-admin/persons?login=PENDING&page_size=100", token=ctx.manager)
    pending_ok = pending_filter[0] == 200 and any(i["email"] == email for i in json.loads(pending_filter[1])["items"])
    bad_filter = http("GET", base + "/api/v1/site-admin/persons?role=ADMIN", token=ctx.manager)[0]
    person_id = items[0]["person_id"] if items else 0
    profile_status, profile_body = http("GET", base + f"/api/v1/site-admin/persons/{person_id}", token=ctx.manager)
    units = json.loads(profile_body).get("units", []) if profile_status == 200 else []
    profile_ok = any(u["relation"] == "OWNER" and u["active"] for u in units)
    # Another site's person is not visible.
    foreign = ctx.psql.run(db, f"""INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
        VALUES ('Directory Site {suffix}', 'Bursa', 'directory-{suffix}', 'ACTIVE', 'STANDARD', CURRENT_DATE + 365) RETURNING id;""").strip()
    foreign_person = ctx.psql.run(db, f"INSERT INTO persons (full_name, email, person_type, site_id) VALUES ('Foreign', 'foreign-{suffix}@example.com', 'HOME_OWNER', {foreign}) RETURNING id;").strip()
    foreign_status = http("GET", base + f"/api/v1/site-admin/persons/{foreign_person}", token=ctx.manager)[0]
    # U7: moving in "an existing person" only accepts this site's people.
    unit_for_move = json.loads(body)["unit_id"]
    foreign_move = http("POST", base + f"/api/v1/site-admin/units/{unit_for_move}/move-in", token=ctx.manager,
                        body={"person_id": int(foreign_person), "role": "TENANT"})[0]
    # Export: refused without a fresh password check, audited with one.
    passwords = getattr(ctx.backend, "passwords", {})
    plain = http("POST", base + "/api/v1/auth/login", body={"email": "mehmet.demir@begonya.com",
                 "password": passwords.get("mehmet.demir@begonya.com", "mehmet123")})
    unstepped = json.loads(plain[1])["access_token"] if plain[0] == 200 else ""
    no_step_up = http("GET", base + "/api/v1/site-admin/persons/export", token=unstepped)
    export_status, export_body = http("GET", base + f"/api/v1/site-admin/persons/export?q=directory-{suffix}", token=ctx.manager)
    exported = export_status == 200 and email in export_body and export_body.startswith("\ufeffperson_id")
    audited = ctx.psql.run(db, "SELECT count(*) FROM audit_events WHERE action='PERSON_DIRECTORY_EXPORTED';")
    ok = (found and pending_ok and bad_filter == 400 and profile_ok and foreign_status == 404 and foreign_move == 404
          and no_step_up[0] == 403 and "STEP_UP" in no_step_up[1] and exported and int(audited) >= 1)
    return ok, (f"search {found}, pending filter {pending_ok}, bad filter {bad_filter}, profile owner {profile_ok}, "
                f"foreign profile {foreign_status}, foreign move-in {foreign_move}, export without step-up {no_step_up[0]}, export {export_status} "
                f"contains {exported}, audited {audited}")


def check_person_records_and_import(ctx: Context) -> Tuple[bool, str]:
    """F10/F7/F9/F8: national ID (hashed, step-up, audited), preferences, duplicate check, CSV import."""
    db, base = ctx.backend.db_name, ctx.backend.base
    suffix = str(time.time_ns())[-9:]
    email = f"records-{suffix}@example.com"
    status, body = http("POST", base + "/api/v1/site-admin/home-owners", token=ctx.manager,
                        body=_owner_body(400 + int(suffix[-2:]), email, f"Records Person {suffix}"))
    if status != 201:
        return False, f"registration {status} {body[:160]}"
    person = ctx.psql.run(db, f"SELECT id FROM persons WHERE lower(email)='{email}';").strip()
    other = ctx.psql.run(db, f"""INSERT INTO persons (full_name, email, person_type, site_id)
        SELECT 'Other Records {suffix}', 'other-{suffix}@example.com', 'HOME_OWNER', site_id FROM persons WHERE id={person} RETURNING id;""").strip()
    # F10: a valid TCKN is stored only as hash and mask; a bad one, a duplicate or a missing step-up is refused.
    tckn = "10000000146"
    ctx.psql.run(db, f"UPDATE persons SET national_id_hash=NULL, national_id_masked=NULL WHERE national_id_masked='*******0146' AND site_id=(SELECT site_id FROM persons WHERE id={person});")
    set_status, set_body = http("PUT", base + f"/api/v1/site-admin/persons/{person}/national-id", token=ctx.manager, body={"national_id": tckn})
    masked = set_status == 200 and json.loads(set_body).get("national_id_masked") == "*******0146"
    stored = ctx.psql.run(db, f"SELECT (national_id IS NULL AND national_id_hash IS NOT NULL)::text FROM persons WHERE id={person};") == "true"
    invalid = http("PUT", base + f"/api/v1/site-admin/persons/{other}/national-id", token=ctx.manager, body={"national_id": "10000000147"})[0]
    taken = http("PUT", base + f"/api/v1/site-admin/persons/{other}/national-id", token=ctx.manager, body={"national_id": tckn})[0]
    passwords = getattr(ctx.backend, "passwords", {})
    plain = http("POST", base + "/api/v1/auth/login", body={"email": "mehmet.demir@begonya.com",
                 "password": passwords.get("mehmet.demir@begonya.com", "mehmet123")})
    unstepped = json.loads(plain[1])["access_token"] if plain[0] == 200 else ""
    no_step_up = http("PUT", base + f"/api/v1/site-admin/persons/{other}/national-id", token=unstepped, body={"national_id": tckn})
    audited = ctx.psql.run(db, f"SELECT count(*) FROM audit_events WHERE action='PERSON_NATIONAL_ID_SET' AND resource_id='{person}';")
    # F7: preferences are saved and shown on the profile; an unknown channel is refused.
    prefs = {"preferred_channel": "sms", "preferred_language": "en",
             "emergency_contact_name": "Acil Kisi", "emergency_contact_phone": "0532 999 88 77"}
    pref_status = http("PUT", base + f"/api/v1/site-admin/persons/{person}/preferences", token=ctx.manager, body=prefs)[0]
    bad_pref = http("PUT", base + f"/api/v1/site-admin/persons/{person}/preferences", token=ctx.manager,
                    body={"preferred_channel": "FAX", "preferred_language": "tr"})[0]
    profile_status, profile_body = http("GET", base + f"/api/v1/site-admin/persons/{person}", token=ctx.manager)
    record = json.loads(profile_body).get("record", {}) if profile_status == 200 else {}
    profile_ok = (record.get("national_id_masked") == "*******0146" and record.get("preferences", {}).get("preferred_channel") == "SMS"
                  and len(record.get("consents", [])) == 4)
    # F9: the same national ID or email is reported before a second record is made.
    dup_status, dup_body = http("POST", base + "/api/v1/site-admin/persons/duplicate-check", token=ctx.manager,
                                body={"full_name": "someone else", "email": email.upper(), "national_id": tckn})
    dups = json.loads(dup_body) if dup_status == 200 else []
    dup_ok = any(d["person"]["person_id"] == int(person) and {"SAME_NATIONAL_ID", "SAME_EMAIL"} <= set(d["reasons"]) for d in dups)
    # F8: a dry run changes nothing, a commit registers every row, a repeat is refused row by row.
    block = f"I{suffix[-5:]}"
    csv_text = ("block;unit_no;floor;owner_full_name;owner_email;owner_phone;land_share;monthly_dues;is_resident;tenant_full_name;tenant_email;tenant_phone\n"
                f"{block} Blok;1;1;Import One {suffix};import1-{suffix}@example.com;0532 {suffix[-3:]} 10 01;10;1.250,50;evet;;;\n"
                f"{block} Blok;2;1;Import Two {suffix};import2-{suffix}@example.com;0532 {suffix[-3:]} 10 02;;;hayır;Import Tenant {suffix};import3-{suffix}@example.com;0532 {suffix[-3:]} 10 03\n")
    dry_status, dry_body = http("POST", base + "/api/v1/site-admin/persons/import", token=ctx.manager, body={"csv": csv_text, "dry_run": True})
    dry = json.loads(dry_body) if dry_status == 200 else {}
    untouched = ctx.psql.run(db, f"SELECT count(*) FROM users WHERE email LIKE 'import_-{suffix}@example.com';") == "0"
    commit_status, commit_body = http("POST", base + "/api/v1/site-admin/persons/import", token=ctx.manager, body={"csv": csv_text})
    commit = json.loads(commit_body) if commit_status == 200 else {}
    accounts = ctx.psql.run(db, f"SELECT count(*) FROM users WHERE email LIKE 'import_-{suffix}@example.com';")
    dues = ctx.psql.run(db, f"""SELECT count(*) FROM units u JOIN blocks b ON b.id=u.block_id WHERE b.block_name ILIKE '{block}%' AND u.deleted_at IS NULL;""")
    repeat = http("POST", base + "/api/v1/site-admin/persons/import", token=ctx.manager, body={"csv": csv_text})
    repeated = json.loads(repeat[1]) if repeat[0] == 200 else {}
    import_audit = ctx.psql.run(db, "SELECT count(*) FROM audit_events WHERE action='PERSON_IMPORT_COMMITTED';")
    ok = (masked and stored and invalid == 400 and taken == 409 and no_step_up[0] == 403 and "STEP_UP" in no_step_up[1]
          and int(audited) == 1 and pref_status == 200 and bad_pref == 400 and profile_ok and dup_ok
          and dry.get("invalid") == 0 and dry.get("committed") is False and untouched
          and commit.get("created") == 2 and accounts == "3" and dues == "2"
          and repeated.get("committed") is False and repeated.get("invalid") == 2 and int(import_audit) >= 1)
    return ok, (f"national id set {set_status} masked {masked} hashed {stored}, invalid {invalid}, taken {taken}, no step-up {no_step_up[0]}, "
                f"audited {audited}, preferences {pref_status} bad {bad_pref}, profile record {profile_ok}, duplicates {dup_ok}, "
                f"dry run {dry_status} invalid {dry.get('invalid')} untouched {untouched}, commit {commit_status} created {commit.get('created')} "
                f"accounts {accounts} units {dues}, repeat invalid {repeated.get('invalid')}, import audited {import_audit}")


CHECK_FUNCS: Dict[str, Callable[[Context], Tuple[bool, str]]] = {
    "person_records_and_import": check_person_records_and_import,
    "person_directory_and_export": check_person_directory_and_export,
    "person_tenant_isolation": check_person_tenant_isolation,
    "person_activation_lifecycle": check_person_activation_lifecycle,
    "invitation_atomic_registration":check_invitation_atomic_registration,
    "household_members_persisted":check_household_members,
    "support_grant_lifecycle":check_support_grant_lifecycle,
    "security_session_lifecycle":check_security_session_lifecycle,
    "transactional_audit":check_transactional_audit,
    "audit_scope_and_privileges":check_audit_scope_and_privileges,
    "registration_repository_scope":check_registration_repository_scope,
    "unauthenticated_routes_rejected": check_unauthenticated,
    "forged_token_rejected": check_forged,
    "cross_site_forbidden": check_cross_site,
    "webhook_signature_enforced": check_webhook,
    "concurrent_receipts_unique": check_concurrent,
    "idempotent_payment_retry": check_idempotent,
    "restart_persistence": check_restart,
    "sequences_survive_restart": check_sequences,
    "match_all_settles_in_place": check_match_all_in_place,
    "payer_identity_recorded": check_payer_identity,
    "site_purge_is_atomic": check_site_purge,
    "tenant_surplus_virman": check_tenant_surplus_virman,
    "reversal_restores_ledger": check_reversal,
    "webhook_claim_scoped": check_webhook_claim,
    "issuer_snapshot_on_receipt": check_issuer_snapshot,
    "debt_aging_snapshot_persisted": check_aging_snapshot,
    "virman_reversal_restores_advance": check_virman_reversal,
    "resident_statement_scoped": check_resident_statement,
    "receipt_pdf_and_verification": check_receipt_pdf,
    "card_payment_via_provider": check_card_payment,
    "budget_accrual_legal_basis": check_budget_accrual,
    "ledger_integrity_clean": check_ledger_integrity,
    "finance_desk_over_http": check_finance_desk,
    "exit_settlement_self_approval_audited": check_exit_settlement_self_approval_audited,
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
                # Check at each boundary: later payments must not conceal earlier drift.
                if name != "ledger_integrity_clean":
                    clean, evidence = check_ledger_integrity(ctx)
                    if not clean:
                        ok = False
                        detail += "; ledger postcondition: " + evidence
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
