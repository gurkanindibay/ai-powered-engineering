"""Disposable repositories and deterministic bridge for fault-injection tests."""
from copy import deepcopy
from pathlib import Path

from scripts.engineering_harness.backend import Execution
from scripts.engineering_harness.contracts import digest
from scripts.engineering_harness.routing import ROLES
from scripts.engineering_harness.workspace import git


def capabilities():
    return {"schema_version": 1, "targets": [
        {"provider": "fixture", "model": "deterministic", "tiers": ["low", "medium", "high", "critical"],
         "roles": list(ROLES), "options": {"effort": ["low", "high"]}, "max_tokens": 1000,
         "input_per_million": "1.00", "output_per_million": "2.00",
         "price_date": "2026-11-08", "benchmark_id": "fixture-only-not-a-model-evaluation"}]}


def policy():
    paths = {role: [] for role in ROLES}
    paths.update(developer=["src"], backend_developer=["src"], frontend_developer=["ui"])
    return {"schema_version": 1, "image": "sha256:" + "a" * 64, "bridge": ["fixture-bridge"], "network": "none",
            "limits": {"tokens": 20000, "attempt_tokens": 1000, "cost": "1", "seconds": 600,
                       "attempt_seconds": 30, "max_repairs": 3, "memory_mb": 128, "cpus": 1,
                       "pids": 32, "output_bytes": 65536},
            "role_paths": paths, "protected_paths": ["checks", "policy.json"], "preferences": {},
            "gates": [{"id": "unit", "argv": ["python3", "-m", "unittest"], "cwd": ".", "timeout": 30,
                       "test_pattern": r"Ran (?P<count>\d+) tests?"}],
            "acceptance": {"Behavior passes regression tests": ["unit"]}}


def repository(path: Path):
    path.mkdir()
    (path / "src").mkdir()
    (path / "src" / "value.py").write_text("VALUE = 0\n")
    (path / "checks").mkdir()
    (path / "checks" / "test_value.py").write_text("# Trusted checker\n")
    git(path, "init", "--quiet")
    git(path, "add", "--all")
    git(path, "commit", "--quiet", "-m", "fixture")
    return path


def response(envelope):
    role = envelope["role"]
    artifacts = {
        "coordinator": {"work_plan": ["Implement accepted scope", "Integrate and verify"], "coordination_risks": []},
        "product_owner": {"scope": "Implement bounded behavior", "acceptance_criteria": ["Behavior passes regression tests"], "exclusions": []},
        "business_analyst": {"domain_rules": ["Preserve data"], "contracts": {"v1": "Bounded behavior"}, "edge_cases": ["Empty input"]},
        "architect": {"design": "Layered architecture", "risks": []},
        "tester": {"criteria": {c: "pass" for c in envelope["acceptance"]}, "verdict": "pass", "residual_risks": []},
    }.get(role, {"changes": ["src/value.py"], "tests": ["unit"]})
    return {"schema_version": 1, "run_id": envelope["run_id"], "task_id": envelope["task_id"],
            "attempt_id": envelope["attempt_id"], "candidate": envelope["candidate"], "input_hash": digest(envelope),
            "status": "completed", "summary": "Completed fixture role", "artifacts": artifacts,
            "issues": [], "usage": {"input_tokens": 10, "output_tokens": 5}}


class FakeBackend:
    """Does not call an LLM; tests observable controller behavior only."""
    def __init__(self, config):
        self.config = config
        self.calls = []
        self.mode = "success"
        self.gate_runs = 0
        self.stopped = []
        self.live = "running"
        self.transform = lambda result: result

    def capabilities(self, name, **kwargs):
        return capabilities()

    def execute(self, name, argv, **kwargs):
        import json
        self.calls.append((name, kwargs))
        envelope = kwargs.get("payload")
        if envelope is not None:
            result = response(envelope)
            if envelope["role"] in ("developer", "backend_developer"):
                file = kwargs["workspace"] / "src" / "value.py"
                file.write_text("VALUE = 1\n")
            return Execution(0, json.dumps(self.transform(result)), "completed", 1)
        self.gate_runs += 1
        if self.mode == "infra":
            return Execution(125, "Docker unavailable", "completed", 1)
        if self.mode == "zero":
            return Execution(0, "Ran 0 tests\nOK", "completed", 1)
        if self.mode == "fail_once" and self.gate_runs == 1:
            return Execution(1, "Ran 2 tests\nFAILED", "completed", 1)
        if self.mode == "capture":
            records = kwargs["workspace"] / "records" / "runs"
            records.mkdir(parents=True, exist_ok=True)
            (records / "run-1.jsonl").write_text('{"scenario": "SC-01-01-01", "status": "PASS"}\n')
            (kwargs["workspace"] / "elsewhere.txt").write_text("not captured\n")
        if self.mode == "mutate_gate":
            (kwargs["workspace"] / "src" / "value.py").write_text("VALUE = 999\n")
        return Execution(0, "Ran 2 tests\nOK", "completed", 1)

    def cancel(self, name):
        self.stopped.append(name)

    def status(self, name):
        return self.live
