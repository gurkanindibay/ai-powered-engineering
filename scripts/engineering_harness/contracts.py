"""Versioned worker boundaries, configuration validation and safe serialization."""
from __future__ import annotations

import hashlib
import json
from pathlib import PurePosixPath
import re
from typing import Any

from .routing import HarnessError, ROLES, money, positive_int


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def safe_path(value: Any) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise HarnessError("Paths must be nonempty relative POSIX paths")
    path = PurePosixPath(value)
    if path.is_absolute() or any(p in (".", "..", ".git") for p in value.split("/")) or ":" in value or "," in value:
        raise HarnessError(f"Unsafe relative path: {value}")
    return path.as_posix().rstrip("/")


def under(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + "/")


def redact(text: str, secrets: tuple[str, ...] = ()) -> str:
    for secret in sorted((s for s in secrets if s), key=len, reverse=True):
        text = text.replace(secret, "[REDACTED]")
    text = re.sub(r"(?i)((?:api[_-]?key|authorization|password|token|secret)\s*[:=]\s*)[^\s,;\"}]+", r"\1[REDACTED]", text)
    return text


def validate_policy(value: dict) -> dict:
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise HarnessError("Policy requires schema_version=1")
    required = {"schema_version", "image", "bridge", "network", "limits", "role_paths", "protected_paths", "gates", "acceptance", "preferences"}
    if set(value) != required:
        raise HarnessError(f"Policy fields must be {sorted(required)}")
    image = value["image"]
    if not isinstance(image, str) or not re.fullmatch(r"(?:[^\s,]+@)?sha256:[0-9a-f]{64}", image):
        raise HarnessError("Container image must be pinned by sha256 digest")
    if not isinstance(value["bridge"], list) or not value["bridge"] or any(not isinstance(s, str) or not s or "\x00" in s for s in value["bridge"]):
        raise HarnessError("Bridge must be a nonempty argv list")
    if not isinstance(value["network"], str) or (value["network"] != "none" and not re.fullmatch(r"harness-egress-[a-z0-9-]+", value["network"])):
        raise HarnessError("Network must be none or a separately administered harness-egress-* proxy network")
    limits = value["limits"]
    expected = {"tokens", "cost", "seconds", "attempt_seconds", "attempt_tokens", "max_repairs", "memory_mb", "cpus", "pids", "output_bytes"}
    if not isinstance(limits, dict) or set(limits) != expected:
        raise HarnessError(f"Limits must contain {sorted(expected)}")
    for name in expected - {"cost", "max_repairs"}:
        positive_int(limits[name], name)
    if type(limits["max_repairs"]) is not int or not 0 <= limits["max_repairs"] <= 10:
        raise HarnessError("max_repairs must be between zero and ten")
    if money(limits["cost"]) <= 0:
        raise HarnessError("Cost budget must be positive")
    if not isinstance(value["role_paths"], dict) or set(value["role_paths"]) != set(ROLES):
        raise HarnessError("Specify writable paths for every role (empty list for read-only roles)")
    for paths in [*value["role_paths"].values(), value["protected_paths"]]:
        if not isinstance(paths, list):
            raise HarnessError("Path policies must be lists")
        for path in paths:
            safe_path(path)
    if not isinstance(value["preferences"], dict) or any(k not in ROLES for k in value["preferences"]):
        raise HarnessError("Invalid role preferences")
    if not isinstance(value["gates"], list) or not value["gates"]:
        raise HarnessError("At least one trusted verification gate is required")
    gate_ids = set()
    for gate in value["gates"]:
        if not isinstance(gate, dict) or set(gate) - {"id", "argv", "cwd", "timeout", "test_pattern", "repair_role", "captures"} or not {"id", "argv", "cwd", "timeout", "test_pattern"} <= set(gate):
            raise HarnessError("Gate requires id, argv, cwd, timeout and test_pattern")
        if not isinstance(gate["id"], str) or not re.fullmatch(r"[a-z0-9-]+", gate["id"]) or gate["id"] in gate_ids:
            raise HarnessError("Gate ids must be unique lowercase identifiers")
        if gate.get("repair_role") is not None and gate["repair_role"] not in ("developer", "backend_developer", "frontend_developer"):
            raise HarnessError("Invalid gate repair_role")
        gate_ids.add(gate["id"])
        # Directories whose new files (e.g. test run records) the controller preserves in evidence.
        if not isinstance(gate.get("captures", []), list):
            raise HarnessError("Gate captures must be a list of paths")
        for path in gate.get("captures", []):
            safe_path(path)
        if not isinstance(gate["argv"], list) or not gate["argv"] or any(not isinstance(a, str) or not a for a in gate["argv"]):
            raise HarnessError("Gate command must be an argv list")
        if gate["cwd"] != ".":
            safe_path(gate["cwd"])
        positive_int(gate["timeout"], "gate timeout")
        if gate["test_pattern"] is not None:
            if not isinstance(gate["test_pattern"], str):
                raise HarnessError("test_pattern must be a regular expression or null")
            try:
                pattern = re.compile(gate["test_pattern"])
            except re.error as exc:
                raise HarnessError("Invalid test-count pattern") from exc
            if "count" not in pattern.groupindex:
                raise HarnessError("Test pattern must have a named count group")
    if not isinstance(value["acceptance"], dict) or not value["acceptance"]:
        raise HarnessError("Map every acceptance criterion to required gate ids")
    for criterion, ids in value["acceptance"].items():
        if not isinstance(criterion, str) or not criterion.strip() or not isinstance(ids, list) or not ids or any(not isinstance(i, str) or i not in gate_ids for i in ids):
            raise HarnessError("Acceptance references unknown or empty gates")
    if not any(g["test_pattern"] for g in value["gates"]):
        raise HarnessError("At least one gate must prove a positive executed test count")
    return value


