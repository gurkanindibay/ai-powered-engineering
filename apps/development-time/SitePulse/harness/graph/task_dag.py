"""Task DAG engine: loads, validates and updates ``.specify/tasks/task-dag.json``.

Validation (the rules of ``task-dag.schema.json``) runs on load: unknown
dependency ids, unknown gates, malformed acceptance test ids, duplicate ids and
cycles are errors, not silent blockers. Writes are atomic (temp file + rename)
and keep every top-level key of the document.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Set

STATUSES = ("UNVERIFIED", "PENDING", "IN_PROGRESS", "FAILED", "BLOCKED", "COMPLETED")
REQUIRED_TASK_FIELDS = {"id": str, "name": str, "module": str, "status": str, "depends_on": list, "spec_ref": str}


class DagValidationError(ValueError):
    """Raised when task-dag.json violates the schema."""


class TaskDag:
    def __init__(self, dag_file: Path):
        self.dag_file = Path(dag_file)
        self.document: Dict[str, Any] = {}
        self.tasks: Dict[str, Dict[str, Any]] = {}
        self.dependencies: Dict[str, List[str]] = {}
        self._load()

    # -- loading & validation -------------------------------------------------

    def _load(self) -> None:
        with open(self.dag_file, "r", encoding="utf-8") as f:
            self.document = json.load(f)
        errors = validate_document(self.document)
        if errors:
            raise DagValidationError("task-dag.json is invalid:\n  - " + "\n  - ".join(errors))
        for task in self.document["tasks"]:
            self.tasks[task["id"]] = task
            self.dependencies[task["id"]] = list(task.get("depends_on", []))

    # -- queries --------------------------------------------------------------

    def incomplete_dependencies(self, task_id: str) -> List[str]:
        return [d for d in self.dependencies.get(task_id, []) if self.tasks[d].get("status") != "COMPLETED"]

    def get_runnable_tasks(self) -> List[Dict[str, Any]]:
        """Tasks not yet completed whose dependencies are all COMPLETED."""
        return [
            t
            for tid, t in self.tasks.items()
            if t.get("status") in ("UNVERIFIED", "PENDING", "FAILED") and not self.incomplete_dependencies(tid)
        ]

    # -- updates --------------------------------------------------------------

    def update_task(self, task_id: str, **fields: Any) -> None:
        if task_id not in self.tasks:
            raise KeyError(f"Task {task_id} not found")
        if "status" in fields and fields["status"] not in STATUSES:
            raise ValueError(f"Invalid status {fields['status']!r}; expected one of {STATUSES}")
        self.tasks[task_id].update(fields)
        self.save()

    def update_task_status(self, task_id: str, new_status: str) -> None:
        self.update_task(task_id, status=new_status)

    def save(self) -> None:
        """Atomically rewrites the DAG, preserving all top-level keys."""
        doc = dict(self.document)
        doc["tasks"] = list(self.tasks.values())
        fd, tmp = tempfile.mkstemp(dir=self.dag_file.parent, prefix=".task-dag.", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=2, ensure_ascii=False)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.dag_file)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        self.document = doc

    # -- rendering ------------------------------------------------------------

    def render_ascii(self) -> str:
        icons = {
            "COMPLETED": "[✔] VERIFIED",
            "IN_PROGRESS": "[⚡] IN LOOP",
            "PENDING": "[⏳] PENDING",
            "UNVERIFIED": "[?] UNVERIFIED",
            "FAILED": "[✘] FAILED",
            "BLOCKED": "[⛔] BLOCKED",
        }
        lines = ["=== SitePulse Harness Task DAG ==="]
        for task_id, task in self.tasks.items():
            deps = ", ".join(task.get("depends_on", [])) or "None (Root)"
            lines.append(f"  {task_id} {icons.get(task.get('status', ''), '[?]').ljust(15)} : {task['name']}")
            lines.append(f"       └─ Module: {task.get('module')} | Prereqs: [{deps}] | Gates: {', '.join(task.get('gates', [])) or '-'}")
        return "\n".join(lines)


def validate_document(doc: Any) -> List[str]:
    """Returns all schema violations of a task DAG document (empty when valid)."""
    from harness.loop.verification_gates import is_valid_acceptance_id, known_gate

    errors: List[str] = []
    if not isinstance(doc, dict) or not isinstance(doc.get("tasks"), list):
        return ["document must be an object with a 'tasks' array"]
    ids: List[str] = []
    for i, task in enumerate(doc["tasks"]):
        where = f"tasks[{i}]"
        if not isinstance(task, dict):
            errors.append(f"{where} must be an object")
            continue
        for key, typ in REQUIRED_TASK_FIELDS.items():
            if not isinstance(task.get(key), typ):
                errors.append(f"{where}.{key} is required and must be a {typ.__name__}")
        tid = task.get("id", where)
        ids.append(tid)
        if task.get("status") not in STATUSES:
            errors.append(f"{tid}: status {task.get('status')!r} is not one of {STATUSES}")
        for g in task.get("gates", []) or []:
            if not known_gate(g):
                errors.append(f"{tid}: unknown gate {g!r}")
        for t in task.get("acceptance_tests", []) or []:
            if not is_valid_acceptance_id(t):
                errors.append(f"{tid}: malformed acceptance test id {t!r}")
        if not task.get("gates") and not task.get("acceptance_tests"):
            errors.append(f"{tid}: declares neither gates nor acceptance_tests, so it can never be verified")
    dupes = {x for x in ids if ids.count(x) > 1}
    for d in sorted(dupes):
        errors.append(f"duplicate task id {d!r}")
    known = set(ids)
    for task in doc["tasks"]:
        for dep in task.get("depends_on", []) or []:
            if dep not in known:
                errors.append(f"{task.get('id')}: depends on unknown task {dep!r}")
    if not errors:
        errors.extend(_cycle_errors({t["id"]: t.get("depends_on", []) for t in doc["tasks"]}))
    return errors


def _cycle_errors(deps: Dict[str, List[str]]) -> List[str]:
    visited: Set[str] = set()
    stack: Set[str] = set()
    errors: List[str] = []

    def dfs(node: str) -> None:
        visited.add(node)
        stack.add(node)
        for n in deps.get(node, []):
            if n in stack:
                errors.append(f"cycle detected involving task {n!r}")
            elif n not in visited:
                dfs(n)
        stack.discard(node)

    for node in deps:
        if node not in visited:
            dfs(node)
    return errors
