#!/usr/bin/env python3
"""Bidirectional Requirements Traceability Matrix (RTM) Validator.

Validates forward and backward traceability across:
- docs/engineering-process/cmmi-pipeline/traceability-matrix.md (RTM Table)
- apps/development-time/SitePulse/.specify/tasks/task-dag.json
- Implementation source files and test suites on disk.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


ACCEPTANCE_REF = re.compile(r"`((?:rust|flutter|system|scenario):[^`]+)`")


class RtmValidator:
    """A requirement is VERIFIED only with evidence: its task is COMPLETED, and
    `.specify/evidence/<task>.json` records a passing run on the current commit
    in which every acceptance test named in the RTM row passed."""

    def __init__(self, workspace_root: Optional[Path] = None, allow_stale_evidence: bool = False):
        self.allow_stale_evidence = allow_stale_evidence
        if workspace_root is None:
            # SCRIPT_DIR is .../apps/development-time/SitePulse/harness
            script_dir = Path(__file__).resolve().parent
            self.workspace_root = script_dir.parents[3]
        else:
            self.workspace_root = workspace_root

        self.rtm_file = (
            self.workspace_root / "apps" / "development-time" / "SitePulse" / "docs"
            / "engineering-process" / "cmmi-pipeline" / "traceability-matrix.md"
        )
        self.dag_file = (
            self.workspace_root
            / "apps"
            / "development-time"
            / "SitePulse"
            / ".specify"
            / "tasks"
            / "task-dag.json"
        )
        self.evidence_dir = self.dag_file.parent.parent / "evidence"

    def parse_rtm_table(self) -> List[Dict[str, str]]:
        """Parses rows from the markdown table in traceability-matrix.md."""
        if not self.rtm_file.exists():
            raise FileNotFoundError(f"RTM document not found: {self.rtm_file}")

        content = self.rtm_file.read_text(encoding="utf-8")
        rows = []

        # Matches rows like: | **REQ-001** | ... | `task-01` | `path` | ... | **VERIFIED** |
        for line in content.splitlines():
            line_str = line.strip()
            if line_str.startswith("|") and "**REQ-" in line_str:
                cols = [c.strip() for c in line_str.split("|")[1:-1]]
                if len(cols) >= 9:
                    req_id = re.sub(r"[\*`]", "", cols[0]).strip()
                    intent = cols[1].strip()
                    spec_ref = re.sub(r"[`]", "", cols[2]).strip()
                    arch_ref = cols[3].strip()
                    task_id = re.sub(r"[`]", "", cols[4]).strip()
                    artifacts_raw = cols[5].strip()
                    verification_tests = cols[6].strip()
                    validation_criteria = cols[7].strip()
                    status = re.sub(r"[\*`]", "", cols[8]).strip()

                    # Extract file paths from artifact column
                    artifact_paths = [
                        p.strip("`")
                        for p in re.findall(r"`([^`]+)`", artifacts_raw)
                    ]

                    rows.append({
                        "req_id": req_id,
                        "intent": intent,
                        "spec_ref": spec_ref,
                        "arch_ref": arch_ref,
                        "task_id": task_id,
                        "artifact_paths": artifact_paths,
                        "verification_tests": verification_tests,
                        "validation_criteria": validation_criteria,
                        "status": status,
                    })

        return rows

    def _current_commit(self) -> Optional[str]:
        try:
            return subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.workspace_root, capture_output=True,
                                  text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return None

    def _evidence_issues(self, req_id: str, task_id: str, named_tests: List[str]) -> List[str]:
        if not named_tests:
            return [f"[{req_id}] VERIFIED but names no acceptance tests (rust:/flutter:/system:/scenario: ids)"]
        path = self.evidence_dir / f"{task_id}.json"
        try:
            evidence = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return [f"[{req_id}] VERIFIED but evidence file is missing or unreadable: {path.name}"]
        issues: List[str] = []
        if not evidence.get("passed"):
            issues.append(f"[{req_id}] VERIFIED but the latest evidence run failed")
        if not self.allow_stale_evidence:
            head = self._current_commit()
            if head is None or evidence.get("commit") != head:
                issues.append(f"[{req_id}] evidence is from commit {evidence.get('commit')}, not the current HEAD {head}")
            if evidence.get("dirty"):
                issues.append(f"[{req_id}] evidence was recorded on a dirty working tree")
        passed = {t["id"] for t in evidence.get("acceptance_tests", []) if t.get("passed")}
        for test in named_tests:
            if test not in passed:
                issues.append(f"[{req_id}] named test {test} did not pass in the evidence")
        return issues

    def load_task_dag(self) -> Dict[str, Any]:
        if not self.dag_file.exists():
            raise FileNotFoundError(f"Task DAG not found: {self.dag_file}")

        with open(self.dag_file, "r", encoding="utf-8") as f:
            data = json.load(f)

        tasks = {}
        for t in data.get("tasks", []):
            tasks[t["id"]] = t
        return tasks

    def validate(self) -> Dict[str, Any]:
        """Performs full bidirectional cross-reference validation."""
        rtm_rows = self.parse_rtm_table()
        dag_tasks = self.load_task_dag()

        issues: List[str] = []
        # `harness_cli verify --record` completes tasks one by one in CI while the committed RTM
        # still says UNVERIFIED; that lag is expected during a recording run, not a defect.
        recording = os.environ.get("SITEPULSE_RECORDING") == "1"
        verified_count = 0
        pending_count = 0

        for row in rtm_rows:
            req_id = row["req_id"]
            task_id = row["task_id"]
            status = row["status"]

            # 1. Forward Traceability: Check Task DAG existence
            if task_id not in dag_tasks:
                issues.append(f"[{req_id}] Referenced task_id '{task_id}' does not exist in task-dag.json")
            else:
                dag_status = dag_tasks[task_id].get("status")
                # Cross-check status alignment
                if status == "VERIFIED" and dag_status != "COMPLETED":
                    issues.append(
                        f"[{req_id}] Status mismatch: RTM is 'VERIFIED' but task-dag.json is '{dag_status}'"
                    )
                elif (status in ("PENDING", "UNVERIFIED") and dag_status == "COMPLETED"
                      and not recording):
                    issues.append(
                        f"[{req_id}] Status mismatch: RTM is '{status}' but task-dag.json is 'COMPLETED'"
                    )

            # 2. VERIFIED needs evidence, not just files on disk
            named_tests = ACCEPTANCE_REF.findall(row["verification_tests"])
            if status == "VERIFIED":
                issues.extend(self._evidence_issues(req_id, task_id, named_tests))
            if status == "VERIFIED":
                verified_count += 1
                for rel_path in row["artifact_paths"]:
                    full_path = self.workspace_root / rel_path
                    if not full_path.exists():
                        issues.append(
                            f"[{req_id}] Missing implementation artifact on disk: {rel_path}"
                        )
            else:
                pending_count += 1

            # 3. Verification gate and validation criteria presence
            if not row["verification_tests"]:
                issues.append(f"[{req_id}] Missing verification test definitions")
            if not row["validation_criteria"]:
                issues.append(f"[{req_id}] Missing validation acceptance criteria")

        # 4. Backward Traceability: Check if all completed DAG tasks have an RTM entry
        rtm_task_ids = {r["task_id"] for r in rtm_rows}
        for t_id, task in dag_tasks.items():
            if t_id not in rtm_task_ids:
                issues.append(
                    f"Orphan Task detected: Task '{t_id}' ({task['name']}) has no corresponding RTM requirement"
                )

        passed = len(issues) == 0
        return {
            "passed": passed,
            "total_requirements": len(rtm_rows),
            "verified_requirements": verified_count,
            "pending_requirements": pending_count,
            "total_dag_tasks": len(dag_tasks),
            "issues": issues,
            "requirements": rtm_rows,
        }


def main():
    parser = argparse.ArgumentParser(description="A-CMMI Requirements Traceability Matrix Validator")
    parser.add_argument("--check", action="store_true", help="Run validation check")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--allow-stale-evidence", action="store_true", help="Accept evidence from other commits or dirty trees")

    args = parser.parse_args()
    validator = RtmValidator(allow_stale_evidence=args.allow_stale_evidence)

    try:
        report = validator.validate()
    except Exception as e:
        print(f"Validation Error: {e}", file=sys.stderr)
        sys.exit(2)

    if args.json:
        print(json.dumps(report, indent=2))
        sys.exit(0 if report["passed"] else 1)

    print("=" * 70)
    print("  A-CMMI BIDIRECTIONAL REQUIREMENTS TRACEABILITY VALIDATION REPORT")
    print("=" * 70)
    print(f"Total Requirements Traced: {report['total_requirements']}")
    print(f"  - Verified Requirements: {report['verified_requirements']}")
    print(f"  - Pending Requirements:  {report['pending_requirements']}")
    print(f"Total Task DAG Nodes:      {report['total_dag_tasks']}")
    print("-" * 70)

    if report["passed"]:
        print("[✔] TRACEABILITY CHECK PASSED!")
        print("    Forward/backward links are complete and every VERIFIED requirement")
        print("    is backed by passing evidence from the current commit.")
        sys.exit(0)
    else:
        print(f"[❌] TRACEABILITY CHECK FAILED with {len(report['issues'])} issue(s):")
        for issue in report["issues"]:
            print(f"    - {issue}")
        sys.exit(1)


if __name__ == "__main__":
    main()
