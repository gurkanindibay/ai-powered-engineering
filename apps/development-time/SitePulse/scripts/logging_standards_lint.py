#!/usr/bin/env python3
"""Lint: Enforces unified logging standards for SitePulse (docs/standards/LOGGING_STANDARDS.md).

Hard rules (any finding fails):
* `no-println`: No `println!`, `eprintln!`, or `dbg!` in production Rust backend code (excluding CLI tools in `src/bin/` and test modules).
* `no-raw-print`: No raw `print(` in Flutter Dart code (`flutter/lib/`). All logging must route through `AppLogger`.
* `no-sensitive-log`: No logging of sensitive credential variables (`password`, `secret`, `access_token`, `refresh_token`, etc.).

Ratchet rules (counts may only decrease; --update-baseline records lower count):
* `raw-debug-print`: Occurrences of ad-hoc `debugPrint(` in Flutter `lib/` (target: 0; migrate to `AppLogger`).

Usage:
    python3 scripts/logging_standards_lint.py                    # human-readable, exit 1 on findings
    python3 scripts/logging_standards_lint.py --json             # machine-readable
    python3 scripts/logging_standards_lint.py --update-baseline  # update baseline after paying debt
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
DEFAULT_FLUTTER = ROOT / "flutter"
DEFAULT_BASELINE = ROOT / "scripts" / "logging_standards_baseline.json"

PRINTLN_RE = re.compile(r"\b(?:println!|eprintln!|dbg!)\s*\(")
RAW_PRINT_RE = re.compile(r"\bprint\s*\(")
DEBUG_PRINT_RE = re.compile(r"\bdebugPrint\s*\(")
SENSITIVE_LOG_RE = re.compile(
    r"""(?xi)
    (?:tracing::(?:trace|debug|info|warn|error)!\s*\([^)]*?\b(?:password|raw_password|secret|google_id_token)\s*=\s*[%?])
    |(?:AppLogger\.(?:trace|debug|info|warn|error|fatal)\s*\([^)]*?\$(?:password|secret|token)\b)
    |(?:\bdebugPrint\s*\([^)]*?\$(?:password|secret)\b)
    """
)


@dataclass
class Finding:
    rule: str
    file: str
    line: int
    text: str


def blank_rust_non_code(source: str) -> str:
    """Return `source` with comments, strings and `#[cfg(test)]` modules blanked."""
    out = list(source)
    n = len(source)

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    i = 0
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif source.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if source.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif source.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
            blank(i + 1, j)
            i = j + 1
        else:
            i += 1

    # Blank out #[cfg(test)] modules
    code = "".join(out)
    cfg_test_re = re.compile(r"#\[cfg\(test\)\]\s*mod\s+\w+\s*\{")
    for m in cfg_test_re.finditer(code):
        start = m.start()
        open_brace = code.find("{", start)
        if open_brace >= 0:
            depth, pos = 1, open_brace + 1
            while pos < n and depth > 0:
                if code[pos] == "{":
                    depth += 1
                elif code[pos] == "}":
                    depth -= 1
                pos += 1
            blank(start, pos)

    return "".join(out)


def blank_dart_non_code(source: str) -> str:
    """Return `source` with comments and strings blanked."""
    out = list(source)
    n = len(source)

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    i = 0
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        elif source.startswith("'''", i) or source.startswith('"""', i):
            quote = source[i:i + 3]
            j = source.find(quote, i + 3)
            j = n if j < 0 else j + 3
            blank(i + 3, j - 3)
            i = j
        elif source[i] in ('"', "'"):
            q = source[i]
            j = i + 1
            while j < n and source[j] != q:
                j += 2 if source[j] == "\\" else 1
            blank(i + 1, j)
            i = j + 1
        else:
            i += 1

    return "".join(out)


