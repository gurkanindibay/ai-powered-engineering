#!/usr/bin/env python3
"""SitePulse Harness CLI: task DAG scheduler and verification loop.

Commands
  status                 Show the task DAG.
  next                   List tasks whose dependencies are complete.
  gates                  List the available gates and the commands they run.
  verify --task ID       Run the task's gates and acceptance tests (read-only).
         [--record]      Also write evidence and update the task status. Only
                         allowed in CI (CI=true) unless --allow-local-record.
         [--no-global]   Skip the global build gates (faster local iteration).
         [--json]        Print the machine-readable result.

Exit code: 0 when verification passed, 1 when it failed, 2 on usage errors.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(PROJECT_ROOT))
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

from harness.graph.task_dag import DagValidationError, TaskDag  # noqa: E402
from harness.loop.loop_runner import LoopRunner, git_state, write_evidence  # noqa: E402
from harness.loop.verification_gates import describe_gates  # noqa: E402

DAG_PATH = PROJECT_ROOT / ".specify" / "tasks" / "task-dag.json"
EVIDENCE_DIR = PROJECT_ROOT / ".specify" / "evidence"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="SitePulse Engineering Harness", formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("status", help="Show the current Task DAG status")
    sub.add_parser("next", help="List runnable tasks")
    sub.add_parser("gates", help="List available gates")
    v = sub.add_parser("verify", help="Run verification for one task")
    v.add_argument("--task", required=True, help="Task id, e.g. task-01")
    v.add_argument("--record", action="store_true", help="Write evidence and update the task status")
    v.add_argument("--allow-local-record", action="store_true", help="Permit --record outside CI")
    v.add_argument("--no-global", action="store_true", help="Skip global build gates")
    v.add_argument("--json", action="store_true", help="Print JSON")
    for p in sub.choices.values():
        p.add_argument("--dag", type=Path, default=DAG_PATH, help=argparse.SUPPRESS)
        p.add_argument("--evidence-dir", type=Path, default=EVIDENCE_DIR, help=argparse.SUPPRESS)
        p.add_argument("--root", type=Path, default=PROJECT_ROOT, help=argparse.SUPPRESS)
    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 2
    if args.command == "gates":
        for name, cmd in describe_gates().items():
            print(f"  {name:18} {cmd}")
        return 0

    try:
        dag = TaskDag(args.dag)
    except (OSError, DagValidationError) as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2

    if args.command == "status":
        print(dag.render_ascii())
        return 0
    if args.command == "next":
        runnable = dag.get_runnable_tasks()
        if not runnable:
            print("No runnable tasks (all completed or blocked by dependencies).")
        for t in runnable:
            print(f"  ⚡ {t['id']}: {t['name']} (Spec: {t.get('spec_ref')}, status {t['status']})")
        return 0

    task_id = args.task
    if task_id not in dag.tasks:
        print(f"Error: Unknown task {task_id}", file=sys.stderr)
        return 2
    task = dag.tasks[task_id]

    if args.record:
        if os.environ.get("CI") != "true" and not args.allow_local_record:
            print("Error: --record changes task status and is reserved for CI (set CI=true or pass --allow-local-record).", file=sys.stderr)
            return 2
        blocked_by = dag.incomplete_dependencies(task_id)
        if blocked_by:
            print(f"Error: {task_id} cannot be recorded before its dependencies complete: {', '.join(blocked_by)}", file=sys.stderr)
            return 2
        if task.get("status") == "BLOCKED":
            print(f"Error: {task_id} is BLOCKED (retry budget exhausted); a human must reset it.", file=sys.stderr)
            return 2
        dag.update_task(task_id, status="IN_PROGRESS")
        # Gates run below see a DAG that recording is changing: tell them (see RtmValidator).
        os.environ["SITEPULSE_RECORDING"] = "1"

    runner = LoopRunner(max_budget=int(task.get("max_attempts", 3)), include_global=not args.no_global)
    if not args.json:
        print(f"Running verification for [{task_id}] {task['name']}...")
    result = runner.run_task_gates(task, args.root)

    if args.record:
        attempts = 0 if result["passed"] else int(task.get("attempts", 0)) + 1
        status = runner.next_status(result["passed"], attempts)
        evidence = write_evidence(args.evidence_dir, result, git_state(args.root), attempts)
        try:
            evidence_ref = str(evidence.resolve().relative_to(Path(args.root).resolve()))
        except ValueError:
            evidence_ref = str(evidence.resolve())
        dag.update_task(task_id, status=status, attempts=attempts, evidence=evidence_ref)
        result["recorded_status"] = status

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    elif result["passed"]:
        print(f"[✔] PASSED: {result['gates_evaluated']} gate(s)/test(s) satisfied.")
    else:
        print(f"[❌] FAILED:")
        for d in result["diagnostics"]:
            print(f"    {d}")
    if args.record and not args.json:
        print(f"    Recorded status: {result['recorded_status']}")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
