#!/usr/bin/env python3
"""Person-scope audit for the SitePulse Rust backend (issue #535).

`users`, `user_site_roles` and `persons` are identity tables, so they are not
protected by tenant row-level security (a session looks its own user up before a
site is known). That means a query against them has to state its scope itself:

  site      the statement filters by a site key (or a site-derived parent such
            as `units`, `sites`, `v_person_roles`, `unit_occupancies`).
  person    the statement keys on a person id that the caller resolved inside
            the site it is serving.
  identity  a global identity lookup (email, google_sub, session user id) where
            no site applies yet: sign-in, session validation, uniqueness checks.
  platform  startup load, migration, SaaS administration, provisioning or the
            development seed/reset.

The four annotations below are line comments placed in the enclosing function,
before the statement, or on its line:

    // person-scope: site
    // person-scope: person
    // person-scope: identity
    // person-scope: platform

The rule is static: a statement whose SQL text names a site key is `site` by
construction; every other statement needs an annotation. This keeps the audit
true for new code instead of freezing today's review, and mirrors the tenant
lint (`tenant_isolation_lint.py`).

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
# A statement is site-scoped when it names a site key or a table that carries one.
SITE_SCOPE_RE = re.compile(
    r"\b(?:site_id|sites?|units?|unit_occupancies|unit_ownerships|v_person_roles)\b", re.I
)
SCOPE_MARKER_RE = re.compile(
    r"//\s*person-scope:\s*(site|person|identity|platform)\b", re.I
)
STRING_LITERAL_RE = re.compile(r'r#*"(?:[^"]|"(?!#))*"#*|"(?:[^"\\]|\\.)*"', re.S)
FN_START_RE = re.compile(r"(?m)^[ \t]*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+\w+")


@dataclass
class Finding:
    file: str
    line: int
    function: str
    message: str


def _strip_test_modules(code: str) -> str:
    index = code.find("#[cfg(test)]")
    return code if index < 0 else code[:index]


def _function_at(code: str, offset: int) -> tuple[str, int]:
    """The enclosing function's name and start offset (module level if none)."""
    starts = [(m.start(), m.group(0)) for m in FN_START_RE.finditer(code) if m.start() <= offset]
    if not starts:
        return "<module>", 0
    start, text = starts[-1]
    name = re.sub(r".*\bfn\s+", "", text).strip()
    return name, start


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
            sql = literal
            name, fn_start = _function_at(code, m.start())
            prefix = code[fn_start : m.start()]
            if SITE_SCOPE_RE.search(sql):
                scoped += 1
                continue
            markers = [x.group(1).lower() for x in SCOPE_MARKER_RE.finditer(prefix)]
            line_of_literal = code.count("\n", 0, m.start()) + 1
            if markers:
                scoped += 1
                continue
            findings.append(
                Finding(
                    rel,
                    line_of_literal,
                    name,
                    f"`{name}` queries {', '.join(sorted(set(x.lower() for x in IDENTITY_RE.findall(sql))))} "
                    "without a site key and without a scope annotation: add a `site_id`/`units` filter, "
                    "or state the scope with `// person-scope: site|person|identity|platform`",
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
