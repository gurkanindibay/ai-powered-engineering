"""Command-line API for planning, execution, evidence and evaluation."""
from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
import sys

from . import t3
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
        p.add_argument("--t3-catalog", type=Path, help="Saved T3 orchestrator_capabilities result; routes stages to T3 child-agent models")
        p.add_argument("--t3-registry", type=Path, default=t3.DEFAULT_REGISTRY, help="Operator T3 role/tier model registry")
        if command == "create":
            p.add_argument("--policy", type=Path, required=True, help="Trusted operator policy outside worker control")
            p.add_argument("--repository", type=Path, default=Path.cwd())
            p.add_argument("--revision", default="HEAD", help="Committed source revision; dirty local edits are never included implicitly")
    for command in ("status", "step", "run", "cancel", "recover", "events", "audit"):
        p = sub.add_parser(command)
        p.add_argument("run_id")
    p = sub.add_parser("captures", help="List (or with --output, write) the files gates captured in the latest verification, e.g. test run records")
    p.add_argument("run_id")
    p.add_argument("--output", type=Path, help="Directory (repository root) to write the captured files into; existing files are never overwritten")
    p = sub.add_parser("t3-dispatch", help="Claim the next stage and print its T3 delegate_task payload (or run gates when none remain)")
    p.add_argument("run_id")
    p.add_argument("--catalog", type=Path, required=True, help="Fresh T3 orchestrator_capabilities result")
    p.add_argument("--registry", type=Path, default=t3.DEFAULT_REGISTRY)
    p = sub.add_parser("t3-submit", help="Record a T3 child's final message for a claimed attempt")
    p.add_argument("run_id")
    p.add_argument("attempt_id")
    p.add_argument("--output", type=Path, required=True, help="File with the child's final message; - reads stdin")
    p = sub.add_parser("t3-heartbeat", help="Extend the lease of a long-running T3 child")
    p.add_argument("run_id")
    p.add_argument("attempt_id")
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
            if args.capabilities and args.t3_catalog:
                raise HarnessError("Use either --capabilities or --t3-catalog")
            capabilities = read_json(args.capabilities) if args.capabilities else None
            if args.t3_catalog:
                capabilities = t3.capabilities_from_catalog(read_json(args.t3_registry), read_json(args.t3_catalog))
            options = dict(files_count=args.files, financial=args.financial, schema=args.schema,
                           auth=args.auth, requested=args.complexity, roles=args.roles, scope=args.scope,
                           capabilities=capabilities)
            if args.command == "plan":
                value = plan(args.task, **options)
                if args.t3_catalog:
                    for stage in value["stages"]:
                        target = t3.with_tier_options(stage["target"], value["complexity"])
                        stage["target"] = {"providerInstanceId": target["provider"], "model": target["model"],
                                           "options": target["selected_options"]}
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
            elif args.command == "captures":
                value = engine.captures(args.run_id, args.output)
            elif args.command == "t3-dispatch":
                capabilities = t3.capabilities_from_catalog(read_json(args.registry), read_json(args.catalog))
                value = engine.t3_dispatch(args.run_id, capabilities)
            elif args.command == "t3-submit":
                output = sys.stdin.read() if str(args.output) == "-" else args.output.read_text()
                value = {"run_id": args.run_id, "status": engine.t3_submit(args.run_id, args.attempt_id, output)}
            elif args.command == "t3-heartbeat":
                if store.attempt(args.attempt_id)["run_id"] != args.run_id:
                    raise HarnessError("Attempt does not belong to this run")
                store.heartbeat(args.attempt_id)
                value = {"run_id": args.run_id, "attempt_id": args.attempt_id, "heartbeat": True}
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
