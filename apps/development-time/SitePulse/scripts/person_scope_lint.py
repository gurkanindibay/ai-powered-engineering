#!/usr/bin/env python3
"""Person-scope audit for the SitePulse Rust backend (issue #535).

`users`, `user_site_roles` and `persons` are identity tables, so they are not
protected by tenant row-level security (a session looks its own user up before a
site is known). That means a query against them has to state its scope itself:

  site      a `WHERE`, `HAVING` or `ON` predicate binds a site key to a parameter,
            a literal or `sp_tenant_site()`, so the statement is filtered by site;
            or an `INSERT` writes the site the caller serves.
  person    the statement keys on a person or user id that the caller resolved
            inside the site it is serving.
  identity  a global identity lookup (email, google_sub, session user id) where
            no site applies yet: sign-in, session validation, uniqueness checks,
            account activation.
  platform  startup load, migration, SaaS administration, provisioning or the
            development seed/reset.

The four annotations below are line comments placed immediately before the
statement they justify (within [`MARKER_WINDOW_LINES`] lines):

    // person-scope: site
    // person-scope: person
    // person-scope: identity
    // person-scope: platform

The rule is static and clause-aware: naming a site key in the `SELECT` list, a
`SET` clause, an `INSERT` column list or a conflict target does **not** scope a
statement; only a predicate that also binds a value does. A statement with no
such predicate needs an annotation, so the audit stays true for new code instead
of freezing today's review. It mirrors `tenant_isolation_lint.py`.

SQL assembled from several literals (`format!`, `concat!`) is checked literal by
literal: keep a scoped statement in one literal, or annotate it.

Usage:
    python3 scripts/person_scope_lint.py            # human-readable
    python3 scripts/person_scope_lint.py --json     # gate `person-scope-lint`
    python3 scripts/person_scope_lint.py --backend path/to/backend

Exit code 0 when every identity-table statement is scoped or annotated, 1
otherwise.
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

IDENTITY_TABLES = ("users", "user_site_roles", "persons")
IDENTITY_RE = re.compile(r"\b(?:" + "|".join(IDENTITY_TABLES) + r")\b", re.I)
SQL_RE = re.compile(
    r"\b(?:SELECT|INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|TRUNCATE)\b", re.I
)
# Clauses that carry a filter. `ON` here is a join condition, not `ON CONFLICT`.
CLAUSE_RE = re.compile(
    r"\b(WHERE|HAVING|ON(?!\s+CONFLICT)|GROUP\s+BY|ORDER\s+BY|LIMIT|OFFSET|RETURNING|"
    r"VALUES|SET|UNION|EXCEPT|INTERSECT)\b",
    re.I,
)
FILTER_CLAUSES = ("WHERE", "HAVING", "ON")
# A site key and a value it is compared with. Both must appear in the predicate:
# `site_id` in a SELECT list is not a filter, and `ON a.site_id = b.site_id` binds
# no value, so neither scopes the statement.
SITE_KEY_RE = re.compile(
    r"\b(?:site_id|sites?|units?|unit_occupancies|unit_ownerships|v_person_roles)\b", re.I
)
SITE_BIND_RE = re.compile(r"\$\d+|sp_tenant_site\(\)", re.I)
# Quoted SQL values are data, not identifiers: `'persons'` in an audit row is not
# a query against the persons table, and a hard-coded tenant id is not a scope.
SQL_VALUE_RE = re.compile(r"'(?:[^']|'')*'")
SCOPE_MARKER_RE = re.compile(
    r"//\s*person-scope:\s*(site|person|identity|platform)\b", re.I
)
# A marker may sit a few lines above the statement (a doc comment line, a blank
# line) but must not bless a second statement added later in the same function.
MARKER_WINDOW_LINES = 4
STRING_LITERAL_RE = re.compile(r'r#*"(?:[^"]|"(?!#))*"#*|"(?:[^"\\]|\\.)*"', re.S)
FN_START_RE = re.compile(r"(?m)^[ \t]*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+\w+")
CFG_TEST_RE = re.compile(r"#\[cfg\(test\)\]")


@dataclass
class Finding:
    file: str
    line: int
    function: str
    message: str


def _strip_test_modules(code: str) -> str:
    """Removes `#[cfg(test)]` modules only, keeping the production code after them."""
    text = code
    search_from = 0
    while True:
        marker = CFG_TEST_RE.search(text, search_from)
        if not marker:
            return text
        module = re.search(r"\bmod\s+\w+\s*\{", text[marker.end() :])
        if not module:
            return text
        opening = marker.end() + module.end() - 1
        depth = 0
        end = None
        for index in range(opening, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        if end is None:
            return text
        text = text[: marker.start()] + text[end:]
        search_from = marker.start()


def site_scoped_sql(sql: str) -> bool:
    """True when a filtering clause binds a site key to a value."""
    clauses = list(CLAUSE_RE.finditer(sql))
    for index, clause in enumerate(clauses):
        name = re.sub(r"\s+", " ", clause.group(1).upper())
        if name not in FILTER_CLAUSES:
            continue
        end = clauses[index + 1].start() if index + 1 < len(clauses) else len(sql)
        predicate = sql[clause.end() : end]
        if SITE_KEY_RE.search(predicate) and SITE_BIND_RE.search(predicate):
            return True
    return False


def _function_at(code: str, offset: int) -> tuple[str, int]:
    """The enclosing function's name and start offset (module level if none)."""
    starts = [
        (match.start(), match.group(0)) for match in FN_START_RE.finditer(code) if match.start() <= offset
    ]
    if not starts:
        return "<module>", 0
    start, text = starts[-1]
    name = re.sub(r".*\bfn\s+", "", text).strip()
    return name, start