def line_of(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def lint(backend: Path, flutter: Path, baseline_path: Path | None = None) -> dict:
    findings: list[Finding] = []
    counts = {"raw-debug-print": 0}

    # 1. Lint Rust Backend
    backend_src = backend / "src"
    if backend_src.exists():
        for path in sorted(backend_src.rglob("*.rs")):
            rel = path.relative_to(backend).as_posix()
            source = path.read_text(encoding="utf-8")
            lines = source.split("\n")

            # Check sensitive logging in raw source
            for m in SENSITIVE_LOG_RE.finditer(source):
                ln = line_of(source, m.start())
                findings.append(Finding("no-sensitive-log", rel, ln, lines[ln - 1].strip()[:160]))

            # Check println! outside src/bin
            if not rel.startswith("src/bin/"):
                code = blank_rust_non_code(source)
                for m in PRINTLN_RE.finditer(code):
                    ln = line_of(source, m.start())
                    findings.append(Finding("no-println", rel, ln, lines[ln - 1].strip()[:160]))

    # 2. Lint Flutter Frontend
    flutter_lib = flutter / "lib"
    if flutter_lib.exists():
        for path in sorted(flutter_lib.rglob("*.dart")):
            rel = path.relative_to(flutter).as_posix()
            source = path.read_text(encoding="utf-8")
            lines = source.split("\n")

            # Check sensitive logging
            for m in SENSITIVE_LOG_RE.finditer(source):
                ln = line_of(source, m.start())
                findings.append(Finding("no-sensitive-log", rel, ln, lines[ln - 1].strip()[:160]))

            code = blank_dart_non_code(source)

            # Check raw print(
            for m in RAW_PRINT_RE.finditer(code):
                ln = line_of(source, m.start())
                findings.append(Finding("no-raw-print", rel, ln, lines[ln - 1].strip()[:160]))

            # Track debugPrint( (excluding app_logger.dart implementation)
            if not rel.endswith("app_logger.dart"):
                matches = list(DEBUG_PRINT_RE.finditer(code))
                counts["raw-debug-print"] += len(matches)

    baseline = {}
    if baseline_path and baseline_path.exists():
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))

    ratchet_exceeded = []
    for rule, count in counts.items():
        allowed = baseline.get(rule)
        if allowed is not None and count > allowed:
            ratchet_exceeded.append({"rule": rule, "count": count, "allowed": allowed})

    return {
        "passed": not findings and not ratchet_exceeded,
        "findings": [asdict(f) for f in findings],
        "counts": counts,
        "baseline": baseline,
        "ratchet_exceeded": ratchet_exceeded,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="Print report in JSON format")
    parser.add_argument("--update-baseline", action="store_true", help="Update baseline file with current counts")
    parser.add_argument("--backend", type=Path, default=DEFAULT_BACKEND, help="Path to backend directory")
    parser.add_argument("--flutter", type=Path, default=DEFAULT_FLUTTER, help="Path to flutter directory")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE, help="Path to baseline JSON file")
    args = parser.parse_args()

    report = lint(args.backend, args.flutter, args.baseline)

    if args.update_baseline:
        args.baseline.parent.mkdir(parents=True, exist_ok=True)
        args.baseline.write_text(json.dumps(report["counts"], indent=2) + "\n", encoding="utf-8")
        if not args.json:
            print(f"Updated baseline at {args.baseline}: {report['counts']}")
        return 0

    if args.json:
        print(json.dumps(report, indent=2))
        return 0 if report["passed"] else 1

    if report["findings"]:
        print(f"FAILED: {len(report['findings'])} logging standards violation(s):")
        for f in report["findings"]:
            print(f"  [{f['rule']}] {f['file']}:{f['line']}: {f['text']}")
    else:
        print("PASSED: Zero hard logging standards violations.")

    if report["ratchet_exceeded"]:
        print("\nRATCHET EXCEEDED:")
        for r in report["ratchet_exceeded"]:
            print(f"  [{r['rule']}] count {r['count']} exceeds baseline allowed {r['allowed']}")
    else:
        print(f"Ratchet counts within baseline: {report['counts']}")

    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