ROLE_ARTIFACTS = {
    "coordinator": ("work_plan", "coordination_risks"),
    "product_owner": ("scope", "acceptance_criteria", "exclusions"),
    "business_analyst": ("domain_rules", "contracts", "edge_cases"),
    "architect": ("design", "risks"),
    "tester": ("criteria", "verdict", "residual_risks"),
}
DEVELOPER_ARTIFACTS = ("changes", "tests")
ARTIFACT_TYPES = {
    "work_plan": list, "coordination_risks": list,
    "scope": str, "acceptance_criteria": list, "exclusions": list, "domain_rules": list,
    "contracts": dict, "edge_cases": list, "design": str, "risks": list, "criteria": dict,
    "verdict": str, "residual_risks": list, "changes": list, "tests": list,
}


def role_artifacts(role: str) -> tuple[str, ...]:
    """Artifact names a completed result for this role must provide."""
    return ROLE_ARTIFACTS.get(role, DEVELOPER_ARTIFACTS)


def validate_result(result: dict, envelope: dict) -> dict:
    required = {"schema_version", "run_id", "task_id", "attempt_id", "input_hash", "candidate", "status", "summary", "artifacts", "issues", "usage"}
    if not isinstance(result, dict) or set(result) != required or result["schema_version"] != 1:
        raise HarnessError("Worker result does not match result schema v1")
    for key in ("run_id", "task_id", "attempt_id", "candidate"):
        if result[key] != envelope[key]:
            raise HarnessError(f"Worker result has stale or mismatched {key}")
    if result["input_hash"] != digest(envelope):
        raise HarnessError("Worker result references a different input envelope")
    if result["status"] not in ("completed", "code_defect", "blocked", "infrastructure_error"):
        raise HarnessError("Unknown worker result status")
    if not isinstance(result["summary"], str) or not result["summary"].strip():
        raise HarnessError("Worker result requires a summary")
    if not isinstance(result["issues"], list) or any(not isinstance(i, str) for i in result["issues"]):
        raise HarnessError("Worker issues must be strings")
    if not isinstance(result["artifacts"], dict):
        raise HarnessError("Worker artifacts must be an object")
    role = envelope["role"]
    fields = set(role_artifacts(role))
    if result["status"] == "completed":
        if result["issues"] or not fields <= set(result["artifacts"]):
            raise HarnessError("Completed result has unresolved issues or missing role artifacts")
        if any(not result["artifacts"][field] for field in fields - {"exclusions", "residual_risks", "risks"}):
            raise HarnessError("Required role artifacts must not be empty")
        types = ARTIFACT_TYPES
        for field in fields:
            artifact = result["artifacts"][field]
            if not isinstance(artifact, types[field]) or (isinstance(artifact, list) and any(not isinstance(v, str) for v in artifact)):
                raise HarnessError(f"Invalid role artifact type: {field}")
        if role == "product_owner" and set(result["artifacts"]["acceptance_criteria"]) != set(envelope["acceptance"]):
            raise HarnessError("Product owner changed the operator's accepted criteria; revise policy explicitly")
        if role == "tester":
            if result["artifacts"]["verdict"] != "pass" or not isinstance(result["artifacts"]["criteria"], dict):
                raise HarnessError("Tester must supply per-criterion decisions and a pass verdict")
            if set(result["artifacts"]["criteria"]) != set(envelope["acceptance"]) or any(v != "pass" for v in result["artifacts"]["criteria"].values()):
                raise HarnessError("Tester did not pass every acceptance criterion")
    usage = result["usage"]
    if not isinstance(usage, dict) or set(usage) != {"input_tokens", "output_tokens"}:
        raise HarnessError("Usage requires input_tokens and output_tokens")
    if any(type(v) is not int or v < 0 for v in usage.values()):
        raise HarnessError("Usage tokens must be nonnegative integers")
    return result
