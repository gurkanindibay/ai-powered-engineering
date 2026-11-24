#!/usr/bin/env python3
"""Deterministic Docker integration fixture. This is not a model/provider adapter."""
import hashlib
import json
from pathlib import Path
import sys

request = json.load(sys.stdin)
if request["action"] == "capabilities":
    result = {"schema_version": 1, "targets": [{"provider": "fixture", "model": "deterministic",
              "tiers": ["low", "medium", "high", "critical"], "roles": ["coordinator", "product_owner", "business_analyst", "architect", "backend_developer", "frontend_developer", "developer", "tester"],
              "options": {}, "max_tokens": 1000, "input_per_million": "0", "output_per_million": "0",
              "price_date": "2026-11-08", "benchmark_id": "fixture-only"}]}
else:
    if request["role"] == "coordinator":
        artifacts = {"work_plan": ["Implement accepted scope", "Integrate and verify"], "coordination_risks": []}
    elif request["role"] in ("developer", "backend_developer"):
        Path("src/value.py").write_text("VALUE = 1\n")
        artifacts = {"changes": ["src/value.py"], "tests": ["unit"]}
    elif request["role"] == "frontend_developer":
        Path("ui/view.txt").write_text("value: 1\n")
        artifacts = {"changes": ["ui/view.txt"], "tests": ["unit"]}
    elif request["role"] == "product_owner":
        artifacts = {"scope": "Bounded fixture", "acceptance_criteria": list(request["acceptance"]), "exclusions": []}
    elif request["role"] == "business_analyst":
        artifacts = {"domain_rules": ["Preserve value"], "contracts": {"v1": "value = 1"}, "edge_cases": ["Empty input"]}
    elif request["role"] == "architect":
        artifacts = {"design": "Bounded modules", "risks": []}
    else:
        artifacts = {"criteria": {c: "pass" for c in request["acceptance"]}, "verdict": "pass", "residual_risks": []}
    raw = json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    result = {"schema_version": 1, "run_id": request["run_id"], "task_id": request["task_id"],
              "attempt_id": request["attempt_id"], "candidate": request["candidate"],
              "input_hash": hashlib.sha256(raw.encode()).hexdigest(), "status": "completed",
              "summary": "Completed deterministic fixture", "artifacts": artifacts, "issues": [],
              "usage": {"input_tokens": 10, "output_tokens": 5}}
print(json.dumps(result))
