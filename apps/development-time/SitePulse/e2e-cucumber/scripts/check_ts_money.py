#!/usr/bin/env python3
"""Lint: Enforce decimal precision in TypeScript step definitions and page objects.

AGENTS Rule 2: Floating point parsing of monetary amounts (Number(...), parseFloat(...))
is strictly forbidden in financial domains. Amounts must be represented as strings
or arbitrary-precision Decimals (via decimal.js).
"""
import re
import sys
from pathlib import Path

FORBIDDEN = [
    (re.compile(r"\bNumber\s*\([^)]*\b(?:amount|balance|budget|share|due|price|fee|advance|penalty|paid)\b[^)]*\)", re.I),
     "Forbidden Number(...) conversion of monetary identifier"),
    (re.compile(r"\bparseFloat\s*\(", re.I),
     "Forbidden parseFloat(...) call; use decimal.js or Decimal string representations"),
    (re.compile(r"\bparseInt\s*\([^)]*\b(?:amount|balance|budget|share|due|price|fee|advance|penalty|paid)\b[^)]*\)", re.I),
     "Forbidden parseInt(...) conversion of monetary identifier"),
]

def check_file(path: Path) -> list[str]:
    findings = []
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    for idx, line in enumerate(lines, start=1):
        # Ignore comments
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*"):
            continue
        for pattern, msg in FORBIDDEN:
            if pattern.search(line):
                findings.append(f"{path}:{idx}: {msg}\n    {line.strip()}")
    return findings

def main() -> int:
    root = Path(__file__).resolve().parents[1] / "src"
    ts_files = list(root.rglob("*.ts"))
    all_findings = []
    for f in ts_files:
        all_findings.extend(check_file(f))

    if all_findings:
        print(f"FAILED: Found {len(all_findings)} decimal precision violations in TypeScript suite:\n", file=sys.stderr)
        for finding in all_findings:
            print(finding, file=sys.stderr)
        return 1

    print(f"OK: {len(ts_files)} TypeScript files verified clean of floating-point money conversions.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
