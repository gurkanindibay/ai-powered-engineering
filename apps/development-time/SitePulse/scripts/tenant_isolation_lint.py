#!/usr/bin/env python3
"""Multi-tenant isolation guardrails for the SitePulse Rust backend.

Static rules that keep one tenant's (site's) data out of another's reach. Each
rule encodes a leak class that was found in the codebase and fixed:

  unscoped-site-input         A handler accepts a request type with a `site_id`
                              field (Query/Json) but takes no `TenantScope`
                              (or `Claims`). The middleware check is heuristic;
                              handlers must pin the site through the scope.
                              (Leak fixed: /payments/homeowner-records.)
  unscoped-object-path        A route carries an object id in its path that the
                              middleware cannot attribute to a site (anything
                              but unit and bank-account paths), and its handler
                              takes no `TenantScope`/`Claims`, so nothing checks
                              that the object belongs to the caller's site.
                              (Leak fixed: /capital-projects/:id, including the
                              installment accrual and disbursement writes.)
                              An `AuthzContext` handler counts as scoped when it
                              calls `ctx.require(..)`, pins via `TenantScope`,
                              takes the site from the token (`ctx.claims..`),
                              passes the caller context (`&ctx`) to a service
                              that looks objects up by the caller's site, or
                              states `// tenant-scope: checked in <Service::fn>`.
  guessed-tenant              Production code falls back to a hard-coded tenant
                              (`"1"`, `"site-1"`, `"site-begonya"`) when a site
                              is unknown, attributing data to some other site.
                              `src/state.rs` (dev fixtures) and `#[cfg(test)]`
                              modules are exempt.
  unbound-tenant-transaction  A transaction opened in `src/services/` is not
                              bound to its tenant with `tx_bind_tenant` (row-
                              level security, V21). Platform-wide transactions
                              opt out with a `// tenant-guard: platform` comment.
  rls-coverage                A table with a tenant key column (`site_id`,
                              `unit_id`, `payment_entry_id`, `project_id`,
                              `budget_id`) is never passed to
                              `sp_enable_tenant_rls`, so PostgreSQL would not
                              isolate it. Identity tables that span tenants are
                              listed in RLS_EXEMPT.

Usage:
    python3 scripts/tenant_isolation_lint.py            # human-readable
    python3 scripts/tenant_isolation_lint.py --json     # gate `tenant-lint`
    python3 scripts/tenant_isolation_lint.py --backend path/to/backend

Exit code 0 when there are no findings, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BACKEND = ROOT / "backend"

SCOPE_MARKERS = ("TenantScope", "Claims")
GUESSED_TENANT_RE = re.compile(
    r'unwrap_or_else\(\s*\|\|\s*"(?:1|site-\w+)"\s*\.to_string\(\)\s*\)'
    r'|unwrap_or\(\s*"(?:1|site-\w+)"\s*\)'
    r'|"site-begonya"'
)
# Path families whose id the auth middleware resolves to a site itself
# (auth::path_unit_id / auth::path_site_id), plus public and platform routes.
MIDDLEWARE_SCOPED_PATHS = (
    "/api/v1/residents/:", "/api/v1/units/:",
    "/api/v1/home-residents/invite-link/:", "/api/v1/home-residents/members/:",
    "/api/v1/site-admin/units/:", "/api/v1/site-admin/home-owners/:",
    "/api/v1/site-admin/bank-account/:",
)
NOT_TENANT_PATHS = (
    "/api/v1/saas", "/api/v1/system/", "/api/v1/registration/submit/",
    "/api/v1/payment-provider/sandbox/", "/api/v1/public/",
)
ROUTE_OPEN_RE = re.compile(r'\.route\(\s*"([^"]+)"')
ROUTE_TABLE_RE = re.compile(r'\b(?:get|post|put|patch|delete)\s+"([^"]+)"\s*=>\s*handlers::(\w+)')
TX_OPEN_RE = re.compile(r"\.transaction\(\)|\.build_transaction\(\)")
TX_BIND_WINDOW = 30
PLATFORM_MARKER = "tenant-guard: platform"
DELEGATED_MARKER = "tenant-scope: checked in"
TENANT_KEYS = ("site_id", "unit_id", "payment_entry_id", "project_id", "budget_id")
# Tables whose rows legitimately span tenants (identity, platform settings) or
# that are tenant roots handled explicitly.
RLS_EXEMPT = {
    "users",            # login identity: looked up by email before the tenant is known
    "user_site_roles",  # role membership across sites (SaaS administration)
    "persons",          # natural persons can own units in several sites
    "auth_sessions",    # identity: sessions are resolved before a tenant is known
    "audit_events",     # append-only audit trail, nullable site, written from platform contexts
    "financial_access_log",      # append-only access audit, nullable site (platform reads)
    "management_company_sites",  # one management company spans several sites
    "schema_migrations",
}


@dataclass
class Finding:
    rule: str
    file: str
    line: int
    message: str


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _strip_test_modules(code: str) -> str:
    """Drops `#[cfg(test)]` modules (by convention at the end of a file)."""
    idx = code.find("#[cfg(test)]")
    return code if idx < 0 else code[:idx]


def _strip_comments(code: str) -> str:
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), code)


def _signature(code: str, open_paren: int) -> str:
    depth, i = 0, open_paren
    while i < len(code):
        c = code[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return code[open_paren + 1 : i]
        i += 1
    return code[open_paren + 1 :]


def site_bearing_types(src: Path) -> set[str]:
    types: set[str] = set()
    for f in src.rglob("*.rs"):
        text = f.read_text(encoding="utf-8")
        for m in re.finditer(r"pub struct (\w+)\s*\{(.*?)\n\}", text, re.S):
            if re.search(r"\bpub site_id\s*:", m.group(2)):
                types.add(m.group(1))
    return types


def _body(code: str, after_sig: int) -> str:
    """The handler body following its signature (brace-balanced)."""
    start = code.find("{", after_sig)
    if start < 0:
        return ""
    depth = 0
    for i in range(start, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return code[start : i + 1]
    return code[start:]


def _is_scoped(sig: str, body: str) -> bool:
    """`TenantScope`/`Claims` in the signature, or an `AuthzContext` whose
    handler actually checks the site (`ctx.require(..)` or a `TenantScope`)."""
    if any(marker in sig for marker in SCOPE_MARKERS):
        return True
    if "AuthzContext" not in sig:
        return False
    # The check may live in the service the context is passed to; that has to be
    # stated explicitly (`// tenant-scope: checked in <Service::method>`).
    if ".require(" in body or "TenantScope::from_claims" in body or DELEGATED_MARKER in body:
        return True
    # Site taken from the verified token, or the caller context handed to the
    # service (master's convention: services look objects up by the caller's site).
    return bool(re.search(r"\bctx\.claims\b|[(,]\s*&ctx\b", body))


def lint_handlers(backend: Path, findings: list[Finding]) -> None:
    src = backend / "src"
    handlers = src / "handlers"
    if not handlers.is_dir():
        return
    site_types = site_bearing_types(src)
    for f in sorted(handlers.rglob("*.rs")):
        rel = f.relative_to(backend).as_posix()
        code = _strip_test_modules(f.read_text(encoding="utf-8"))
        for m in re.finditer(r"pub async fn (\w+)\s*\(", code):
            sig = _signature(code, m.end() - 1)
            inputs = re.findall(r"(?:Query|Json)\s*<\s*(?:[\w:]*::)?(\w+)\s*>", sig)
            bearing = [t for t in inputs if t in site_types]
            if bearing and not _is_scoped(sig, _body(code, m.end())):
                findings.append(Finding(
                    "unscoped-site-input", rel, _line_of(code, m.start()),
                    f"`{m.group(1)}` accepts {', '.join(bearing)} (has `site_id`) without a "
                    "`TenantScope`; add `scope: crate::tenancy::TenantScope` and pin the site"))


def handler_signatures(backend: Path) -> tuple[dict[str, str], dict[str, str]]:
    sigs: dict[str, str] = {}
    bodies: dict[str, str] = {}
    for f in (backend / "src" / "handlers").rglob("*.rs"):
        code = _strip_test_modules(f.read_text(encoding="utf-8"))
        for m in re.finditer(r"pub async fn (\w+)\s*\(", code):
            sig = _signature(code, m.end() - 1)
            sigs[m.group(1)] = sig
            bodies[m.group(1)] = _body(code, m.end() - 1 + len(sig) + 2)
    return sigs, bodies


def lint_object_paths(backend: Path, findings: list[Finding]) -> None:
    app = backend / "src" / "app.rs"
    if not app.is_file() or not (backend / "src" / "handlers").is_dir():
        return
    code = app.read_text(encoding="utf-8")
    sigs, bodies = handler_signatures(backend)
    routes: list[tuple[str, list[str], int]] = []
    # Builder style: .route("/path", get(handlers::a).post(handlers::b))
    for m in ROUTE_OPEN_RE.finditer(code):
        body = _signature(code, code.index("(", m.start()))
        routes.append((m.group(1), re.findall(r"handlers::(\w+)", body), m.start()))
    # Table style: post "/path" => handlers::name, Require(...);
    for m in ROUTE_TABLE_RE.finditer(code):
        routes.append((m.group(1), [m.group(2)], m.start()))
    if not routes:
        findings.append(Finding(
            "unscoped-object-path", "src/app.rs", 1,
            "no routes could be parsed from src/app.rs: update ROUTE_OPEN_RE / ROUTE_TABLE_RE in "
            "tenant_isolation_lint.py so this rule keeps checking object-id routes"))
        return
    for path, handlers, offset in routes:
        if ":" not in path or path.startswith(MIDDLEWARE_SCOPED_PATHS) or path.startswith(NOT_TENANT_PATHS):
            continue
        for handler in handlers:
            sig = sigs.get(handler)
            if sig is None or _is_scoped(sig, bodies.get(handler, "")):
                continue
            findings.append(Finding(
                "unscoped-object-path", "src/app.rs", _line_of(code, offset),
                f"`{path}` -> `{handler}`: the path id is not attributable to a site by the "
                "middleware; take a `TenantScope` and check the object's site (404 if foreign)"))


def lint_guessed_tenants(backend: Path, findings: list[Finding]) -> None:
    src = backend / "src"
    for f in sorted(src.rglob("*.rs")):
        rel = f.relative_to(backend).as_posix()
        if rel == "src/state.rs":
            continue  # development fixtures, never loaded with a database
        code = _strip_comments(_strip_test_modules(f.read_text(encoding="utf-8")))
        for m in GUESSED_TENANT_RE.finditer(code):
            findings.append(Finding(
                "guessed-tenant", rel, _line_of(code, m.start()),
                f"hard-coded tenant fallback `{m.group(0)}`: an unknown site must stay "
                "unattributed (empty), never become another tenant"))


def lint_transactions(backend: Path, findings: list[Finding]) -> None:
    services = backend / "src" / "services"
    if not services.is_dir():
        return
    for f in sorted(services.rglob("*.rs")):
        rel = f.relative_to(backend).as_posix()
        code = _strip_test_modules(f.read_text(encoding="utf-8"))
        lines = code.splitlines()
        for i, line in enumerate(lines):
            if not TX_OPEN_RE.search(line):
                continue
            window = "\n".join(lines[max(0, i - 3) : i + TX_BIND_WINDOW])
            if "tx_bind_tenant" in window or PLATFORM_MARKER in window:
                continue
            findings.append(Finding(
                "unbound-tenant-transaction", rel, i + 1,
                "transaction is not bound to its tenant: call `crate::db::tx_bind_tenant(&tx, site)` "
                f"first (or mark a platform-wide transaction with `// {PLATFORM_MARKER}`)"))


def tenant_keyed_tables(migrations: Path) -> dict[str, str]:
    """Table -> migration file that gave it a tenant key column."""
    tables: dict[str, str] = {}
    keys = "|".join(TENANT_KEYS)
    for f in sorted(migrations.glob("V*.sql"), key=lambda p: int(re.match(r"V(\d+)", p.name).group(1))):
        sql = re.sub(r"--[^\n]*", "", f.read_text(encoding="utf-8"))
        for m in re.finditer(r"CREATE TABLE (?:IF NOT EXISTS )?(\w+)\s*\((.*?)\n\s*\)\s*;", sql, re.S | re.I):
            if re.search(rf"^\s*({keys})\s", m.group(2), re.M | re.I):
                tables.setdefault(m.group(1).lower(), f.name)
        for m in re.finditer(rf"ALTER TABLE (?:IF EXISTS )?(\w+)\s+ADD COLUMN (?:IF NOT EXISTS )?({keys})\b", sql, re.I):
            tables.setdefault(m.group(1).lower(), f.name)
    return tables


def rls_enabled_tables(migrations: Path) -> set[str]:
    enabled: set[str] = set()
    for f in migrations.glob("V*.sql"):
        sql = f.read_text(encoding="utf-8")
        for m in re.finditer(r"sp_enable_tenant_rls\(\s*'(\w+)'", sql):
            enabled.add(m.group(1).lower())
        # SELECT sp_enable_tenant_rls(t, ...) FROM unnest(ARRAY['a', 'b']) AS t;
        for m in re.finditer(r"sp_enable_tenant_rls\(\s*t\b.*?unnest\(\s*ARRAY\[(.*?)\]", sql, re.S):
            enabled.update(x.lower() for x in re.findall(r"'(\w+)'", m.group(1)))
    return enabled


def lint_rls(backend: Path, findings: list[Finding]) -> None:
    migrations = backend / "migrations"
    if not migrations.is_dir():
        return
    keyed = tenant_keyed_tables(migrations)
    enabled = rls_enabled_tables(migrations)
    for table, origin in sorted(keyed.items()):
        if table in enabled or table in RLS_EXEMPT:
            continue
        findings.append(Finding(
            "rls-coverage", f"migrations/{origin}", 1,
            f"table `{table}` has a tenant key but no row-level security policy: add it to "
            "`sp_enable_tenant_rls` in a new migration (or to RLS_EXEMPT with a reason)"))


def lint(backend: Path) -> dict:
    findings: list[Finding] = []
    lint_handlers(backend, findings)
    lint_object_paths(backend, findings)
    lint_guessed_tenants(backend, findings)
    lint_transactions(backend, findings)
    lint_rls(backend, findings)
    return {
        "passed": not findings,
        "findings": [asdict(f) for f in findings],
        "counts": {rule: sum(1 for f in findings if f.rule == rule) for rule in sorted({f.rule for f in findings})},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="Print a JSON report")
    parser.add_argument("--backend", type=Path, default=DEFAULT_BACKEND, help="Backend crate directory")
    args = parser.parse_args(argv)
    report = lint(args.backend)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for f in report["findings"]:
            print(f"{f['file']}:{f['line']}: [{f['rule']}] {f['message']}")
        print(f"tenant-isolation-lint: {len(report['findings'])} findings -> {'PASS' if report['passed'] else 'FAIL'}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
