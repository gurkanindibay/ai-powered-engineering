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
                              opt in with `tx_bind_platform` and document it with
                              a `// tenant-guard: platform` comment; the comment
                              without that bind is itself a finding.
  platform-marker-unbound     A `// tenant-guard: platform` comment claims a
                              platform path without the `tx_bind_platform` or
                              `begin_platform_read`/`begin_platform_tx` call that
                              makes it one, so the query still fails closed at
                              runtime. Bind the platform scope or drop the marker.
  unbound-pool-query          A pooled connection queries a tenant table anywhere in
                              `src/` without `begin_tenant_read`/`begin_tenant_tx`
                              or an explicitly bound platform read: unbound reads
                              return no rows and writes are rejected by row-level
                              security.
  rls-coverage                A table with a tenant key column (`site_id`,
                              `unit_id`, `payment_entry_id`, `project_id`,
                              `budget_id`, or a parent key that resolves the
                              tenant through another table) is never passed to
                              `sp_enable_tenant_rls`, so PostgreSQL would not
                              isolate it. Identity tables that span tenants are
                              listed in `scripts/tenant_rls_config.json` exemptions.
  rls-parent-predicate        A table that reaches its tenant through a parent
                              key has a policy whose predicate does not mention
                              that parent, so a copy-paste policy could point at
                              the wrong table and pass unnoticed.

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
    "/api/v1/residents/{", "/api/v1/units/{",
    "/api/v1/home-residents/invite-link/{", "/api/v1/home-residents/members/{",
    "/api/v1/site-admin/units/{", "/api/v1/site-admin/home-owners/{",
    "/api/v1/site-admin/bank-account/{",
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
PLATFORM_BIND_RE = re.compile(r"\b(?:tx_bind_platform|begin_platform_read|begin_platform_tx)\b")
# Files that legitimately open owner-only transactions: the guard helpers themselves and
# the DDL migration runner, which must run as the schema owner and cannot be bound.
SCHEMA_OWNER_FILES = {"src/db/tenant_guard.rs", "src/migrations.rs"}
DELEGATED_MARKER = "tenant-scope: checked in"
TENANT_RLS_CONFIG = json.loads((ROOT / "scripts/tenant_rls_config.json").read_text())
TENANT_KEYS = tuple(TENANT_RLS_CONFIG["tenant_keys"])
# Child tables reach their tenant through a parent whose own policy resolves the
# site (V53). A table with one of these keys and no direct tenant key still has
# to be passed to `sp_enable_tenant_rls`, with the parent-subselect predicate.
PARENT_TENANT_KEYS = TENANT_RLS_CONFIG["parent_tenant_keys"]
# Tables whose rows legitimately span tenants (identity, platform settings) or
# that are tenant roots handled explicitly.
RLS_EXEMPT = set(TENANT_RLS_CONFIG["exemptions"])


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
    src = backend / "src"
    if not src.is_dir():
        return
    for f in sorted(src.rglob("*.rs")):
        rel = f.relative_to(backend).as_posix()
        if rel in SCHEMA_OWNER_FILES:
            continue
        code = _strip_test_modules(f.read_text(encoding="utf-8"))
        lines = code.splitlines()
        for i, line in enumerate(lines):
            if not TX_OPEN_RE.search(line):
                continue
            before = "\n".join(lines[max(0, i - 3) : i + TX_BIND_WINDOW])
            if PLATFORM_MARKER in before and not PLATFORM_BIND_RE.search(before):
                # The comment claims a platform transaction, so the bind it justifies
                # must be there too: an unbound one fails closed at runtime instead.
                findings.append(Finding(
                    "platform-marker-unbound", rel, i + 1,
                    f"`// {PLATFORM_MARKER}` without `crate::db::tx_bind_platform(&tx)`: "
                    "either bind the platform transaction or drop the marker"))
                continue
            if (
                "tx_bind_tenant" in before
                or "tx_bind_platform" in before
                or PLATFORM_MARKER in before
            ):
                continue
            findings.append(Finding(
                "unbound-tenant-transaction", rel, i + 1,
                "transaction is not bound to its tenant: call `crate::db::tx_bind_tenant(&tx, site)` "
                f"or `tx_bind_platform(&tx)` first (or mark with `// {PLATFORM_MARKER}`)"))


