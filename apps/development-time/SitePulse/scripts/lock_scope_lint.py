#!/usr/bin/env python3
"""Global-lock discipline for the SitePulse Rust backend.

`AppState.inner` is one `tokio::sync::RwLock` shared by every tenant. Holding
its guard across database or network I/O stalls the whole platform for the
duration of that I/O (and, with a pool wait timeout, can cascade into
failures). These rules find guards that live across such an `.await`:

  write-guard-across-io   `let x = ...inner.write().await;` is still alive
                          (same scope, not `drop(x)`-ed) at an `.await` on the
                          database (`crate::db::`, `pool`, `client.`, `tx.`),
                          a service that performs I/O, or HTTP (`reqwest`).
  read-guard-across-io    The same for `inner.read().await` guards: readers do
                          not block each other, but a queued writer blocks all
                          later readers behind them.

Scope tracking is lexical and indentation-based (the backend is rustfmt-ed), so
a guard is considered dead once its block closes. Opt out of one site with a
`// lock-scope: allow <reason>` comment on the guard line.

Usage:
    python3 scripts/lock_scope_lint.py            # human-readable
    python3 scripts/lock_scope_lint.py --json     # gate `lock-lint`
    python3 scripts/lock_scope_lint.py --backend path/to/backend

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

GUARD_RE = re.compile(r"let\s+(?:mut\s+)?(\w+)\s*=\s*[\w.]*inner\.(write|read)\(\)\.await\s*;")
IO_AWAIT_RE = re.compile(
    r"(crate::db::|\bdb::|\bpool\b|\bclient\s*\.|\btx\s*\.|reqwest|settle_advances|reload_from_db|"
    r"PaymentTrackingService|CardPaymentService)[^;]*\.await"
)
ALLOW_MARKER = "lock-scope: allow"
MAX_SPAN = 600


@dataclass
class Finding:
    rule: str
    file: str
    line: int
    message: str


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def lint_file(path: Path, rel: str, findings: list[Finding]) -> None:
    code = path.read_text(encoding="utf-8")
    cut = code.find("#[cfg(test)]")
    if cut >= 0:
        code = code[:cut]
    lines = code.splitlines()
    for i, line in enumerate(lines):
        m = GUARD_RE.search(line)
        if not m or ALLOW_MARKER in line:
            continue
        guard, kind = m.group(1), m.group(2)
        indent = _indent(line)
        for j in range(i + 1, min(i + MAX_SPAN, len(lines))):
            cur = lines[j]
            stripped = cur.strip()
            if not stripped or stripped.startswith("//"):
                continue
            if _indent(cur) < indent:
                break  # the guard's block closed
            if re.search(rf"\bdrop\(\s*{guard}\s*\)", cur):
                break
            # Re-binding the same name ends the old guard's use for our purposes.
            if re.search(rf"\blet\s+(?:mut\s+)?{guard}\b", cur) and j != i:
                break
            # Match across the whole statement: rustfmt often puts `.await` on its own line.
            statement = cur
            k = j
            while ";" not in statement and "{" not in statement and k + 1 < len(lines) and k < j + 8:
                k += 1
                statement += " " + lines[k].strip()
            if IO_AWAIT_RE.search(statement):
                findings.append(Finding(
                    f"{kind}-guard-across-io", rel, i + 1,
                    f"`{guard}` ({kind} guard on the global state) is still held at line {j + 1}: "
                    f"`{stripped[:90]}`; copy what you need, drop the guard, then await"))
                break


def lint(backend: Path) -> dict:
    findings: list[Finding] = []
    src = backend / "src"
    for f in sorted(src.rglob("*.rs")):
        lint_file(f, f.relative_to(backend).as_posix(), findings)
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
        print(f"lock-scope-lint: {len(report['findings'])} findings -> {'PASS' if report['passed'] else 'FAIL'}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