def _scope_for(code: str, function_start: int, literal_start: int) -> str | None:
    """The marker of the nearest annotation within the window, if any."""
    markers = [
        match
        for match in SCOPE_MARKER_RE.finditer(code, function_start, literal_start)
    ]
    if not markers:
        return None
    nearest = markers[-1]
    if code.count("\n", nearest.end(), literal_start) > MARKER_WINDOW_LINES:
        return None
    return nearest.group(1).lower()


def audit(backend: Path) -> dict:
    src = backend / "src"
    findings: list[Finding] = []
    if not src.is_dir():
        return {"passed": False, "findings": [], "counts": {}, "scoped": 0}
    scoped = 0
    for f in sorted(src.rglob("*.rs")):
        rel = f.relative_to(backend).as_posix()
        code = _strip_test_modules(f.read_text(encoding="utf-8"))
        for m in STRING_LITERAL_RE.finditer(code):
            literal = m.group(0)
            if not IDENTITY_RE.search(literal) or not SQL_RE.search(literal):
                continue
            sql = SQL_VALUE_RE.sub("''", literal)
            if not IDENTITY_RE.search(sql):
                continue
            if site_scoped_sql(sql):
                scoped += 1
                continue
            name, function_start = _function_at(code, m.start())
            if _scope_for(code, function_start, m.start()):
                scoped += 1
                continue
            findings.append(
                Finding(
                    rel,
                    code.count("\n", 0, m.start()) + 1,
                    name,
                    f"`{name}` queries {', '.join(sorted(set(x.lower() for x in IDENTITY_RE.findall(sql))))} "
                    "without a site predicate and without a scope annotation: bind a site key in "
                    "`WHERE`/`HAVING`/`ON`, or state the scope with "
                    "`// person-scope: site|person|identity|platform` right above the statement",
                )
            )
    return {
        "passed": not findings,
        "findings": [asdict(f) for f in findings],
        "counts": {
            "identity_query_sites": scoped + len(findings),
            "scoped_or_annotated": scoped,
            "unscoped": len(findings),
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--json", action="store_true", help="Print a JSON report")
    parser.add_argument(
        "--backend", type=Path, default=DEFAULT_BACKEND, help="Backend crate directory"
    )
    args = parser.parse_args(argv)
    report = audit(args.backend)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for finding in report["findings"]:
            print(f"{finding['file']}:{finding['line']}: {finding['message']}")
        counts = report["counts"]
        print(
            "person-scope-lint: "
            f"{counts.get('unscoped', 0)} unscoped of "
            f"{counts.get('identity_query_sites', 0)} identity query sites -> "
            f"{'PASS' if report['passed'] else 'FAIL'}"
        )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
