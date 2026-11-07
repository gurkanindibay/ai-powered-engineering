#!/usr/bin/env python3
"""Lint: the Flutter UI follows the design-system rules from UX_UI_EVALUATION_REPORT.md.

Hard rules (any finding fails):
* `font-floor`   no literal font size below 12 px (`fontSize: 11`, `selectedFontSize: 10`, ...).
* `money-format` no amount printed by hand: `'₺${x.toStringAsFixed(..)}'`, `'₺$x'` or
                 `'₺${x}'`; use `formatTry(x)` / `MoneyFormatter` (Decimal, `₺1.423,33`).
* `emoji-icon`   no emoji inside string literals (they render differently per platform);
                 use an `Icon` instead.
* `stand-in-icon` no `Icons.g_mobiledata` stand-in for the Google mark (use `GoogleMark`).
* `no-popup`     no floating popup or partial sheet (`showDialog`, `showModalBottomSheet`,
                 `AlertDialog`, `SimpleDialog`, `Dialog`, ...): the constitution mandates
                 full-screen pages. Use `AppFullscreenPage` or `showSpPage` + `SpAlertPage` /
                 `SpDialogPage` / `SpSelectionPage` (`ui/components/sp_dialog_pages.dart`).

Ratchet rules (counts may only go down; `--update-baseline` records a lower count):
* `literal-font-size` literal `fontSize:` values outside ui/theme and ui/design_system.
* `raw-color`         `Color(0x...)` literals outside ui/theme and ui/design_system.

Only code is checked: comments are ignored, and string rules look only inside literals.

Usage:
    python3 scripts/ui_style_lint.py                  # human-readable, exit 1 on findings
    python3 scripts/ui_style_lint.py --json           # machine-readable
    python3 scripts/ui_style_lint.py --update-baseline
    python3 scripts/ui_style_lint.py --root path/to/flutter/lib/ui --baseline path/to/baseline.json
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
DEFAULT_BASELINE = ROOT / "scripts" / "ui_style_baseline.json"
EXEMPT_DIRS = ("theme", "design_system")

FONT_FLOOR_RE = re.compile(r"\b(?:fontSize|selectedFontSize|unselectedFontSize)\s*:\s*(\d+(?:\.\d+)?)")
LITERAL_FONT_RE = re.compile(r"\bfontSize\s*:\s*\d")
RAW_COLOR_RE = re.compile(r"\bColor\(0x[0-9A-Fa-f]{6,8}\)")
STAND_IN_RE = re.compile(r"\bIcons\.g_mobiledata\b")
MONEY_IN_STRING_RE = re.compile(r"₺\$(?:\{[^}]*?\.toStringAsFixed\(|\{(?!formatTry\(|MoneyFormatter\.)|[A-Za-z_])")
POPUP_RE = re.compile(
    r"(?<![A-Za-z0-9_])(?:showDialog|showModalBottomSheet|showBottomSheet|showGeneralDialog|showCupertinoDialog"
    r"|showCupertinoModalPopup|AlertDialog|SimpleDialog|Dialog|CupertinoAlertDialog)\s*(?:<[^>()]*>)?\("
)
# The deprecated sheet container is the one place that still wraps showModalBottomSheet.
POPUP_EXEMPT_FILES = ("components/app_modal_sheet.dart",)
EMOJI_RE = re.compile("[\U0001F300-\U0001FAFF☀-➿\U0001F1E6-\U0001F1FF]")


@dataclass
class Finding:
    rule: str
    file: str
    line: int
    text: str


def split_code(source: str) -> tuple[str, str]:
    """Return (code_only, strings_only): same length as source, other parts blanked.

    Comments are blanked in both. Interpolations `${...}` inside strings count as
    string content for the string rules (that is where `₺${x}` lives).
    """
    code = list(source)
    strings = [" " if c != "\n" else "\n" for c in source]
    i, n = 0, len(source)

    def blank(a: int, b: int, keep_in_strings: bool) -> None:
        for k in range(a, b):
            if source[k] == "\n":
                continue
            code[k] = " "
            if keep_in_strings:
                strings[k] = source[k]

    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            blank(i, j, False)
            i = j
        elif source.startswith("/*", i):
            j = source.find("*/", i)
            j = n if j < 0 else j + 2
            blank(i, j, False)
            i = j
        elif source[i] in "'\"":
            quote = source[i:i + 3] if source[i:i + 3] in ("'''", '"""') else source[i]
            raw = i > 0 and source[i - 1] == "r"
            j = i + len(quote)
            depth = 0
            while j < n:
                if depth == 0 and source.startswith(quote, j):
                    break
                if source[j] == "\\" and not raw:
                    j += 2
                    continue
                if source.startswith("${", j) and not raw:
                    depth += 1
                    j += 2
                    continue
                if depth and source[j] == "{":
                    depth += 1
                elif depth and source[j] == "}":
                    depth -= 1
                j += 1
            j = min(n, j + len(quote))
            blank(i, j, True)
            i = j
        else:
            i += 1
    return "".join(code), "".join(strings)


