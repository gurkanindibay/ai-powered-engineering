#!/usr/bin/env python3
"""Compatibility planner for the durable development harness; never dispatches agents."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

if __package__:
    from .engineering_harness.routing import HarnessError, ROLES, TIERS, assess, plan
else:
    from engineering_harness.routing import HarnessError, ROLES, TIERS, assess, plan


def assess_complexity(task_description, files_count=None, touches_financial=False, touches_schema=False, touches_auth=False):
    return assess(task_description, files_count, financial=touches_financial, schema=touches_schema, auth=touches_auth).tier


def build_iteration_pipeline(task, complexity=None, files_count=None, touches_financial=False,
                             touches_schema=False, touches_auth=False, roles=None, capabilities=None, scope="fullstack"):
    return plan(task, requested=complexity, files_count=files_count, financial=touches_financial,
                schema=touches_schema, auth=touches_auth, roles=roles, capabilities=capabilities, scope=scope)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", required=True)
    parser.add_argument("--complexity", choices=TIERS, help="Requested tier; cannot lower assessed risk")
    parser.add_argument("--files", type=int)
    parser.add_argument("--financial", action="store_true")
    parser.add_argument("--schema", action="store_true")
    parser.add_argument("--auth", action="store_true")
    parser.add_argument("--roles", nargs="+", choices=ROLES)
    parser.add_argument("--scope", choices=("fullstack", "backend", "frontend", "mechanical"), default="fullstack")
    parser.add_argument("--capabilities", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        capabilities = json.loads(args.capabilities.read_text()) if args.capabilities else None
        pipeline = build_iteration_pipeline(args.task, args.complexity, args.files, args.financial,
                                            args.schema, args.auth, args.roles, capabilities, args.scope)
    except (HarnessError, OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(pipeline, indent=2))
    else:
        print(f"Complexity: {pipeline['complexity'].upper()}")
        for reason in pipeline["assessment"]["reasons"]:
            print(f"  {reason}")
        for stage in pipeline["stages"]:
            target = stage["target"]
            print(f"{stage['id']} {stage['role']}: " + (f"{target['provider']}/{target['model']}" if target else "unresolved (capabilities required)"))
        print("Planning only. Use development_harness.py to execute with a trusted sandbox policy.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
