#!/usr/bin/env python3
"""Ratchet test-quality shortcuts so new weak assertions and timing dependencies fail CI.

Counts are pinned by ``test_quality_baseline.json``. Increases and unrecorded decreases fail so
improvements are locked in by updating the baseline. Existing over-limit scenario claims are
tracked per test; new claims or increases fail. Use ``--update-baseline`` for reviewed changes.

Usage:
    python3 scripts/test_quality_lint.py
    python3 scripts/test_quality_lint.py --json
    python3 scripts/test_quality_lint.py --update-baseline
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPO = ROOT.parents[2]
DEFAULT_BASELINE = ROOT / "scripts" / "test_quality_baseline.json"
MAX_SCENARIOS_PER_TEST = 3

SLEEP_RE = re.compile(
    r"\bthread::sleep\s*\(|\btokio::time::sleep\s*\(|\btime\.sleep\s*\(|"
    r"\bwait_for_timeout\s*\(|\bFuture\.delayed\s*\("
)
ENV_MUTATION_RE = re.compile(
    r"\b(?:std::env::(?:set_var|remove_var)|env::(?:set_var|remove_var)|"
    r"monkeypatch\.(?:setenv|delenv)|os\.environ\s*\[[^\]]+\]\s*=|"
    r"os\.environ\.(?:update|pop|clear)\s*\(|patch\.dict\s*\(\s*os\.environ)"
)
UTC_NOW_RE = re.compile(r"\b(?:chrono::)?Utc::now\s*\(")
IS_ERR_RE = re.compile(r"\.is_err\s*\(\s*\)")


@dataclass(frozen=True)
class Finding:
    rule: str
    file: str
    line: int
    text: str


def _assert_is_err_offsets(source: str) -> list[int]:
    """Return offsets of is_err checks inside assert! macros, respecting nested parens."""
    hits: list[int] = []
    for match in re.finditer(r"\bassert!\s*\(", source):
        start = match.end()
        depth = 1
        quote: str | None = None
        escaped = False
        for index in range(start, len(source)):
            char = source[index]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
                continue
            if char in ("'", '"'):
                quote = char
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    args = source[start:index]
                    err = IS_ERR_RE.search(args)
                    if err:
                        hits.append(start + err.start())
                    break
    return hits


def _line_of(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def analyze(repo: Path, tests: list[dict[str, Any]]) -> tuple[dict[str, int], dict[str, int], list[Finding]]:
    """Count existing shortcuts and return current over-limit claims per test."""
    sitepulse_prefix = "apps/development-time/SitePulse/"
    counts: Counter[str] = Counter()
    scenario_overages: dict[str, int] = {}
    findings: list[Finding] = []

    for test in tests:
        rel = str(test.get("file", ""))
        if not rel.startswith(sitepulse_prefix):
            continue
        path = repo / rel
        if not path.is_file():
            continue
        source = path.read_text(encoding="utf-8", errors="replace")
        lines = source.splitlines()
        start = max(0, int(test.get("line", 1)) - 1)
        end = max(start + 1, int(test.get("end", start + 1)))
        body = "\n".join(lines[start:end])
        key = f"{rel}::{test.get('name', '<unnamed>')}"
        claimed = int(test.get("scenarios_claimed", 0))
        if claimed > MAX_SCENARIOS_PER_TEST:
            scenario_overages[key] = claimed

        flags = set(test.get("flags", []))
        if "only-unwrap (passes if nothing panics)" in flags:
            counts["unwrap-only-tests"] += 1
            findings.append(Finding("unwrap-only-test", rel, int(test.get("line", 1)), lines[start].strip()[:160]))
        if "weak-assertions-only" in flags:
            counts["weak-only-tests"] += 1
            findings.append(Finding("weak-only-test", rel, int(test.get("line", 1)), lines[start].strip()[:160]))
        if test.get("lang") == "python" and "/e2e/" in rel and "wait-only (no explicit assertion)" in flags:
            counts["wait-only-gui-tests"] += 1
            findings.append(Finding("wait-only-gui-test", rel, int(test.get("line", 1)), lines[start].strip()[:160]))

        for match in SLEEP_RE.finditer(body):
            counts["fixed-sleep-calls"] += 1
            line = start + _line_of(body, match.start())
            findings.append(Finding("fixed-sleep", rel, line, lines[line - 1].strip()[:160]))
        for match in ENV_MUTATION_RE.finditer(body):
            counts["environment-mutations"] += 1
            line = start + _line_of(body, match.start())
            findings.append(Finding("environment-mutation", rel, line, lines[line - 1].strip()[:160]))

        if test.get("lang") == "rust" and "/backend/tests/" in rel:
            for offset in _assert_is_err_offsets(body):
                counts["any-error-is-err-checks"] += 1
                line = start + _line_of(body, offset)
                findings.append(Finding("any-error-is-err", rel, line, lines[line - 1].strip()[:160]))

    backend_tests = repo / "apps/development-time/SitePulse/backend/tests"
    if backend_tests.exists():
        for path in sorted(backend_tests.rglob("*.rs")):
            source = path.read_text(encoding="utf-8", errors="replace")
            rel = path.relative_to(repo).as_posix()
            lines = source.splitlines()
            for match in UTC_NOW_RE.finditer(source):
                counts["utc-now-backend-test-reads"] += 1
                line = _line_of(source, match.start())
                findings.append(Finding("utc-now-in-backend-test", rel, line, lines[line - 1].strip()[:160]))

    counts["scenario-over-cap-tests"] = len(scenario_overages)
    return dict(sorted(counts.items())), dict(sorted(scenario_overages.items())), findings


def compare_to_baseline(
    counts: dict[str, int], overages: dict[str, int], baseline: dict[str, Any], findings: list[Finding]
) -> list[dict[str, Any]]:
    allowed_counts = baseline.get("counts", {})
    allowed_overages = baseline.get("over_limit_tests", {})
    exceeded = [
        {"rule": rule, "count": count, "allowed": int(allowed_counts.get(rule, 0))}
        for rule, count in counts.items()
        if count > int(allowed_counts.get(rule, 0))
    ]
    decreased = [
        {"rule": rule, "count": count, "baseline": int(allowed_counts[rule]),
         "message": "Improvement detected; run --update-baseline and commit the reviewed baseline."}
        for rule, count in counts.items()
        if rule in allowed_counts and count < int(allowed_counts[rule])
    ]
    exceeded.extend(decreased)
    finding_rules = {
        "any-error-is-err-checks": "any-error-is-err",
        "unwrap-only-tests": "unwrap-only-test",
        "weak-only-tests": "weak-only-test",
        "wait-only-gui-tests": "wait-only-gui-test",
        "fixed-sleep-calls": "fixed-sleep",
        "environment-mutations": "environment-mutation",
        "utc-now-backend-test-reads": "utc-now-in-backend-test",
    }
    for item in exceeded:
        rule = finding_rules.get(item["rule"])
        if rule:
            item["examples"] = [asdict(finding) for finding in findings if finding.rule == rule][:10]
    for key, count in overages.items():
        allowed = int(allowed_overages.get(key, 0))
        if count > allowed:
            exceeded.append({
                "rule": "scenarios-per-test", "test": key, "count": count, "allowed": allowed,
                "message": "New or increased over-cap claim; if this test was renamed or moved, review and run --update-baseline.",
            })
    return exceeded


def lint(repo: Path, baseline_path: Path) -> dict[str, Any]:
    scripts = repo / "apps/development-time/SitePulse/scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    try:
        import test_strategy_scan
    except ImportError as exc:
        raise ValueError(f"Could not load test_strategy_scan.py from {scripts}: {exc}") from exc

    test_rows = test_strategy_scan.scan(repo)["tests"]
    counts, overages, findings = analyze(repo, test_rows)
    baseline: dict[str, Any] = json.loads(baseline_path.read_text(encoding="utf-8")) if baseline_path.exists() else {}
    exceeded = compare_to_baseline(counts, overages, baseline, findings)

    return {
        "passed": not exceeded,
        "max_scenarios_per_test": MAX_SCENARIOS_PER_TEST,
        "counts": counts,
        "baseline": baseline,
        "over_limit_tests": overages,
        "ratchet_exceeded": exceeded,
        "tests_scanned": len(test_rows),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=DEFAULT_REPO, help="repository root")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE, help="ratchet baseline JSON")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    parser.add_argument("--update-baseline", action="store_true", help="record current counts and over-limit tests")
    args = parser.parse_args(argv)

    try:
        report = lint(args.repo.resolve(), args.baseline)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"test_quality_lint: {exc}", file=sys.stderr)
        return 2

    if args.update_baseline:
        args.baseline.parent.mkdir(parents=True, exist_ok=True)
        content = {"counts": report["counts"], "over_limit_tests": report["over_limit_tests"]}
        args.baseline.write_text(json.dumps(content, indent=2) + "\n", encoding="utf-8")
        report["baseline_updated"] = str(args.baseline)
        report["passed"] = True
        report["ratchet_exceeded"] = []

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        state = "PASSED" if report["passed"] else "FAILED"
        print(f"{state}: test quality ratchet (max scenarios/test: {MAX_SCENARIOS_PER_TEST})")
        for rule, count in report["counts"].items():
            print(f"  {rule}: {count}")
        if report["ratchet_exceeded"]:
            print("New findings:")
            for item in report["ratchet_exceeded"]:
                print(f"  {item}")
        if args.update_baseline:
            print(f"Updated baseline: {args.baseline}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
