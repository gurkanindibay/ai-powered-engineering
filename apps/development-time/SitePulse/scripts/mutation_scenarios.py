#!/usr/bin/env python3
"""Hand-designed mutation scenarios that test the SitePulse tests.

A mutation scenario plants one deliberate, realistic bug (a *mutant*) in
production code and runs the test suites that should notice it. A mutant the
tests fail on is *killed*; one they still pass on *survived* and marks a gap in
the tests, not in the code.

The catalogue lives in ``harness/mutation/scenarios.toml``. Each scenario names
a file, an exact ``original`` snippet that must occur once in it, the
``mutant`` that replaces it, and the suites to run, cheapest first. Suites stop
at the first one that kills the mutant unless ``--all-suites`` is given.

Outcomes:
  killed     a suite failed on the mutant (the tests caught the bug)
  survived   every suite passed on the mutant (a test gap)
  unviable   the mutant did not compile; fix the scenario, it proves nothing
  timeout    a suite ran past its timeout (counted apart from the score)
  skipped    a suite needs something this run does not have (e.g. PostgreSQL)

Mutation score = killed / (killed + survived).

Commands:
  list                     show the catalogue
  validate                 every file exists and every original occurs once
  baseline                 run every suite the selection uses, unmutated
  run                      apply each selected mutant, run its suites, restore
  restore                  put back files left mutated by an interrupted run

Examples:
  python3 scripts/mutation_scenarios.py validate
  python3 scripts/mutation_scenarios.py list --layer rust --json
  python3 scripts/mutation_scenarios.py run --id MUT-RS-001 --id MUT-RS-002
  python3 scripts/mutation_scenarios.py run --layer python --markdown out.md --output out.json
  python3 scripts/mutation_scenarios.py run --with postgres   # include DB suites

The working tree must be clean for every file a run mutates; the original text
is journalled before each mutation so ``restore`` can undo an interrupted run.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import tomllib
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Callable, Sequence

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOGUE = PROJECT_ROOT / "harness" / "mutation" / "scenarios.toml"
# One journal per checkout: worktrees run mutations side by side, and one run must
# never overwrite, delete or restore another checkout's entry.
JOURNAL = Path(tempfile.gettempdir()) / (
    "sitepulse-mutation-journal-" + hashlib.sha256(str(PROJECT_ROOT).encode()).hexdigest()[:16] + ".json"
)
# Set while a mutant is applied, so self-checks that read production code
# (such as the catalogue drift test) do not count as a kill.
ACTIVE_ENV = "SITEPULSE_MUTATION_ACTIVE"
UNVIABLE_MARKERS = ("error[E", "error: could not compile", "Error: Compilation failed", "SyntaxError")
OUTPUT_TAIL = 30


@dataclass(frozen=True)
class Suite:
    name: str
    cwd: str
    cmd: list[str]
    timeout: int = 900
    requires: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Scenario:
    id: str
    layer: str
    area: str
    operator: str
    risk: str
    file: str
    original: str
    mutant: str
    intent: str
    suites: list[str]
    note: str = ""


@dataclass
class SuiteResult:
    suite: str
    status: str  # passed | failed | unscored | unviable | timeout | skipped | not-run
    seconds: float = 0.0
    tail: str = ""
    baseline_status: str = ""
    baseline_seconds: float = 0.0
    baseline_tail: str = ""
    failure_test: str = ""


@dataclass
class ScenarioResult:
    id: str
    layer: str
    area: str
    operator: str
    risk: str
    outcome: str
    killed_by: str = ""
    killed_test: str = ""
    seconds: float = 0.0
    suites: list[SuiteResult] = field(default_factory=list)


@dataclass
class Catalogue:
    suites: dict[str, Suite]
    scenarios: list[Scenario]


def load_catalogue(path: Path = DEFAULT_CATALOGUE) -> Catalogue:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    suites = {name: Suite(name=name, **spec) for name, spec in data.get("suites", {}).items()}
    scenarios = [Scenario(**spec) for spec in data.get("scenario", [])]
    return Catalogue(suites=suites, scenarios=scenarios)


def validate(catalogue: Catalogue, root: Path = PROJECT_ROOT) -> list[str]:
    """Problems that make a scenario meaningless; empty when the catalogue is sound."""
    problems: list[str] = []
    seen: set[str] = set()
    for s in catalogue.scenarios:
        if s.id in seen:
            problems.append(f"{s.id}: duplicate id")
        seen.add(s.id)
        if s.original == s.mutant:
            problems.append(f"{s.id}: mutant is identical to the original")
        if not s.suites:
            problems.append(f"{s.id}: names no suite")
        for name in s.suites:
            if name not in catalogue.suites:
                problems.append(f"{s.id}: unknown suite {name!r}")
        path = root / s.file
        if not path.is_file():
            problems.append(f"{s.id}: {s.file} does not exist")
            continue
        count = path.read_text(encoding="utf-8").count(s.original)
        if count != 1:
            problems.append(
                f"{s.id}: original snippet occurs {count} times in {s.file} (needs exactly 1); "
                "the code changed, so update the scenario to the new code"
            )
    return problems


def _parse_git_output_paths(stdout: str, repo_root: Path, root: Path, is_status: bool = False) -> set[str]:
    paths: set[str] = set()
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if is_status:
            parts = line.split(maxsplit=1)
            if len(parts) != 2:
                continue
            path_str = parts[1]
            if " -> " in path_str:
                path_str = path_str.split(" -> ")[1]
        else:
            path_str = line
        p = (repo_root / path_str.strip('"')).resolve()
        try:
            paths.add(str(p.relative_to(root.resolve())))
        except ValueError:
            pass
    return paths


def detect_changed_files(root: Path = PROJECT_ROOT, base: str | None = None) -> set[str]:
    """Detects modified files in git relative to `root`. Raises ValueError on git failure or invalid base."""
    proc = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise ValueError(f"git rev-parse failed: {proc.stderr.strip() or 'not a git repository'}")
    repo_root = Path(proc.stdout.strip()).resolve()

    if base:
        diff = subprocess.run(
            ["git", "diff", "--name-only", base],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
        if diff.returncode != 0:
            raise ValueError(f"git diff failed against base {base!r}: {diff.stderr.strip() or 'unknown revision'}")
        return _parse_git_output_paths(diff.stdout, repo_root, root, is_status=False)

    # 1. Uncommitted working tree / staged changes
    st = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if st.returncode != 0:
        raise ValueError(f"git status failed: {st.stderr.strip()}")
    changed = _parse_git_output_paths(st.stdout, repo_root, root, is_status=True)

    # 2. Diff against HEAD~1 or origin/master...HEAD if working tree clean
    if not changed:
        for target in ("HEAD~1", "origin/master...HEAD"):
            diff = subprocess.run(
                ["git", "diff", "--name-only", target],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )
            if diff.returncode == 0:
                target_changed = _parse_git_output_paths(diff.stdout, repo_root, root, is_status=False)
                if target_changed:
                    changed = target_changed
                    break
    return changed


def select(
    catalogue: Catalogue,
    ids: Sequence[str],
    layers: Sequence[str],
    areas: Sequence[str],
    changed_files: Sequence[str] | set[str] | None = None,
    *,
    direct_only: bool = False,
) -> list[Scenario]:
    chosen = catalogue.scenarios
    if ids:
        wanted = set(ids)
        unknown = wanted - {s.id for s in chosen}
        if unknown:
            raise SystemExit(f"unknown scenario id(s): {', '.join(sorted(unknown))}")
        chosen = [s for s in chosen if s.id in wanted]
    if layers:
        chosen = [s for s in chosen if s.layer in layers]
    if areas:
        chosen = [s for s in chosen if s.area in areas]
    if changed_files is not None:
        changed_set = set(changed_files)
        if direct_only:
            return [s for s in chosen if s.file in changed_set]
        direct_files = {s.file for s in catalogue.scenarios}
        indirect_inputs = changed_set - direct_files
        indirect_areas = _indirect_areas_for_changed_files(indirect_inputs)
        chosen = [
            s for s in chosen
            if s.file in changed_set
            or "*" in indirect_areas
            or s.area in indirect_areas
            or f"@layer:{s.layer}" in indirect_areas
        ]
    return chosen


# These inputs exercise behaviour represented by the listed mutation areas but
# do not themselves contain a mutant. Keep the map explicit: unrelated tests
# and tooling must not silently turn into a full mutation run.
INDIRECT_CHANGE_AREAS: dict[str, frozenset[str]] = {
    "backend/tests/db_accrual_*": frozenset({"accrual-persistence"}),
    "backend/tests/db_tenant_*": frozenset({"tenancy"}),
    "backend/tests/db_occupancy_*": frozenset({"proration", "unit-state"}),
    "backend/tests/db_person_*": frozenset({"identifiers", "tenancy"}),
    "backend/tests/db_unit_person_*": frozenset({"identifiers", "tenancy"}),
    "backend/tests/db_advance_exit_*": frozenset({"allocation", "proration"}),
    "backend/tests/statement_*": frozenset({"unit-statements", "statement-sections"}),
    "backend/tests/payment_*": frozenset({"dues-ledger", "late-fee", "double-entry"}),
    "backend/tests/payments_*": frozenset({"dues-ledger", "late-fee", "double-entry"}),
    "backend/src/services/finance_common.rs": frozenset({"dues-ledger", "late-fee", "accrual-persistence"}),
    "backend/migrations/V*__*tenant*": frozenset({"tenancy"}),
    "backend/migrations/V*__*dues*": frozenset({"dues-ledger", "accrual-persistence"}),
    "backend/migrations/V*__*financial*": frozenset({"dues-ledger", "accrual-persistence"}),
    "flutter/test/ui_test_helpers.dart": frozenset({"@layer:flutter"}),
    "flutter/test/support/*": frozenset({"@layer:flutter"}),
    "scripts/mutation_scenarios.py": frozenset({"*"}),
    "harness/mutation/*": frozenset({"*"}),
}


def _indirect_areas_for_changed_files(changed_files: set[str]) -> set[str]:
    areas: set[str] = set()
    for path in changed_files:
        for pattern, mapped_areas in INDIRECT_CHANGE_AREAS.items():
            if fnmatch.fnmatchcase(path, pattern):
                areas.update(mapped_areas)
    if "*" in areas:
        return {"*"}
    return areas


def _tail(text: str, lines: int = OUTPUT_TAIL) -> str:
    return "\n".join(text.strip().splitlines()[-lines:])


def _failure_identifier(output: str) -> str:
    """Return a test or assertion identity when a runner includes one."""
    patterns = (
        r"^---- (.+?) stdout ----$",  # Rust libtest
        r"^test (.+?) \.\.\. FAILED$",  # Rust libtest without captured panic detail
        r"^FAILED\s+(\S+::\S+)(?:\s+-\s+|$)",  # pytest
        r"^(?:FAIL|ERROR):\s*(.+)$",  # unittest
        r"^\d{2}:\d{2}\s+\+\d+\s+-\d+:\s*(.+?)(?:\s+\[E\])?$",  # Flutter test runner
    )
    for pattern in patterns:
        match = re.search(pattern, output, re.MULTILINE)
        if match:
            return match.group(1).strip()
    return ""


Runner = Callable[[Suite, Path], SuiteResult]


def run_suite(suite: Suite, root: Path) -> SuiteResult:
    env = dict(os.environ, **{ACTIVE_ENV: "1"})
    started = time.monotonic()
    # Own process group, so a timeout also stops the test binaries cargo/flutter
    # started instead of leaving them running into the next mutant.
    proc = subprocess.Popen(
        suite.cmd,
        cwd=root / suite.cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        output, _ = proc.communicate(timeout=suite.timeout)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        return SuiteResult(suite.name, "timeout", time.monotonic() - started)
    except BaseException:
        _kill_group(proc)
        raise
    elapsed = time.monotonic() - started
    if proc.returncode == 0:
        return SuiteResult(suite.name, "passed", elapsed)
    status = "unviable" if any(m in output for m in UNVIABLE_MARKERS) else "failed"
    return SuiteResult(suite.name, status, elapsed, _tail(output), failure_test=_failure_identifier(output))


def _kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    proc.wait()


def _git_dirty(root: Path, rel: str) -> bool:
    proc = subprocess.run(
        ["git", "status", "--porcelain", "--", rel], cwd=root, capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:  # not a git checkout (e.g. a self-test sandbox)
        return False
    return bool(proc.stdout.strip())


def _journal_write(journal: Path, path: Path, original: str) -> None:
    journal.write_text(json.dumps({"file": str(path), "text": original}), encoding="utf-8")


def _journal_entry(journal: Path, root: Path) -> dict | None:
    """The journal entry, if it belongs to a file under `root` (this checkout)."""
    if not journal.exists():
        return None
    entry = json.loads(journal.read_text(encoding="utf-8"))
    if not Path(entry["file"]).resolve().is_relative_to(root.resolve()):
        return None
    return entry


def restore(journal: Path = JOURNAL, root: Path = PROJECT_ROOT) -> str | None:
    """Writes back a file left mutated by an interrupted run in this checkout; returns its path.
    An entry for a file outside `root` belongs to another checkout and is left alone."""
    entry = _journal_entry(journal, root)
    if entry is None:
        return None
    Path(entry["file"]).write_text(entry["text"], encoding="utf-8")
    journal.unlink()
    return entry["file"]


def run_scenario(
    scenario: Scenario,
    catalogue: Catalogue,
    root: Path = PROJECT_ROOT,
    capabilities: frozenset[str] = frozenset(),
    all_suites: bool = False,
    runner: Runner = run_suite,
    journal: Path = JOURNAL,
    clean_baselines: dict[str, SuiteResult] | None = None,
) -> ScenarioResult:
    path = root / scenario.file
    original_text = path.read_text(encoding="utf-8")
    if original_text.count(scenario.original) != 1:
        raise SystemExit(f"{scenario.id}: original snippet no longer occurs exactly once; run `validate`")
    result = ScenarioResult(
        scenario.id, scenario.layer, scenario.area, scenario.operator, scenario.risk, outcome="survived"
    )
    started = time.monotonic()
    baselines: dict[str, SuiteResult] = {}
    runnable: list[str] = []
    for name in scenario.suites:
        suite = catalogue.suites[name]
        missing = [requirement for requirement in suite.requires if requirement not in capabilities]
        if missing:
            baselines[name] = SuiteResult(
                name, "skipped", tail=f"needs {', '.join(missing)}", baseline_status="skipped"
            )
            continue
        baseline = replace(clean_baselines[name]) if clean_baselines is not None else runner(suite, root)
        baseline.baseline_status = baseline.status
        baseline.baseline_seconds = baseline.seconds
        baseline.baseline_tail = baseline.tail
        if baseline.status == "passed":
            runnable.append(name)
        else:
            baseline.status = "unscored"
        baselines[name] = baseline

    if not runnable:
        result.suites = [baselines[name] for name in scenario.suites]
        result.outcome = "skipped" if all(row.baseline_status == "skipped" for row in result.suites) else "unscored"
        result.seconds = round(time.monotonic() - started, 1)
        return result

    _journal_write(journal, path, original_text)
    try:
        path.write_text(original_text.replace(scenario.original, scenario.mutant, 1), encoding="utf-8")
        mutation_results: dict[str, SuiteResult] = {}
        for name in runnable:
            suite = catalogue.suites[name]
            outcome = runner(suite, root)
            baseline = baselines[name]
            outcome.baseline_status = baseline.baseline_status
            outcome.baseline_seconds = baseline.baseline_seconds
            outcome.baseline_tail = baseline.baseline_tail
            mutation_results[name] = outcome
            if outcome.status in ("failed", "unviable", "timeout") and result.outcome == "survived":
                result.outcome = {"failed": "killed"}.get(outcome.status, outcome.status)
                result.killed_by = name if outcome.status == "failed" else ""
                result.killed_test = outcome.failure_test if outcome.status == "failed" else ""
                if not all_suites or outcome.status == "unviable":
                    break
        result.suites = []
        for name in scenario.suites:
            baseline = baselines[name]
            if name in mutation_results:
                result.suites.append(mutation_results[name])
            elif baseline.baseline_status == "passed":
                result.suites.append(SuiteResult(
                    name, "not-run", baseline_status="passed",
                    baseline_seconds=baseline.baseline_seconds,
                    baseline_tail=baseline.baseline_tail,
                    tail="Mutation suite was not run after an earlier suite ended the scenario.",
                ))
            else:
                result.suites.append(baseline)
        if result.outcome == "survived" and any(
            baselines[name].baseline_status not in ("passed", "skipped") for name in scenario.suites
        ):
            result.outcome = "unscored"
    finally:
        path.write_text(original_text, encoding="utf-8")
        if journal.exists():
            journal.unlink()
    result.seconds = round(time.monotonic() - started, 1)
    return result


def run_clean_baselines(
    names: Sequence[str],
    catalogue: Catalogue,
    capabilities: frozenset[str],
    root: Path = PROJECT_ROOT,
    runner: Runner = run_suite,
) -> dict[str, SuiteResult]:
    """Run each selected suite once before any mutant changes the source tree."""
    results: dict[str, SuiteResult] = {}
    for name in sorted(set(names)):
        suite = catalogue.suites[name]
        missing = [requirement for requirement in suite.requires if requirement not in capabilities]
        if missing:
            results[name] = SuiteResult(name, "skipped", tail=f"needs {', '.join(missing)}")
        else:
            results[name] = runner(suite, root)
    return results


def summarise(results: Sequence[ScenarioResult]) -> dict:
    counts: dict[str, int] = {}
    for r in results:
        counts[r.outcome] = counts.get(r.outcome, 0) + 1
    killed, survived = counts.get("killed", 0), counts.get("survived", 0)
    scored = killed + survived
    by_layer: dict[str, dict[str, int]] = {}
    for r in results:
        bucket = by_layer.setdefault(r.layer, {})
        bucket[r.outcome] = bucket.get(r.outcome, 0) + 1
    baseline_failures: dict[tuple[str, str, str], set[str]] = {}
    for result in results:
        for suite in result.suites:
            if suite.baseline_status and suite.baseline_status not in ("passed", "skipped"):
                key = (suite.suite, suite.baseline_status, suite.baseline_tail)
                baseline_failures.setdefault(key, set()).add(result.id)
    return {
        "total": len(results),
        "counts": counts,
        "score": round(killed / scored, 3) if scored else None,
        "by_layer": by_layer,
        "survivors": [r.id for r in results if r.outcome == "survived"],
        "unscored": [r.id for r in results if r.outcome == "unscored"],
        "baseline_failures": [
            {"suite": suite, "status": status, "diagnostics": diagnostics, "affected_ids": sorted(ids)}
            for (suite, status, diagnostics), ids in sorted(baseline_failures.items())
        ],
    }


def markdown_report(results: Sequence[ScenarioResult], catalogue: Catalogue) -> str:
    by_id = {s.id: s for s in catalogue.scenarios}
    summary = summarise(results)
    score = "n/a" if summary["score"] is None else f"{summary['score']:.0%}"
    lines = [
        "# Mutation run",
        "",
        f"Scenarios: {summary['total']} · score: **{score}** · "
        + " · ".join(f"{k}: {v}" for k, v in sorted(summary["counts"].items())),
        "",
        "| ID | Layer | Area | Operator | Risk | Outcome | Killed by | Failure test | Seconds |",
        "|---|---|---|---|---|---|---|---|---:|",
    ]
    for r in results:
        lines.append(
            f"| {r.id} | {r.layer} | {r.area} | {r.operator} | {r.risk} | "
            f"{'**SURVIVED**' if r.outcome == 'survived' else r.outcome} | {r.killed_by or '-'} | "
            f"{r.killed_test or '-'} | {r.seconds} |"
        )
    survivors = [r for r in results if r.outcome == "survived"]
    if survivors:
        lines += ["", "## Survivors", ""]
        for r in survivors:
            s = by_id[r.id]
            lines.append(f"- **{r.id}** `{s.file}` — {s.intent}")
    if summary["baseline_failures"]:
        lines += ["", "## Failed clean baselines", ""]
        for failure in summary["baseline_failures"]:
            lines.append(
                f"- `{failure['suite']}` clean baseline {failure['status']} for "
                f"{', '.join(failure['affected_ids'])}. Diagnostics: "
                f"{failure['diagnostics'] or 'No output was captured.'}"
            )
    return "\n".join(lines) + "\n"


def _print_table(rows: list[list[str]]) -> None:
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    for row in rows:
        print("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["list", "validate", "baseline", "run", "restore"])
    parser.add_argument("--catalogue", type=Path, default=DEFAULT_CATALOGUE)
    parser.add_argument("--id", action="append", default=[], help="scenario id (repeatable)")
    parser.add_argument("--layer", action="append", default=[], help="rust, flutter, python, db (repeatable)")
    parser.add_argument("--area", action="append", default=[], help="functional area (repeatable)")
    parser.add_argument("--with", dest="capabilities", action="append", default=[],
                        help="capability a suite may require, e.g. postgres (repeatable)")
    parser.add_argument("--all-suites", action="store_true", help="keep running suites after the first kill")
    parser.add_argument("--allow-dirty", action="store_true", help="mutate files with uncommitted changes")
    parser.add_argument("--json", action="store_true", help="print JSON instead of text")
    parser.add_argument("--output", type=Path, help="write the JSON result here")
    parser.add_argument("--markdown", type=Path, help="write a markdown report here")
    parser.add_argument(
        "--changed",
        nargs="?",
        const="",
        default=None,
        metavar="BASE",
        help="only run scenarios targeting files changed in git (optionally compared against BASE)",
    )
    parser.add_argument(
        "--direct-only",
        action="store_true",
        help="with --changed, select only directly changed scenario target files",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit with code 1 if any mutant survives, is unscored, times out, or fails to compile",
    )
    args = parser.parse_args(argv)
    if args.direct_only and args.changed is None:
        parser.error("--direct-only requires --changed")

    if args.command == "restore":
        restored = restore()
        print(f"restored {restored}" if restored else "nothing to restore")
        return 0

    catalogue = load_catalogue(args.catalogue)
    problems = validate(catalogue)
    if args.command == "validate":
        if args.json:
            print(json.dumps({"scenarios": len(catalogue.scenarios), "problems": problems}, indent=2))
        else:
            print("\n".join(problems) or f"ok: {len(catalogue.scenarios)} scenarios, {len(catalogue.suites)} suites")
        return 1 if problems else 0

    changed_files = None
    if args.changed is not None:
        try:
            changed_files = detect_changed_files(PROJECT_ROOT, base=args.changed if args.changed else None)
        except ValueError as err:
            print(f"error: {err}", file=sys.stderr)
            return 2

    chosen = select(
        catalogue, args.id, args.layer, args.area,
        changed_files=changed_files, direct_only=args.direct_only,
    )
    if args.changed is not None and not chosen:
        if args.command == "list":
            if args.json:
                print(json.dumps([], indent=2))
            else:
                print("no mutation scenarios match changed files")
            return 0
        if args.command in ("baseline", "run"):
            if args.json:
                print(json.dumps({"summary": {"score": None, "counts": {}, "survivors": [],
                                                "unscored": [], "baseline_failures": [], "by_layer": {}},
                                  "results": []}, indent=2))
            else:
                print("no mutation scenarios match changed files")
            return 0

    if args.command == "list":
        if args.json:
            print(json.dumps([asdict(s) for s in chosen], indent=2))
        else:
            _print_table([["ID", "LAYER", "AREA", "OPERATOR", "RISK", "FILE"]]
                         + [[s.id, s.layer, s.area, s.operator, s.risk, s.file] for s in chosen])
        return 0

    if problems:
        print("catalogue problems (run `validate`):\n" + "\n".join(problems), file=sys.stderr)
        return 2
    capabilities = frozenset(args.capabilities)

    if args.command == "baseline":
        names = sorted({n for s in chosen for n in s.suites})
        baselines = run_clean_baselines(names, catalogue, capabilities, runner=run_suite)
        results = [baselines[name] for name in names]
        for result in results:
            print(f"{result.suite}: {result.status} ({result.seconds:.0f}s)", file=sys.stderr)
        if args.json:
            print(json.dumps([asdict(r) for r in results], indent=2))
        failing = [r for r in results if r.status not in ("passed", "skipped")]
        for r in failing:
            print(f"baseline {r.suite} {r.status}:\n{r.tail}", file=sys.stderr)
        return 1 if failing else 0

    if _journal_entry(JOURNAL, PROJECT_ROOT) is not None:
        print(f"an interrupted run left {JOURNAL}; run `restore` first", file=sys.stderr)
        return 2
    if not args.allow_dirty:
        dirty = sorted({s.file for s in chosen if _git_dirty(PROJECT_ROOT, s.file)})
        if dirty:
            print("refusing to mutate files with uncommitted changes:\n  " + "\n  ".join(dirty), file=sys.stderr)
            return 2

    suite_names = sorted({name for scenario in chosen for name in scenario.suites})
    clean_baselines = run_clean_baselines(suite_names, catalogue, capabilities, runner=run_suite)
    for baseline in clean_baselines.values():
        print(f"baseline {baseline.suite}: {baseline.status} ({baseline.seconds:.0f}s)", file=sys.stderr)
        if baseline.status not in ("passed", "skipped"):
            print(f"baseline {baseline.suite} {baseline.status}:\n{baseline.tail}", file=sys.stderr)

    results: list[ScenarioResult] = []
    for index, scenario in enumerate(chosen, 1):
        result = run_scenario(
            scenario, catalogue, capabilities=capabilities, all_suites=args.all_suites,
            clean_baselines=clean_baselines,
        )
        results.append(result)
        if not args.json:
            print(f"[{index}/{len(chosen)}] {scenario.id} {result.outcome}"
                  f"{' by ' + result.killed_by if result.killed_by else ''} ({result.seconds}s)", flush=True)
    summary = summarise(results)
    payload = {"summary": summary, "results": [asdict(r) for r in results]}
    if args.output:
        args.output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.write_text(markdown_report(results, catalogue), encoding="utf-8")
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        score = "n/a" if summary["score"] is None else f"{summary['score']:.0%}"
        print(f"score {score}; " + ", ".join(f"{k} {v}" for k, v in sorted(summary["counts"].items())))
        if summary["survivors"]:
            print("survivors: " + ", ".join(summary["survivors"]))
    if args.strict:
        has_survivors = bool(summary["survivors"])
        has_unviable = summary["counts"].get("unviable", 0) > 0
        has_timeout = summary["counts"].get("timeout", 0) > 0
        has_unscored = summary["counts"].get("unscored", 0) > 0
        has_baseline_failures = bool(summary["baseline_failures"])
        if has_survivors or has_unviable or has_timeout or has_unscored or has_baseline_failures:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