def _tenant_table_names(backend: Path) -> set[str]:
    migrations = backend / "migrations"
    if not migrations.is_dir():
        return set()
    tables = (
        set(rls_policies(migrations).keys())
        | set(tenant_keyed_tables(migrations).keys())
        | set(TENANT_RLS_CONFIG["root_tables"])
    )
    tables -= RLS_EXEMPT
    # A view over tenant tables is as tenant-scoped as the tables behind it: a query
    # through one is just as unbound (V33 views, for example, hid two real leaks).
    return tables | _tenant_view_names(migrations, tables)


def _tenant_view_names(migrations: Path, tenant_tables: set[str]) -> set[str]:
    """Views whose definition reads at least one tenant table (latest definition wins)."""
    definitions: dict[str, str] = {}
    for f in sorted(migrations.glob("V*.sql"), key=lambda p: int(re.match(r"V(\d+)", p.name).group(1))):
        sql = re.sub(r"--[^\n]*", "", f.read_text(encoding="utf-8"))
        for m in re.finditer(
            r"CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+(\w+).*?;", sql, re.S | re.I
        ):
            definitions[m.group(1).lower()] = m.group(0)
    if not definitions:
        return set()
    body_re = re.compile(r"\b(?:" + "|".join(sorted(tenant_tables)) + r")\b")
    return {name for name, ddl in definitions.items() if body_re.search(ddl)}


def lint_pool_queries(backend: Path, findings: list[Finding]) -> None:
    src = backend / "src"
    if not src.is_dir():
        return
    tenant_tables = _tenant_table_names(backend)
    if not tenant_tables:
        return
    table_re = re.compile(r"\b(?:" + "|".join(sorted(tenant_tables)) + r")\b")
    tx_helper_re = re.compile(
        r"\b(?:begin_tenant_read|begin_tenant_tx|begin_platform_read|begin_platform_tx)\b"
    )
    # A pool acquisition: `pool.get()`, the shared security connection, or the
    # `state.pool.as_ref()...get().await` form the handlers and services use.
    conn_re = re.compile(
        r"\b(?:pool\.get|security_connection)\(|\.get\(\)\s*\.\s*await"
    )
    for f in sorted(src.rglob("*.rs")):
        rel = f.relative_to(backend).as_posix()
        if rel in ("src/db/tenant_guard.rs", "src/db/security_repository.rs"):
            continue
        code = _strip_test_modules(f.read_text(encoding="utf-8"))
        fn_starts = [
            m.start()
            for m in re.finditer(r"(?m)^[ \t]*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+\w+", code)
        ]
        for m in conn_re.finditer(code):
            pos = m.start()
            # Scope to the enclosing function body.
            fn_start = max((s for s in fn_starts if s <= pos), default=0)
            fn_end = next((s for s in fn_starts if s > pos), len(code))
            fn_slice = code[fn_start:fn_end]
            if PLATFORM_MARKER in fn_slice and not PLATFORM_BIND_RE.search(fn_slice):
                # The comment claims a platform path, so the bind it justifies must be
                # in the same function: an unbound one fails closed at runtime instead.
                findings.append(Finding(
                    "platform-marker-unbound", rel, _line_of(code, pos),
                    f"`// {PLATFORM_MARKER}` without `begin_platform_read`/`begin_platform_tx`: "
                    "either bind the platform query or drop the marker"))
                continue
            if PLATFORM_MARKER in fn_slice:
                continue
            after_get = code[pos:fn_end]
            if TX_OPEN_RE.search(after_get) or tx_helper_re.search(after_get):
                continue
            sql_surface = _strip_comments(after_get)
            hit = table_re.search(sql_surface)
            if hit or "rec::" in sql_surface:
                target = hit.group(0) if hit else "finance record"
                findings.append(Finding(
                    "unbound-pool-query", rel, _line_of(code, pos),
                    f"direct pool query touches tenant table `{target}` without a bound "
                    "transaction: use `begin_tenant_read`/`begin_tenant_tx` (or "
                    f"`begin_platform_read`/`begin_platform_tx` with `// {PLATFORM_MARKER}`)"))


