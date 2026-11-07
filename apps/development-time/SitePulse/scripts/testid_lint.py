#!/usr/bin/env python3
"""Lint: every widget Key in the Flutter UI has a matching GUI automation id.

The GUI suite (e2e/) finds widgets through `testId('<id>', child)` from
flutter/lib/testing/test_id.dart, which renders `flt-semantics-identifier` in
E2E builds. Widget tests use `Key('<id>')`. Both must use the same id, so a new
widget with a Key but no testId is invisible to the browser tests. This lint
fails when that happens.

Rules:
* For every `Key(<expr>)` / `ValueKey(<expr>)` with a string id under
  flutter/lib/ui, the same file must contain `testId(<expr>, ...)` with the
  identical expression (interpolations such as 'row_${item.id}' included).
* Keys on constructors that cannot carry a Semantics wrapper (list entries such
  as DropdownMenuItem, PopupMenuItem, Tab, Expanded, Positioned, ...) are skipped
  and listed as `skipped`.
* Keys built from variables (`Key(id)`), GlobalKey, UniqueKey and ObjectKey are
  not ids and are ignored.
* A key that only resets widget state (not an automation target) is exempted
  with a `// testid-lint: ignore` comment on its line or the line above.

Usage:
    python3 scripts/testid_lint.py            # human-readable, exit 1 on findings
    python3 scripts/testid_lint.py --json     # machine-readable
    python3 scripts/testid_lint.py --root apps/development-time/SitePulse/flutter/lib/ui
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_UI = ROOT / "flutter" / "lib" / "ui"

KEY_RE = re.compile(r"\b(?:Value)?Key\(\s*(?P<expr>'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")\s*\)")
TESTID_RE = re.compile(r"\btestId\(\s*(?P<expr>'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")\s*,")
# Constructors whose children must be a specific type (or that are layout-only parent data),
# so a Semantics wrapper would not compile or would change layout.
IGNORE = "testid-lint: ignore"
UNWRAPPABLE = {"Expanded", "Flexible", "Positioned", "Spacer", "DropdownMenuItem", "PopupMenuItem", "TableRow",
               "ButtonSegment", "DataRow", "DataCell", "SliverToBoxAdapter", "Tab", "BottomNavigationBarItem",
               "NavigationDestination", "Step"}


@dataclass
class Finding:
    file: str
    line: int
    key: str
    ctor: str


def _norm(expr: str) -> str:
    """Compare ids independent of quote style."""
    return expr[1:-1]


def _enclosing_ctor(src: str, pos: int) -> str:
    """Name of the constructor call whose argument list contains `pos`."""
    depth, j = 0, pos - 1
    while j >= 0:
        c = src[j]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                break
            depth -= 1
        j -= 1
    if j < 0 or src[j] != "(":
        return ""
    k = j
    while k > 0 and (src[k - 1].isalnum() or src[k - 1] in "_.<>"):
        k -= 1
    return src[k:j].split(".")[0].split("<")[0]


def lint(ui_root: Path) -> dict:
    missing: list[Finding] = []
    skipped: list[Finding] = []
    checked = 0
    for path in sorted(ui_root.rglob("*.dart")):
        src = path.read_text(encoding="utf-8")
        test_ids = {_norm(m.group("expr")) for m in TESTID_RE.finditer(src)}
        for m in KEY_RE.finditer(src):
            key = _norm(m.group("expr"))
            ctor = _enclosing_ctor(src, m.start())
            finding = Finding(str(path.relative_to(ROOT)), src.count("\n", 0, m.start()) + 1, key, ctor)
            line_start = src.rfind("\n", 0, src.rfind("\n", 0, m.start())) + 1
            line_end = src.find("\n", m.end())
            if ctor in UNWRAPPABLE or IGNORE in src[line_start:line_end]:
                skipped.append(finding)
                continue
            checked += 1
            if key not in test_ids:
                missing.append(finding)
    return {"passed": not missing, "checked": checked, "missing": [asdict(f) for f in missing],
            "skipped": [asdict(f) for f in skipped]}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=DEFAULT_UI, help="Flutter UI directory to scan")
    ap.add_argument("--json", action="store_true", help="print a JSON report")
    args = ap.parse_args(argv)
    if not args.root.is_dir():
        print(f"not a directory: {args.root}", file=sys.stderr)
        return 2
    report = lint(args.root.resolve())
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        for f in report["missing"]:
            print(f"MISSING  {f['file']}:{f['line']}  Key('{f['key']}') in {f['ctor'] or '?'} has no testId('{f['key']}')")
        print(f"{report['checked']} keyed widgets checked, {len(report['missing'])} without a testId, "
              f"{len(report['skipped'])} skipped (unwrappable constructors or `testid-lint: ignore`).")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
