"""Command-line API for planning, execution, evidence and evaluation."""
from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
import sys

from .contracts import canonical, validate_policy
from .engine import Engine
from .evaluation import evaluate
from .routing import HarnessError, ROLES, TIERS, plan
from .store import Store, TERMINAL


def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise HarnessError(f"Unable to read JSON: {path}") from exc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Policy-controlled software development harness (no host execution fallback)")
    parser.add_argument("--state", type=Path, default=Path(".engineering-harness"), help="Private run database, snapshots and evidence directory")
    parser.add_argument("--json", action="store_true", help="Machine-readable JSON")
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("plan", "create"):
        p = sub.add_parser(command)
        p.add_argument("--task", required=True)
        p.add_argument("--complexity", choices=TIERS)
        p.add_argument("--files", type=int)
        p.add_argument("--financial", action="store_true")
        p.add_argument("--schema", action="store_true")
        p.add_argument("--auth", action="store_true")
        p.add_argument("--roles", nargs="+", choices=ROLES)
        p.add_argument("--scope", choices=("fullstack", "backend", "frontend", "mechanical"), default="fullstack")
        p.add_argument("--capabilities", type=Path, help="Offline capabilities snapshot; execution always revalidates live capabilities")
        if command == "create":
            p.add_argument("--policy", type=Path, required=True, help="Trusted operator policy outside worker control")
            p.add_argument("--repository", type=Path, default=Path.cwd())
            p.add_argument("--revision", default="HEAD", help="Committed source revision; dirty local edits are never included implicitly")
    for command in ("status", "step", "run", "cancel", "recover", "events", "audit"):
        p = sub.add_parser(command)
        p.add_argument("run_id")
    p = sub.add_parser("evaluate")
    p.add_argument("--cases", type=Path, required=True)
    p.add_argument("--measurements", type=Path, help="Paired baseline/routed evaluation results")
    p = sub.add_parser("validate-policy")
    p.add_argument("policy", type=Path)
    p = sub.add_parser("sitepulse-policy")
    p.add_argument("--image", required=True, help="Digest-pinned prepared toolchain/bridge image")
    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    store = None
    try:
        if args.command in ("plan", "create"):
            options = dict(files_count=args.files, financial=args.financial, schema=args.schema,
                           auth=args.auth, requested=args.complexity, roles=args.roles, scope=args.scope,
                           capabilities=read_json(args.capabilities) if args.capabilities else None)
            if args.command == "plan":
                value = plan(args.task, **options)
            else:
                policy = validate_policy(read_json(args.policy))
                store = Store(args.state)
                run_id = Engine(store).create(args.repository, args.task, policy, revision=args.revision, **options)
                value = {"run_id": run_id, "status": "QUEUED", "candidate": store.run(run_id)["candidate"],
                         "source_revision": store.run(run_id)["source_revision"]}
        elif args.command == "evaluate":
            value = evaluate(read_json(args.cases), read_json(args.measurements) if args.measurements else None)
        elif args.command == "validate-policy":
            validate_policy(read_json(args.policy))
            value = {"valid": True}
        elif args.command == "sitepulse-policy":
            from .sitepulse import policy_for_sitepulse
            value = policy_for_sitepulse(args.image)
        else:
            store = Store(args.state)
            engine = Engine(store)
            if args.command == "status":
                run = store.run(args.run_id)
                value = {key: run[key] for key in ("id", "status", "revision", "source_revision", "candidate", "cost", "tokens", "deadline")}
                value["tasks"] = [{k: t[k] for k in ("id", "role", "status", "repairs")} for t in store.tasks(args.run_id)]
            elif args.command in ("run", "step"):
                status = engine.step(args.run_id)
                if args.command == "run":
                    while status not in TERMINAL:
                        status = engine.step(args.run_id)
                value = {"run_id": args.run_id, "status": status}
            elif args.command in ("cancel", "recover"):
                value = {"run_id": args.run_id, "status": getattr(engine, args.command)(args.run_id)}
            elif args.command == "events":
                value = [{**e, "body": json.loads(e["body"])} for e in store.events(args.run_id)]
            else:
                value = {"run_id": args.run_id, "valid": store.audit(args.run_id)}
        if args.json or isinstance(value, (dict, list)):
            print(json.dumps(value, indent=2))
        else:
            print(value)
        if isinstance(value, dict) and (value.get("status") in {"BLOCKED", "FAILED", "TIMED_OUT", "CANCELLED"} or value.get("valid") is False or value.get("under_classified", 0) > 0 or ("matched" in value and value["matched"] != value["sample_size"])):
            return 1
        return 0
    except (HarnessError, OSError, sqlite3.Error) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    finally:
        if store is not None:
            store.close()