def tenant_keyed_tables(migrations: Path) -> dict[str, tuple[str, str | None]]:
    """Table -> (migration, parent table it reaches its tenant through, if any)."""
    tables: dict[str, tuple[str, str | None]] = {}
    keys = "|".join(TENANT_KEYS)
    parent_keys = "|".join(PARENT_TENANT_KEYS)
    for f in sorted(migrations.glob("V*.sql"), key=lambda p: int(re.match(r"V(\d+)", p.name).group(1))):
        sql = re.sub(r"--[^\n]*", "", f.read_text(encoding="utf-8"))
        for m in re.finditer(r"CREATE TABLE (?:IF NOT EXISTS )?(\w+)\s*\((.*?)\n\s*\)\s*;", sql, re.S | re.I):
            body = m.group(2)
            if re.search(rf"^\s*({keys})\s", body, re.M | re.I):
                tables.setdefault(m.group(1).lower(), (f.name, None))
                continue
            # A table that reaches its tenant only through a parent still needs a
            # policy, and that policy must resolve through the parent.
            parent = re.search(rf"^\s*({parent_keys})\s", body, re.M | re.I)
            if parent:
                tables.setdefault(
                    m.group(1).lower(), (f.name, PARENT_TENANT_KEYS[parent.group(1).lower()])
                )
        for m in re.finditer(
            rf"ALTER TABLE (?:IF EXISTS )?(\w+)\s+ADD COLUMN (?:IF NOT EXISTS )?({keys}|{parent_keys})\b",
            sql,
            re.I,
        ):
            column = m.group(2).lower()
            tables.setdefault(
                m.group(1).lower(), (f.name, PARENT_TENANT_KEYS.get(column))
            )
    return tables


def rls_policies(migrations: Path) -> dict[str, str]:
    """Table -> the predicate it was isolated with."""
    policies: dict[str, str] = {}
    for f in migrations.glob("V*.sql"):
        sql = f.read_text(encoding="utf-8")
        for m in re.finditer(r"sp_enable_tenant_rls\(\s*'(\w+)'\s*,\s*'((?:[^']|'')*)'", sql, re.S):
            policies[m.group(1).lower()] = m.group(2)
        # SELECT sp_enable_tenant_rls(t, ...) FROM unnest(ARRAY['a', 'b']) AS t;
        for m in re.finditer(r"sp_enable_tenant_rls\(\s*t\b.*?unnest\(\s*ARRAY\[(.*?)\]", sql, re.S):
            predicate = re.search(
                r"sp_enable_tenant_rls\(\s*t\s*,\s*'((?:[^']|'')*)'", sql[m.start():], re.S
            )
            for table in re.findall(r"'(\w+)'", m.group(1)):
                policies[table.lower()] = predicate.group(1) if predicate else ""
    return policies


def lint_rls(backend: Path, findings: list[Finding]) -> None:
    migrations = backend / "migrations"
    if not migrations.is_dir():
        return
    keyed = tenant_keyed_tables(migrations)
    policies = rls_policies(migrations)
    for table, (origin, parent) in sorted(keyed.items()):
        if table in RLS_EXEMPT:
            continue
        through = f" through `{parent}`" if parent else ""
        if table not in policies:
            findings.append(Finding(
                "rls-coverage", f"migrations/{origin}", 1,
                f"table `{table}` has a tenant key{through} but no row-level security policy: "
                "add it to `sp_enable_tenant_rls` in a new migration "
                "(or to RLS_EXEMPT with a reason)"))
        elif parent and parent not in policies[table]:
            findings.append(Finding(
                "rls-parent-predicate", f"migrations/{origin}", 1,
                f"table `{table}` reaches its tenant through `{parent}`, but its policy does not "
                f"mention that table: {policies[table]!r}"))


def lint(backend: Path) -> dict:
    findings: list[Finding] = []
    lint_handlers(backend, findings)
    lint_object_paths(backend, findings)
    lint_guessed_tenants(backend, findings)
    lint_transactions(backend, findings)
    lint_pool_queries(backend, findings)
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
