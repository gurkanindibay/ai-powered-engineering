#!/usr/bin/env python3
"""SitePulse persistence lint: database results must never be discarded.

The backend once held state in memory and wrote to PostgreSQL as a best-effort
side effect, discarding errors with `let _ = ...` (131 sites). This lint fails
the build when that pattern comes back. It checks the Rust sources for:

  discarded-db-result   `let _ = <db/client/tx call>` or `.await.ok();` on a database call
  swallowed-load-error  `if let Ok(..) = client.query(..)` (a failed query is silently skipped)
  missing-deny          src/lib.rs must keep `#![deny(unused_must_use)]`, so a bare
                        `db_call().await;` statement does not compile
  silent-default-id     `parse_id_to_i64(..).unwrap_or(<n>)` with n > 0 (writes to another row)

Usage:
    python3 scripts/memory_persistence_lint.py [--json] [--root PATH]

Exit code 0 when clean, 1 when violations are found.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List

DEFAULT_ROOT = Path(__file__).resolve().parent.parent / "backend"

DB_CALL = r"(?:crate::db::\w+|db::\w+|client\s*\.\s*\w+|tx\s*\.\s*\w+|pool\s*\.\s*get|save_\w+|update_\w+|delete_\w+|record_\w+)"
RULES = [
    ("discarded-db-result", re.compile(r"let\s+_\s*=\s*" + DB_CALL), "result of a database call is discarded"),
    ("discarded-db-result", re.compile(DB_CALL + r"\([^;]*?\)\s*\.await\s*\.ok\(\)\s*;", re.S), "database error converted to None and dropped"),
    ("swallowed-load-error", re.compile(r"if\s+let\s+Ok\(\w+\)\s*=\s*client\s*\.\s*query"), "failed query is silently skipped"),
    ("silent-default-id", re.compile(r"parse_id_to_i64\([^)]*\)\s*\.unwrap_or\(\s*[1-9]\d*\s*\)"), "unparseable id silently mapped to a real row"),
]


def lint(root: Path) -> List[Dict[str, object]]:
    findings: List[Dict[str, object]] = []
    for path in sorted((root / "src").rglob("*.rs")):
        text = path.read_text(encoding="utf-8")
        for rule, pattern, message in RULES:
            for m in pattern.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                findings.append({"rule": rule, "file": str(path.relative_to(root)), "line": line,
                                 "message": message, "code": text.splitlines()[line - 1].strip()[:160]})
    lib = root / "src" / "lib.rs"
    if not lib.exists() or "#![deny(unused_must_use)]" not in lib.read_text(encoding="utf-8"):
        findings.append({"rule": "missing-deny", "file": "src/lib.rs", "line": 1,
                         "message": "src/lib.rs must contain #![deny(unused_must_use)]", "code": ""})
    return findings


def run_all_checks(root: Path = DEFAULT_ROOT) -> List[Dict[str, str]]:
    """Compatibility helper: one PASS/FAIL entry per rule."""
    findings = lint(root)
    rules = sorted({r for r, _, _ in RULES} | {"missing-deny"})
    return [
        {"check": rule, "status": "FAIL" if any(f["rule"] == rule for f in findings) else "PASS",
         "message": "; ".join(f"{f['file']}:{f['line']}" for f in findings if f["rule"] == rule)}
        for rule in rules
    ]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="Backend crate root (default: backend/)")
    args = parser.parse_args(argv)
    findings = lint(args.root)
    if args.json:
        print(json.dumps({"passed": not findings, "violations": findings}, indent=2))
    else:
        for f in findings:
            print(f"{f['file']}:{f['line']}: [{f['rule']}] {f['message']}\n    {f['code']}")
        print(f"\nPERSISTENCE LINT: {'OK' if not findings else f'{len(findings)} violation(s)'}")
    return 0 if not findings else 1


if __name__ == "__main__":
    sys.exit(main())
