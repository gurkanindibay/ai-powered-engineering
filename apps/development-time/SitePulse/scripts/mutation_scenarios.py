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
import json
import os
import subprocess
import sys
import tempfile
import time
import tomllib
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Sequence

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOGUE = PROJECT_ROOT / "harness" / "mutation" / "scenarios.toml"
JOURNAL = Path(tempfile.gettempdir()) / "sitepulse-mutation-journal.json"
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
    status: str  # passed | failed | unviable | timeout | skipped
    seconds: float = 0.0
    tail: str = ""


@dataclass
class ScenarioResult:
    id: str
    layer: str
    area: str
    operator: str
    risk: str
    outcome: str
    killed_by: str = ""
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


def select(catalogue: Catalogue, ids: Sequence[str], layers: Sequence[str], areas: Sequence[str]) -> list[Scenario]:
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
    return chosen


def _tail(text: str, lines: int = OUTPUT_TAIL) -> str:
    return "\n".join(text.strip().splitlines()[-lines:])


Runner = Callable[[Suite, Path], SuiteResult]


def run_suite(suite: Suite, root: Path) -> SuiteResult:
    env = dict(os.environ, **{ACTIVE_ENV: "1"})
    started = time.monotonic()
    try:
        proc = subprocess.run(
            suite.cmd,
            cwd=root / suite.cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=suite.timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return SuiteResult(suite.name, "timeout", time.monotonic() - started)
    output = proc.stdout + proc.stderr
    elapsed = time.monotonic() - started
    if proc.returncode == 0:
        return SuiteResult(suite.name, "passed", elapsed)
    status = "unviable" if any(m in output for m in UNVIABLE_MARKERS) else "failed"
    return SuiteResult(suite.name, status, elapsed, _tail(output))


def _git_dirty(root: Path, rel: str) -> bool:
    proc = subprocess.run(
        ["git", "status", "--porcelain", "--", rel], cwd=root, capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:  # not a git checkout (e.g. a self-test sandbox)
        return False
    return bool(proc.stdout.strip())


def _journal_write(journal: Path, path: Path, original: str) -> None:
    journal.write_text(json.dumps({"file": str(path), "text": original}), encoding="utf-8")


def restore(journal: Path = JOURNAL) -> str | None:
    """Writes back a file left mutated by an interrupted run; returns its path."""
    if not journal.exists():
        return None
    entry = json.loads(journal.read_text(encoding="utf-8"))
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
) -> ScenarioResult:
    path = root / scenario.file
    original_text = path.read_text(encoding="utf-8")
    if original_text.count(scenario.original) != 1:
        raise SystemExit(f"{scenario.id}: original snippet no longer occurs exactly once; run `validate`")
    result = ScenarioResult(
        scenario.id, scenario.layer, scenario.area, scenario.operator, scenario.risk, outcome="survived"
    )
    started = time.monotonic()
    _journal_write(journal, path, original_text)
    try:
        path.write_text(original_text.replace(scenario.original, scenario.mutant, 1), encoding="utf-8")
        ran = 0
        for name in scenario.suites:
            suite = catalogue.suites[name]
            missing = [r for r in suite.requires if r not in capabilities]
            if missing:
                result.suites.append(SuiteResult(name, "skipped", tail=f"needs {', '.join(missing)}"))
                continue
            ran += 1
            outcome = runner(suite, root)
            result.suites.append(outcome)
            if outcome.status in ("failed", "unviable", "timeout") and result.outcome == "survived":
                result.outcome = {"failed": "killed"}.get(outcome.status, outcome.status)
                result.killed_by = name if outcome.status == "failed" else ""
                if not all_suites or outcome.status == "unviable":
                    break
        if ran == 0:
            result.outcome = "skipped"
    finally:
        path.write_text(original_text, encoding="utf-8")
        if journal.exists():
            journal.unlink()
    result.seconds = round(time.monotonic() - started, 1)
    return result


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
    return {
        "total": len(results),
        "counts": counts,
        "score": round(killed / scored, 3) if scored else None,
        "by_layer": by_layer,
        "survivors": [r.id for r in results if r.outcome == "survived"],
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
        "| ID | Layer | Area | Operator | Risk | Outcome | Killed by | Seconds |",
        "|---|---|---|---|---|---|---|---:|",
    ]
    for r in results:
        lines.append(
            f"| {r.id} | {r.layer} | {r.area} | {r.operator} | {r.risk} | "
            f"{'**SURVIVED**' if r.outcome == 'survived' else r.outcome} | {r.killed_by or '-'} | {r.seconds} |"
        )
    survivors = [r for r in results if r.outcome == "survived"]
    if survivors:
        lines += ["", "## Survivors", ""]
        for r in survivors:
            s = by_id[r.id]
            lines.append(f"- **{r.id}** `{s.file}` — {s.intent}")
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
    args = parser.parse_args(argv)

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

    chosen = select(catalogue, args.id, args.layer, args.area)
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
        results = []
        for name in names:
            suite = catalogue.suites[name]
            if any(r not in capabilities for r in suite.requires):
                results.append(SuiteResult(name, "skipped", tail=f"needs {', '.join(suite.requires)}"))
                continue
            results.append(run_suite(suite, PROJECT_ROOT))
            print(f"{name}: {results[-1].status} ({results[-1].seconds:.0f}s)", file=sys.stderr)
        if args.json:
            print(json.dumps([asdict(r) for r in results], indent=2))
        failing = [r for r in results if r.status not in ("passed", "skipped")]
        for r in failing:
            print(f"baseline {r.suite} {r.status}:\n{r.tail}", file=sys.stderr)
        return 1 if failing else 0

    if JOURNAL.exists():
        print(f"an interrupted run left {JOURNAL}; run `restore` first", file=sys.stderr)
        return 2
    if not args.allow_dirty:
        dirty = sorted({s.file for s in chosen if _git_dirty(PROJECT_ROOT, s.file)})
        if dirty:
            print("refusing to mutate files with uncommitted changes:\n  " + "\n  ".join(dirty), file=sys.stderr)
            return 2

    results: list[ScenarioResult] = []
    for index, scenario in enumerate(chosen, 1):
        result = run_scenario(scenario, catalogue, capabilities=capabilities, all_suites=args.all_suites)
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
