"""Loop runner: runs a task's checker gates and records auditable evidence.

For a task the runner executes the global build gates, then the task's own
``gates``, then its named ``acceptance_tests``. A task passes only when every
one of them passes; a task with nothing to run cannot pass.

Retry budget (maker-checker loop): each recorded failing run increments the
task's ``attempts``. Below ``max_budget`` the task is FAILED and goes back to
the maker; at the budget it becomes BLOCKED and needs a human.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

from harness.loop.verification_gates import GLOBAL_GATES, GateResult, run_acceptance_tests, run_gate


def git_state(root: Path) -> Dict[str, Any]:
    """Current commit and whether the working tree has uncommitted changes."""
    def git(*args: str) -> Optional[str]:
        try:
            return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return None

    sha = git("rev-parse", "HEAD")
    dirty = git("status", "--porcelain", "--", ".")
    return {"commit": sha, "dirty": bool(dirty) if dirty is not None else None}


class LoopRunner:
    def __init__(self, max_budget: int = 3, include_global: bool = True):
        self.max_budget = max_budget
        self.include_global = include_global

    def run_task_gates(self, task: Dict[str, Any], project_root: Path) -> Dict[str, Any]:
        started = _dt.datetime.now(_dt.timezone.utc)
        gate_names: List[str] = (GLOBAL_GATES if self.include_global else []) + [
            g for g in task.get("gates", []) if not (self.include_global and g in GLOBAL_GATES)
        ]
        gate_results: List[GateResult] = [run_gate(g, project_root) for g in gate_names]
        tests = task.get("acceptance_tests", [])
        test_results = run_acceptance_tests(tests, project_root) if tests else {}

        everything = gate_results + list(test_results.values())
        passed = bool(everything) and all(r.passed for r in everything)
        diagnostics: List[str] = []
        for r in everything:
            if not r.passed:
                diagnostics.append(f"[{r.name}]")
                diagnostics.extend(f"    {d}" for d in r.diagnostics[:25])
        if not everything:
            diagnostics.append("Task declares no gates or acceptance tests; nothing was verified.")
        return {
            "task_id": task["id"],
            "passed": passed,
            "started_at": started.isoformat(),
            "finished_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "gates": [r.to_dict() for r in gate_results],
            "acceptance_tests": [{"id": k, **v.to_dict()} for k, v in test_results.items()],
            "gates_evaluated": len(everything),
            "diagnostics": diagnostics,
        }

    def next_status(self, passed: bool, attempts: int) -> str:
        if passed:
            return "COMPLETED"
        return "BLOCKED" if attempts >= self.max_budget else "FAILED"


def write_evidence(evidence_dir: Path, result: Dict[str, Any], git: Dict[str, Any], attempts: int) -> Path:
    """Atomically writes ``.specify/evidence/<task>.json``."""
    evidence_dir.mkdir(parents=True, exist_ok=True)
    payload = {**result, **git, "attempts": attempts}
    target = evidence_dir / f"{result['task_id']}.json"
    fd, tmp = tempfile.mkstemp(dir=evidence_dir, prefix=f".{result['task_id']}.", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, target)
    return target


def read_evidence(evidence_dir: Path, task_id: str) -> Optional[Dict[str, Any]]:
    path = evidence_dir / f"{task_id}.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
