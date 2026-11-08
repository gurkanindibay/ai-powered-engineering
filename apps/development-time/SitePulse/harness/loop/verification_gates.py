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

import json
import os
import re
import shutil
import subprocess
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence

TAIL_LINES = 40


@dataclass
class GateResult:
    name: str
    passed: bool
    diagnostics: List[str] = field(default_factory=list)
    command: str = ""
    duration_s: float = 0.0
    # Full tool output, kept for parsing; not written to evidence files.
    output: str = field(default="", repr=False)

    def to_dict(self) -> Dict[str, object]:
        d = asdict(self)
        d.pop("output", None)
        return d


@dataclass(frozen=True)
class CommandSpec:
    """A command to run from a directory relative to the SitePulse root."""

    argv: Sequence[str]
    cwd: str
    timeout_s: int = 900


def run_command(name: str, spec: CommandSpec, root: Path) -> GateResult:
    """Runs one command; a missing executable, timeout or non-zero exit fails the gate."""
    exe = spec.argv[0]
    command = " ".join(spec.argv)
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
    except subprocess.TimeoutExpired:
        return GateResult(name, False, [f"Timed out after {spec.timeout_s}s"], command, time.monotonic() - started)
    duration = time.monotonic() - started
    output = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode == 0:
        return GateResult(name, True, [], command, duration, output)
    return GateResult(name, False, extract_diagnostics(output), command, duration, output)


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
    # Errors are fatal; warnings/infos are reported by `flutter analyze` itself.
    "flutter-analyze": [CommandSpec(["flutter", "analyze", "--no-fatal-infos", "--no-fatal-warnings"], "flutter", 600)],
    "flutter-test": [CommandSpec(["flutter", "test"], "flutter", 1200)],
    # One fixture file, run against the Rust services and the Dart use case.
    "money-fixtures": [
        CommandSpec(["cargo", "test", "--locked", "--test", "financial_fixtures"], "backend"),
        CommandSpec(["flutter", "test", "test/financial_fixture_test.dart"], "flutter", 600),
    ],
    "harness-selftest": [CommandSpec(["python3", "-m", "unittest", "discover", "-s", "harness/tests"], ".", 300)],
    "schema-integrity": [CommandSpec(["python3", "scripts/schema_integrity_check.py", "--json"], ".", 600)],
    "persistence-lint": [CommandSpec(["python3", "scripts/memory_persistence_lint.py", "--json"], ".", 120)],
    "api-system": [CommandSpec(["python3", "scripts/api_system_check.py", "--json"], ".", 900)],
    # Every widget Key in flutter/lib/ui must have the same id as a GUI automation testId.
    "testid-lint": [CommandSpec(["python3", "scripts/testid_lint.py", "--json"], ".", 120)],
    # Design-system rules (12 px floor, MoneyFormatter, no emoji icons, ratchet on literal styles).
    "ui-style-lint": [CommandSpec(["python3", "scripts/ui_style_lint.py", "--json"], ".", 120)],
    # Shared-component reuse guard: no raw clipboard writes, hand-rolled amount parsing or
    # JSON Decimal fallbacks outside the shared helpers (docs/flutter-reusability-report.md).
    "flutter-reuse": [CommandSpec(["python3", "scripts/flutter_reuse_inventory.py", "--check", "--json"], ".", 120)],
    # Browser end-to-end suite (e2e/): isolated DB, release backend, Flutter E2E web build, Chrome.
    # Strict xfails pin known product defects; an unexpected pass (XPASS) fails the gate.
    "gui-e2e": [CommandSpec(["python3", "scripts/gui_e2e.py", "run", "--json"], ".", 3600)],
}

# Run for every task before its own gates: the code must build and lint cleanly.
GLOBAL_GATES: List[str] = ["rust-build", "rust-clippy", "flutter-analyze"]


def run_gate(name: str, root: Path) -> GateResult:
    if name not in GATES:
        return GateResult(name, False, [f"Unknown gate '{name}'. Known gates: {', '.join(sorted(GATES))}"])
    results = [run_command(name, spec, root) for spec in GATES[name]]
    return GateResult(
        name,
        all(r.passed for r in results),
        [d for r in results for d in r.diagnostics],
        " && ".join(r.command for r in results),
        sum(r.duration_s for r in results),
    )


# ---------------------------------------------------------------------------
# Acceptance tests
# ---------------------------------------------------------------------------

ACCEPTANCE_ID = re.compile(r"^(rust:[A-Za-z0-9_]+::[A-Za-z0-9_:]+|flutter:test/[A-Za-z0-9_/]+\.dart|system:[a-z0-9_]+)$")


def is_valid_acceptance_id(test_id: str) -> bool:
    return bool(ACCEPTANCE_ID.match(test_id))


def run_acceptance_tests(test_ids: Sequence[str], root: Path) -> Dict[str, GateResult]:
    """Runs named tests and returns a result per test id (grouped per runner)."""
    results: Dict[str, GateResult] = {}
    rust: Dict[str, List[str]] = {}
    system: List[str] = []
    for tid in test_ids:
        if not is_valid_acceptance_id(tid):
            results[tid] = GateResult(tid, False, [f"Malformed acceptance test id '{tid}'"])
        elif tid.startswith("rust:"):
            target, name = tid[len("rust:"):].split("::", 1)
            rust.setdefault(target, []).append(name)
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
    return results


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