def line_of(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def lint(ui_root: Path, baseline_path: Path | None = None) -> dict:
    findings: list[Finding] = []
    counts = {"literal-font-size": 0, "raw-color": 0}
    files = sorted(ui_root.rglob("*.dart"))
    for path in files:
        source = path.read_text(encoding="utf-8")
        code, strings = split_code(source)
        rel = path.relative_to(ui_root).as_posix()
        lines = source.split("\n")
        exempt = rel.split("/")[0] in EXEMPT_DIRS

        def add(rule: str, offset: int) -> None:
            ln = line_of(source, offset)
            findings.append(Finding(rule, rel, ln, lines[ln - 1].strip()[:160]))

        for m in FONT_FLOOR_RE.finditer(code):
            if float(m.group(1)) < 12:
                add("font-floor", m.start())
        for m in STAND_IN_RE.finditer(code):
            add("stand-in-icon", m.start())
        if rel not in POPUP_EXEMPT_FILES:
            for m in POPUP_RE.finditer(code):
                add("no-popup", m.start())
        for m in MONEY_IN_STRING_RE.finditer(strings):
            add("money-format", m.start())
        for m in EMOJI_RE.finditer(strings):
            add("emoji-icon", m.start())
        if not exempt:
            counts["literal-font-size"] += len(LITERAL_FONT_RE.findall(code))
            counts["raw-color"] += len(RAW_COLOR_RE.findall(code))

    baseline = {}
    if baseline_path and baseline_path.exists():
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    ratchet = []
    for rule, count in counts.items():
        allowed = baseline.get(rule)
        if allowed is not None and count > allowed:
            ratchet.append({"rule": rule, "count": count, "allowed": allowed})

    return {
        "passed": not findings and not ratchet,
        "files": len(files),
        "findings": [asdict(f) for f in findings],
        "counts": counts,
        "baseline": baseline,
        "ratchet_exceeded": ratchet,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_UI, help="Flutter UI directory (default: flutter/lib/ui)")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE, help="Ratchet baseline JSON")
    parser.add_argument("--json", action="store_true", help="Print a JSON report")
    parser.add_argument("--update-baseline", action="store_true",
                        help="Write current ratchet counts to the baseline (only lowers them unless --force)")
    parser.add_argument("--force", action="store_true", help="With --update-baseline, allow raising a count")
    args = parser.parse_args(argv)

    report = lint(args.root, args.baseline)
    if args.update_baseline:
        old = report["baseline"]
        new = {}
        for rule, count in report["counts"].items():
            prev = old.get(rule)
            new[rule] = count if (prev is None or count <= prev or args.force) else prev
        args.baseline.write_text(json.dumps(new, indent=2) + "\n", encoding="utf-8")
        report = lint(args.root, args.baseline)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        for f in report["findings"]:
            print(f"{f['file']}:{f['line']}: [{f['rule']}] {f['text']}")
        for r in report["ratchet_exceeded"]:
            print(f"[{r['rule']}] {r['count']} literals, baseline allows {r['allowed']}: "
                  "use theme tokens (AppColors / TextTheme) instead of adding new ones")
        counts = ", ".join(f"{k}={v}" for k, v in report["counts"].items())
        print(f"ui-style-lint: {report['files']} files, {len(report['findings'])} findings, ratchet {counts} "
              f"-> {'PASS' if report['passed'] else 'FAIL'}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
