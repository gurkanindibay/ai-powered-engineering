"""Verification gates for the SitePulse harness.

Every gate runs the real toolchain (compiler, linter, test runner, database or
HTTP checks) and fails when the tool fails. There is no simulated gate: a gate
that cannot run (missing toolchain, timeout) is a failure, never a pass.

Gates are referenced by name from ``task-dag.json`` (``gates``) and from the
CLI. Acceptance tests are referenced by id:

* ``rust:<test target>::<test name>``  e.g. ``rust:integration_tests::when_wrong_password_then_throws_exception``
* ``rust:lib::<path::to::test>``       unit tests inside the library crate
* ``flutter:<test file>``              e.g. ``flutter:test/financial_fixture_test.dart``
* ``system:<check name>``              a check of ``scripts/api_system_check.py``
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence

import ci_case_results

TAIL_LINES = 40


@dataclass
class GateResult:
    name: str
    passed: bool
    diagnostics: List[str] = field(default_factory=list)
    command: str = ""
    duration_s: float = 0.0
    exit_code: int | None = None
    timed_out: bool = False
    # Full tool output, kept for parsing; not written to evidence files.
    output: str = field(default="", repr=False)
    stdout: str = field(default="", repr=False)
    stderr: str = field(default="", repr=False)

    def to_dict(self) -> Dict[str, object]:
        d = asdict(self)
        d.pop("output", None)
        d.pop("stdout", None)
        d.pop("stderr", None)
        return d


@dataclass(frozen=True)
class CommandSpec:
    """A command to run from a directory relative to the SitePulse root."""

    argv: Sequence[str]
    cwd: str
    timeout_s: int = 900


def _cache_file(spec: CommandSpec, root: Path) -> "Path | None":
    """Opt-in cache of PASSED commands (``SITEPULSE_GATE_CACHE_DIR``), used by CI evidence recording.

    Recording evidence verifies every task in one checkout, and each task repeats the same global
    gates (build, clippy, analyze, lints). Within a single run the checkout does not change, so a
    command that already passed is not re-run. Only passes are cached; failures always re-run.
    """
    cache_dir = os.environ.get("SITEPULSE_GATE_CACHE_DIR")
    if not cache_dir:
        return None
    key = hashlib.sha256(json.dumps([list(spec.argv), spec.cwd, str(root.resolve())]).encode()).hexdigest()[:32]
    return Path(cache_dir) / f"{key}.json"


def run_command(name: str, spec: CommandSpec, root: Path) -> GateResult:
    """Runs one command; a missing executable, timeout or non-zero exit fails the gate."""
    exe = spec.argv[0]
    command = " ".join(spec.argv)
    cache = _cache_file(spec, root)
    if cache is not None and cache.is_file():
        try:
            hit = json.loads(cache.read_text())
            return GateResult(name, True, [], command, float(hit.get("duration_s", 0.0)),
                              int(hit.get("exit_code", 0)), output=hit.get("output", ""),
                              stdout=hit.get("stdout", ""), stderr=hit.get("stderr", ""))
        except (OSError, ValueError):
            pass
    if shutil.which(exe) is None:
        return GateResult(name, False, [f"Required tool '{exe}' is not installed or not on PATH"], command)
    started = time.monotonic()
    try:
        proc = subprocess.run(
            list(spec.argv),
            cwd=root / spec.cwd,
            capture_output=True,
            text=True,
            timeout=spec.timeout_s,
            env={**os.environ, "CARGO_TERM_COLOR": "never", "NO_COLOR": "1"},
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        output = str(stdout) + str(stderr)
        return GateResult(name, False, [f"Timed out after {spec.timeout_s}s"], command,
                          time.monotonic() - started, output=output, timed_out=True,
                          stdout=str(stdout), stderr=str(stderr))
    duration = time.monotonic() - started
    output = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode == 0:
        if cache is not None:
            try:
                cache.parent.mkdir(parents=True, exist_ok=True)
                cache.write_text(json.dumps({"duration_s": duration, "exit_code": proc.returncode, "output": output,
                                             "stdout": proc.stdout or "", "stderr": proc.stderr or ""}))
            except OSError:
                pass
        return GateResult(name, True, [], command, duration, proc.returncode, output=output,
                          stdout=proc.stdout or "", stderr=proc.stderr or "")
    return GateResult(name, False, extract_diagnostics(output), command, duration,
                      proc.returncode, output=output, stdout=proc.stdout or "", stderr=proc.stderr or "")


def extract_diagnostics(output: str) -> List[str]:
    """Keeps compiler errors, failing test names and the tail of the output."""
    lines = output.splitlines()
    picked = [
        l.strip()
        for l in lines
        if re.search(r"^(error(\[E\d+\])?:|\s*--> |test .* FAILED|---- .* stdout ----|.*\[E\]$|\s*error •|FAILED\b)", l)
    ]
    tail = [l.rstrip() for l in lines[-TAIL_LINES:]]
    seen: List[str] = []
    for l in picked[:60] + ["--- output tail ---"] + tail:
        if l and l not in seen:
            seen.append(l)
    return seen


# ---------------------------------------------------------------------------
# Gate catalogue
# ---------------------------------------------------------------------------

GATES: Dict[str, List[CommandSpec]] = {
    "rust-build": [CommandSpec(["cargo", "build", "--all-targets", "--locked"], "backend")],
    "rust-clippy": [CommandSpec(["cargo", "clippy", "--all-targets", "--locked", "--", "-D", "warnings"], "backend")],
    "rust-fmt": [CommandSpec(["cargo", "fmt", "--check"], "backend", 120)],
    "rust-test": [CommandSpec(["cargo", "test", "--locked"], "backend")],
    # The PostgreSQL persistence path: RLS tenant isolation, read-only GETs,
    # transactional advance offsets, 503 on database failure (needs DB_PASS).
    # The unit state model (EPIC-08 §3): guarded transitions, derived status.
    # The person API and merge, and unit and person actions repeated in cycles.
    # Every test creates its own throwaway database (named by tag and process id), so the tests
    # run 4 at a time: all five files in one cargo run took 74 s sequentially and 28 s this way.
    "rust-db-test": [CommandSpec(["cargo", "test", "--locked",
                                  "--test", "db_tenant_isolation_tests",
                                  "--test", "db_occupancy_transitions_tests",
                                  "--test", "db_person_api_tests",
                                  "--test", "db_person_merge_tests",
                                  "--test", "db_unit_person_action_cycles_tests",
                                  "--test", "db_accrual_atomic_tests",
                                  "--test", "db_accrual_persistence_tests",
                                  "--test", "db_advance_exit_settlements_tests",
                                  "--", "--ignored", "--test-threads=4"], "backend", 900),
                        # These opt-in PostgreSQL tests were previously never reached by CI.
                        # The CI job uses a fresh service database for this gate.
                        CommandSpec(["env", "SITEPULSE_PG_TESTS=1", "cargo", "test", "--locked",
                                     "--test", "accrual_corrections_tests",
                                     "corrections_round_trip_through_postgresql", "--", "--exact"], "backend", 600),
                        CommandSpec(["env", "SITEPULSE_PG_TESTS=1", "cargo", "test", "--locked",
                                     "--test", "finance_store_pg_tests",
                                     "every_spec009_record_round_trips_through_postgresql", "--", "--exact"], "backend", 600)],
    # Errors are fatal; warnings/infos are reported by `flutter analyze` itself.
    "flutter-analyze": [CommandSpec(["flutter", "analyze", "--no-fatal-infos", "--no-fatal-warnings"], "flutter", 600)],
    "flutter-test": [CommandSpec(["flutter", "test", "--reporter=json"], "flutter", 1200)],
    # One fixture file, run against the Rust services and the Dart use case.
    "money-fixtures": [
        CommandSpec(["cargo", "test", "--locked", "--test", "financial_fixtures"], "backend"),
        CommandSpec(["flutter", "test", "--reporter=json", "test/financial_fixture_test.dart"], "flutter", 600),
    ],
    "harness-selftest": [CommandSpec(["python3", "scripts/unittest_json_runner.py", "-s", "harness/tests"], ".", 300)],
    "schema-integrity": [CommandSpec(["python3", "scripts/schema_integrity_check.py", "--json"], ".", 600)],
    "persistence-lint": [CommandSpec(["python3", "scripts/memory_persistence_lint.py", "--json"], ".", 120)],
    "api-system": [CommandSpec(["python3", "scripts/api_system_check.py", "--json"], ".", 900)],
    # Every widget Key in flutter/lib/ui must have the same id as a GUI automation testId.
    "testid-lint": [CommandSpec(["python3", "scripts/testid_lint.py", "--json"], ".", 120)],
    # Epic -> story -> Gherkin scenario catalogue (.specify/features): every story of a migrated
    # epic has a scenario, scenario ids are unique, `covers` links point at real scenarios.
    "feature-traceability": [CommandSpec(["python3", "scripts/feature_traceability.py", "--json", "check"], ".", 120)],
    # AGENTS.md rule 13: a task branch that changes behaviour carries a recorded test run
    # (.specify/executions) whose latest run has no failing scenario. No-op on the main branch.
    "test-run-recorded": [CommandSpec(["python3", "scripts/feature_traceability.py", "--json", "check", "--require-run"], ".", 120)],
    # Design-system rules (12 px floor, MoneyFormatter, no emoji icons, ratchet on literal styles).
    "ui-style-lint": [CommandSpec(["python3", "scripts/ui_style_lint.py", "--json"], ".", 120)],
    # Rust standards (docs/standards/RUST_STANDARDS.md 10-16): domain purity, layering, shared rules,
    # no per-call regex / implicit rounding / floats; ratchet on unwrap, String errors, fmt.
    "rust-standards-lint": [CommandSpec(["python3", "scripts/rust_standards_lint.py", "--json"], ".", 300)],
    # Shared-component reuse guard: no raw clipboard writes, hand-rolled amount parsing or
    # JSON Decimal fallbacks outside the shared helpers (docs/reusability/flutter-reusability-report.md).
    "flutter-reuse": [CommandSpec(["python3", "scripts/flutter_reuse_inventory.py", "--check", "--json"], ".", 120)],
    # Multi-tenant guardrails: handlers pin site input through TenantScope, object-id
    # routes check ownership, no guessed tenants, service transactions bind their
    # tenant, and every tenant-keyed table has a row-level security policy (V21).
    "tenant-lint": [CommandSpec(["python3", "scripts/tenant_isolation_lint.py", "--json"], ".", 120)],
    # No guard on the global AppState lock is held across database/network I/O.
    "lock-lint": [CommandSpec(["python3", "scripts/lock_scope_lint.py", "--json"], ".", 120)],
    # Cross-stack logging standards (docs/standards/LOGGING_STANDARDS.md): no println/dbg in backend,
    # no raw print in Flutter, structured AppLogger usage, no credential leaks.
    "logging-standards-lint": [CommandSpec(["python3", "scripts/logging_standards_lint.py", "--json"], ".", 120)],
    # Static security guardrails (docs/quality/SECURITY_ASSESSMENT.md): no tracked credential files or
    # hard-coded secrets, least-privilege workflows, pinned images, reviewed public routes, guarded
    # development routes, no permissive CORS / weak crypto / client token storage, error-leak ratchet.
    "security-lint": [CommandSpec(["python3", "scripts/security_lint.py", "--json"], ".", 120)],
    # Browser end-to-end suite (e2e/): isolated DB, release backend, Flutter E2E web build, Chrome.
    # Strict xfails pin known product defects; an unexpected pass (XPASS) fails the gate.
    "gui-e2e": [CommandSpec(["python3", "scripts/gui_e2e.py", "run", "--json"], ".", 3600)],
}

# Run for every task before its own gates: the code must build and lint cleanly, and the
# task must have recorded the test run that verifies it.
GLOBAL_GATES: List[str] = ["rust-build", "rust-clippy", "flutter-analyze", "test-run-recorded"]


def run_gate(name: str, root: Path) -> GateResult:
    if name not in GATES:
        return GateResult(name, False, [f"Unknown gate '{name}'. Known gates: {', '.join(sorted(GATES))}"])
    results = [run_command(name, spec, root) for spec in GATES[name]]
    gate = GateResult(
        name,
        all(r.passed for r in results),
        [d for r in results for d in r.diagnostics],
        " && ".join(r.command for r in results),
        sum(r.duration_s for r in results),
        next((r.exit_code for r in results if r.exit_code not in (None, 0)), 0 if all(r.passed for r in results) else None),
        any(r.timed_out for r in results),
    )
    _write_gate_artifacts(name, GATES[name], results, root)
    return gate


def _write_gate_artifacts(name: str, specs: Sequence[CommandSpec], results: Sequence[GateResult], root: Path) -> None:
    """Persist raw command outcomes and adapted cases for CI without changing runner behavior."""
    destination = os.environ.get("SITEPULSE_GATE_ARTIFACT_DIR")
    if not destination:
        return
    out = Path(destination)
    out.mkdir(parents=True, exist_ok=True)
    for index, (spec, result) in enumerate(zip(specs, results), start=1):
        argv = list(spec.argv)
        cargo_index = argv.index("cargo") if "cargo" in argv else -1
        cargo_argv = argv[cargo_index:] if cargo_index >= 0 else []
        text = result.output
        structured_output = result.stdout
        cases: list[dict[str, object]] = []
        native_runner: str | None = None
        payload: dict[str, object] | None = None
        if cargo_argv:
            native_runner = "cargo"
            suite = "money-fixtures" if "financial_fixtures" in cargo_argv else "rust-db-opt-in" if any(target in cargo_argv for target in ("accrual_corrections_tests", "finance_store_pg_tests")) else "rust-db-test" if "--ignored" in cargo_argv or "SITEPULSE_PG_TESTS=1" in argv else name
            cases = ci_case_results.parse_cargo(text, suite)
        elif argv and argv[0] == "flutter" and "test" in argv:
            native_runner = "flutter"
            suite = "money-fixtures" if "financial_fixture_test.dart" in argv else name
            cases = ci_case_results.parse_flutter_json(structured_output, suite)
        elif any("unittest_json_runner.py" in part for part in argv):
            native_runner = "unittest"
            result_file = Path(destination) / "unittest-case-results.json"
            try:
                result_payload = json.loads(result_file.read_text(encoding="utf-8"))
                raw_cases = result_payload.get("cases", [])
                cases = [dict(case) for case in raw_cases if isinstance(case, dict)]
                payload = {"tests_run": result_payload.get("tests_run"),
                           "adapter_test_count": result_payload.get("adapter_test_count")}
            except (OSError, json.JSONDecodeError):
                cases = ci_case_results.parse_unittest_verbose(text, name)
        elif any("api_system_check.py" in part or "schema_integrity_check.py" in part for part in argv):
            try:
                payload = json.loads(structured_output)
                cases = ci_case_results.parse_check_json(payload, "sitepulse-check", name)
            except json.JSONDecodeError:
                cases = []
            native_runner = "sitepulse-check"
        record = {"schema_version": 1, "gate": name, "command_index": index, "argv": argv,
                  "cwd": spec.cwd, "exit_code": result.exit_code, "timed_out": result.timed_out,
                  "passed": result.passed, "duration_s": round(result.duration_s, 3),
                  "native_runner_totals": ({"total": payload.get("tests_run"), "complete": True}
                                            if native_runner == "unittest" and payload else
                                            ci_case_results.native_totals(text, native_runner, payload) if native_runner else None),
                  "native_case_count": payload.get("adapter_test_count") if native_runner == "unittest" and payload else len(cases),
                  "runner_errors": ci_case_results.flutter_reporter_errors(text) if native_runner == "flutter" else [],
                  "adapter_case_count": len(cases), "cases": cases, "native_output": text}
        (out / f"{name}-{index}.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Acceptance tests
# ---------------------------------------------------------------------------

ACCEPTANCE_ID = re.compile(r"^(rust:[A-Za-z0-9_]+::[A-Za-z0-9_:]+|flutter:test/[A-Za-z0-9_/]+\.dart|system:[a-z0-9_]+"
                           r"|scenario:SC-\d{2}-\d{2}-\d{2})$")


def is_valid_acceptance_id(test_id: str) -> bool:
    return bool(ACCEPTANCE_ID.match(test_id))


def run_acceptance_tests(test_ids: Sequence[str], root: Path) -> Dict[str, GateResult]:
    """Runs named tests and returns a result per test id (grouped per runner)."""
    results: Dict[str, GateResult] = {}
    rust: Dict[str, List[str]] = {}
    system: List[str] = []
    scenarios: List[str] = []
    for tid in test_ids:
        if not is_valid_acceptance_id(tid):
            results[tid] = GateResult(tid, False, [f"Malformed acceptance test id '{tid}'"])
        elif tid.startswith("rust:"):
            target, name = tid[len("rust:"):].split("::", 1)
            rust.setdefault(target, []).append(name)
        elif tid.startswith("scenario:"):
            scenarios.append(tid[len("scenario:"):])
        elif tid.startswith("flutter:"):
            results[tid] = run_command(tid, CommandSpec(["flutter", "test", tid[len("flutter:"):]], "flutter", 600), root)
        else:
            system.append(tid[len("system:"):])

    for target, names in rust.items():
        argv = ["cargo", "test", "--locked"] + (["--lib"] if target == "lib" else ["--test", target])
        argv += ["--", "--exact"] + names
        res = run_command(f"rust:{target}", CommandSpec(argv, "backend"), root)
        output_ok = _rust_tests_reported(res.output, names)
        for n in names:
            ok = output_ok.get(n, False)
            results[f"rust:{target}::{n}"] = GateResult(
                f"rust:{target}::{n}", ok, [] if ok else (res.diagnostics or [f"Test '{n}' did not run or failed"]), res.command, res.duration_s
            )

    if system:
        res = run_command("system", CommandSpec(["python3", "scripts/api_system_check.py", "--json", "--only", ",".join(system)], ".", 900), root)
        per_check = _system_checks_reported(res, root, system)
        for c in system:
            ok = per_check.get(c, False)
            results[f"system:{c}"] = GateResult(f"system:{c}", ok, [] if ok else res.diagnostics, res.command, res.duration_s)
    if scenarios:
        # A Gherkin scenario (.specify/features) is accepted when its latest recorded execution passed.
        res = run_command("scenario", CommandSpec(["python3", "scripts/feature_traceability.py", "--json", "report"], ".", 120), root)
        statuses = _scenario_statuses(res.output)
        for s in scenarios:
            status = statuses.get(s)
            results[f"scenario:{s}"] = GateResult(
                f"scenario:{s}", status == "PASS",
                [] if status == "PASS" else [f"{s} is {status or 'not in .specify/features'}; its latest recorded execution must be PASS "
                                             f"(scripts/gui_e2e.py run --record)"], res.command, res.duration_s)
    return results


def _scenario_statuses(output: str) -> Dict[str, str]:
    """Reads `feature_traceability.py --json report`: {scenario id: latest status}."""
    try:
        data = json.loads(output[output.index("{"):])
    except ValueError:
        return {}
    return {row["id"]: row["status"] for epic in data.get("epics", []) for story in epic["stories"] for row in story["scenarios"]}


def _rust_tests_reported(output: str, names: Sequence[str]) -> Dict[str, bool]:
    """Reads libtest's per-test result lines (`test name ... ok`)."""
    status: Dict[str, bool] = {}
    for n in names:
        m = re.search(r"^test (?:\S+::)*" + re.escape(n.split("::")[-1]) + r" \.\.\. (ok|FAILED)$", output, re.M)
        status[n] = bool(m and m.group(1) == "ok")
    return status


def _system_checks_reported(res: GateResult, root: Path, checks: Sequence[str]) -> Dict[str, bool]:
    """Reads the JSON report printed by api_system_check.py --json."""
    try:
        data = json.loads(res.output[res.output.index("{"):])
    except ValueError:
        return {}
    return {c["name"]: c["passed"] for c in data.get("checks", []) if c.get("name") in checks}


def known_gate(name: str) -> bool:
    return name in GATES


def describe_gates() -> Dict[str, str]:
    return {name: " && ".join(" ".join(s.argv) for s in specs) for name, specs in GATES.items()}


__all__ = [
    "GateResult",
    "GATES",
    "GLOBAL_GATES",
    "run_gate",
    "run_acceptance_tests",
    "is_valid_acceptance_id",
    "known_gate",
    "describe_gates",
]
