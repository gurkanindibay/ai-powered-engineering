#!/usr/bin/env python3
"""Inventory and guard for Flutter component reuse (docs/reusability/flutter-reusability-report.md).

Two parts:

* **Inventory** (always printed): lexical counts of design-token adoption and
  repeated UI patterns under `flutter/lib/ui`, e.g. `EdgeInsets.` vs
  `AppSpacing.`, raw Material colours, `appSnackBar(` vs `spSnackBar(`. Counts
  are signals for tracking migration progress, not findings.

* **Reuse rules** (fail with `--check`): patterns the shared components replaced
  must not come back.
  - `clipboard`     `Clipboard.setData(` outside `ui/design_system/sp_clipboard.dart`;
                    use `spCopyToClipboard` / `spCopyIban` / `SpIbanCopyRow`.
  - `money-parse`   `Decimal.tryParse(` in `lib/ui`; typed amounts go through
                    `MoneyInput` / `SpMoneyFormField` (`MoneyFormatter.tryParse`).
  - `json-decimal`  `Decimal.tryParse(x['k']?.toString() ?? '0') ?? Decimal.zero`
                    anywhere in `lib`; use `readDecimal` (`domain/formatting/json_decimal.dart`).
  - `bank-amount`   hand-rolled `.replaceAll('.', '').replaceAll(',', '.')` amount
                    normalisation in `lib`; use `BankFileParser.parseAmount` / `MoneyFormatter`.
  - `filter-chip`   a raw Material `FilterChip(` in `lib/ui`; use `SpFilterChip`.
  - `selection-page` building `SpSelectionPage(` by hand; use `showSpSelection<T>`.
  - `raw-snackbar`  constructing `SnackBar(` directly; use `SpToast` / `spSnackBar(kind:)`.
  - `person-inputs` a text input for a person's name, phone or email (a `labelText`/`hintText`
                    such as 'Ad Soyad', 'Telefon', 'E-posta', or a `Key('..._name_field')`-style
                    id) outside the shared person form. REQ-042 / acceptance criterion 16 of
                    docs/architecture/OWNERS_RESIDENTS_UNIFIED_DESIGN.md: action, unit and
                    registration pages choose or create a person card with `SpPersonField`
                    (`showSpPersonPicker` -> `SpPersonForm`). Exempt: the shared form, the
                    card's own emergency contact, resident self-service (no directory access),
                    the user's own login e-mail, payer-name matching text and the SaaS admin's
                    site-manager account fields.

The component catalogue and the rules for adding new shared components live in
`.agents/skills/flutter-reusable-components/SKILL.md`.

Comments are ignored.

Usage:
    python3 scripts/flutter_reuse_inventory.py            # inventory + rule findings, exit 0
    python3 scripts/flutter_reuse_inventory.py --check    # exit 1 when any reuse rule fires
    python3 scripts/flutter_reuse_inventory.py --json
    python3 scripts/flutter_reuse_inventory.py --lib path/to/flutter/lib
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LIB = ROOT / "flutter" / "lib"

INVENTORY: dict[str, str] = {
    "InputDecoration(": r"\bInputDecoration\s*\(",
    "TextStyle(": r"\bTextStyle\s*\(",
    "fontSize:": r"\bfontSize\s*:",
    "textTheme": r"\btextTheme\b",
    "EdgeInsets.": r"\bEdgeInsets\.",
    "AppSpacing.": r"\bAppSpacing\.",
    "BorderRadius.circular(": r"\bBorderRadius\.circular\s*\(",
    "AppRadius.": r"\bAppRadius\.",
    "raw Material colours": r"\bColors\.(?:blue|red|green|orange|amber|grey|purple|teal|indigo|blueAccent)\b",
    "Color(0x": r"\bColor\(0x",
    "SpTone.": r"\bSpTone\.",
    "StatusColors": r"\bStatusColors\b",
    "appSnackBar(": r"\bappSnackBar\s*\(",
    "spSnackBar(": r"\bspSnackBar\s*\(",
    "SpToast.": r"\bSpToast\.",
    "AppStrings.": r"\bAppStrings\.",
    "testId(": r"\btestId\s*\(",
    "SpMetricValue(": r"\bSpMetricValue\s*\(",
    "SpGuidanceCard(": r"\bSpGuidanceCard\s*\(",
    "SpStatusBadge(": r"\bSpStatusBadge\s*\(",
    "SpFilterChip(": r"\bSpFilterChip\s*\(",
    "SpMoneyFormField(": r"\bSpMoneyFormField\s*\(",
    "SpIbanCopyRow(": r"\bSpIbanCopyRow\s*\(",
}

RULES: dict[str, tuple[str, str | tuple[str, ...], tuple[str, ...]]] = {
    # rule: (regex, scope (prefix or prefixes) relative to lib, exempt files relative to lib)
    "clipboard": (r"\bClipboard\.setData\s*\(", "ui", ("ui/design_system/sp_clipboard.dart",)),
    "money-parse": (r"\bDecimal\.tryParse\s*\(", "ui", ()),
    "json-decimal": (
        r"Decimal\.tryParse\(\s*\w+\??\[[^\]]+\]\?\.toString\(\)\s*\?\?\s*'0'\s*\)\s*\?\?\s*Decimal\.zero",
        "",
        (),
    ),
    "bank-amount": (r"\.replaceAll\('\.',\s*''\)\.replaceAll\(',',\s*'\.'\)", "", ("domain/formatting/money_formatter.dart",)),
    "filter-chip": (r"(?<![A-Za-z0-9_])FilterChip\s*\(", "ui", ("ui/design_system/sp_filter_chip.dart",)),
    "selection-page": (r"(?<![A-Za-z0-9_])SpSelectionPage\s*\(", "ui", ("ui/components/sp_dialog_pages.dart",)),
    "raw-snackbar": (r"(?<![A-Za-z0-9_])SnackBar\s*\(", "ui", ("ui/design_system/sp_feedback.dart",)),
    "person-inputs": (
        r"(?:labelText|hintText)\s*:\s*'[^']*(?:Ad[ıi]? ?[Ss]oyad|Telefon|E-posta)"
        r"|Key\('[a-z_]*_(?:name|phone|email)(?:_field|_input)?'\)",
        ("ui/components", "ui/dashboard", "ui/navigation", "ui/payments", "ui/residents"),
        (
            "ui/residents/sp_person_form.dart",  # the shared person form itself
            "ui/residents/person_preferences_page.dart",  # the card's own emergency contact
            "ui/residents/resident_household_member_page.dart",  # resident self-service
            "ui/components/profile_role_sheet.dart",  # the user's own login e-mail
            "ui/components/unit_matching_criteria_card.dart",  # payer-name matching text
        ),
    ),
}

# Lines a rule ignores although its regex matches: rule -> regex.
RULE_LINE_ALLOW: dict[str, str] = {
    # SaaS admin provisioning a site manager's login account (no site person directory yet).
    "person-inputs": r"Yönetici |_site_admin_|edit_site_name_field",
}

LINE_COMMENT_RE = re.compile(r"(?<!:)//.*$")


@dataclass
class Finding:
    rule: str
    file: str
    line: int
    text: str


def _strip_comments(source: str) -> list[str]:
    """Blank out `//` and `/* */` comments, keeping line numbers."""
    source = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), source, flags=re.S)
    return [LINE_COMMENT_RE.sub("", line) for line in source.splitlines()]


def scan(lib: Path) -> dict:
    files = sorted(lib.rglob("*.dart"))
    ui_files = [f for f in files if f.relative_to(lib).parts[:1] == ("ui",)]
    stripped = {f: _strip_comments(f.read_text(encoding="utf-8")) for f in files}

    inventory = {}
    for name, pattern in INVENTORY.items():
        regex = re.compile(pattern)
        occurrences = 0
        hit_files = 0
        for f in ui_files:
            n = sum(len(regex.findall(line)) for line in stripped[f])
            occurrences += n
            hit_files += bool(n)
        inventory[name] = {"occurrences": occurrences, "files": hit_files}

    findings: list[Finding] = []
    for rule, (pattern, scope, exempt) in RULES.items():
        regex = re.compile(pattern)
        allow = re.compile(RULE_LINE_ALLOW[rule]) if rule in RULE_LINE_ALLOW else None
        scopes = (scope,) if isinstance(scope, str) else scope
        for f in files:
            rel = f.relative_to(lib).as_posix()
            if scopes != ("",) and not any(rel.startswith(s + "/") for s in scopes):
                continue
            if rel in exempt:
                continue
            for i, line in enumerate(stripped[f], start=1):
                if regex.search(line) and not (allow and allow.search(line)):
                    findings.append(Finding(rule, rel, i, line.strip()[:160]))

    return {
        "lib": str(lib),
        "dart_files": len(files),
        "ui_files": len(ui_files),
        "inventory": inventory,
        "findings": [asdict(f) for f in findings],
        "passed": not findings,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lib", type=Path, default=DEFAULT_LIB, help="Flutter lib/ directory (default: SitePulse)")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--check", action="store_true", help="exit 1 when any reuse rule fires")
    args = parser.parse_args(argv)

    if not args.lib.is_dir():
        print(f"flutter-reuse-inventory: lib directory not found: {args.lib}", file=sys.stderr)
        return 2

    report = scan(args.lib)
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"Flutter reuse inventory ({report['ui_files']} UI files of {report['dart_files']} Dart files)")
        width = max(len(k) for k in report["inventory"])
        for name, row in report["inventory"].items():
            print(f"  {name:<{width}}  {row['occurrences']:>5} occurrences in {row['files']:>3} files")
        for f in report["findings"]:
            print(f"{f['file']}:{f['line']}: [{f['rule']}] {f['text']}")
        status = "PASS" if report["passed"] else "FAIL"
        print(f"flutter-reuse-inventory: {len(report['findings'])} reuse-rule findings -> {status}")
    return 1 if args.check and not report["passed"] else 0


if __name__ == "__main__":
    sys.exit(main())
