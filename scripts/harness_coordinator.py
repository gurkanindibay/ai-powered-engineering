#!/usr/bin/env python3
"""0-token coordinator daemon for reviewer-coordinated auto-handover (Phase 4).

Routine handovers are machine work: validate the checkpoint, transfer the claim,
pick the next healthy qualified provider and dispatch it. None of that needs an
LLM, so this CLI does it deterministically and only *escalates to* the reviewer
when a human decision is actually needed.

Commands
    heartbeat     record/refresh this session's lease (.agents/local/sessions/)
    status        snapshot of leases, pending handovers, escalations and provider health
    handover      capture (or reuse) a checkpoint, transfer the claim and dispatch
    recover       Layer-3 watchdog: snapshot expired/dirty workers, never delete work
    provider-failed  mark a provider THROTTLED/EXHAUSTED after a hard 429
    serve         the daemon loop: watchdog pass, then dispatch pending checkpoints
    simulate      evaluate the shipped synthetic 429/context/thrash scenarios

A dispatch is one of three transports:
    t3       queue a t3-dispatch payload (needs task_cancel of the outgoing child first)
    cli      spawn a headless CLI in a fresh worktree, wrapped by handover capture
    pickup   write a ready-to-paste brief for an interactive IDE/Desktop session

Nothing is spawned with ``--dry-run``; the plan is still written to stdout in
``--json`` form. Every live action is also recorded under
``.agents/local/coordinator/`` so a later run can see what already happened.

Usage:
    python3 scripts/harness_coordinator.py heartbeat --harness t3 --session "$AGENT_SESSION_ID" \\
        --model deepseek-flash --issue 549 --worktree "$PWD"
    python3 scripts/harness_coordinator.py status --json
    python3 scripts/harness_coordinator.py handover --issue 549 --reason context_ceiling \\
        --from-harness t3 --from-session ses_abc --from-provider claudeAgent --dry-run
    python3 scripts/harness_coordinator.py recover --dry-run --t3-db .agents/local/runs.sqlite3
    python3 scripts/harness_coordinator.py serve --once --json
    python3 scripts/harness_coordinator.py simulate --cases config/engineering-harness/coordinator-scenarios.json

Exit codes: 0 done, 1 parked/escalated (a reviewer or operator decision is due),
2 usage or configuration error.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.engineering_harness import coordinator, leases  # noqa: E402
from scripts.engineering_harness.routing import HarnessError  # noqa: E402


def local_root(explicit: str | None = None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    return leases.default_root().parent


def load_health(args: argparse.Namespace) -> dict:
    if getattr(args, "health_file", None):
        try:
            return json.loads(Path(args.health_file).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise coordinator.CoordinatorError(f"cannot read health file {args.health_file}: {exc}") from exc
    ledger = Path(getattr(args, "ledger", None) or (local_root(getattr(args, "state_root", None))
                                                     / "token_ledger.sqlite3"))
    if not ledger.is_file():
        return {"status": "HEALTHY", "providers": {}}
    from scripts.token_tracker.ledger import TokenLedger

    return TokenLedger(ledger).get_health()


def load_catalog(args: argparse.Namespace) -> dict | None:
    path = getattr(args, "t3_catalog", None)
    if not path:
        return None
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise coordinator.CoordinatorError(f"cannot read T3 catalog {path}: {exc}") from exc


def repo_slug() -> str:
    """owner/name for the current checkout, read through `gh` (same as issue_claim)."""
    done = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                          capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise coordinator.CoordinatorError(f"gh repo view failed: {done.stderr.strip()[:300]}")
    return done.stdout.strip()


def gh_runner(argv: list[str]) -> str:
    done = subprocess.run(["gh", *argv], capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise coordinator.CoordinatorError(f"gh {' '.join(argv[:3])} failed: "
                                          f"{(done.stderr or done.stdout).strip()[:300]}")
    return done.stdout


def run_issue_claim(args: list[str], repo: Path) -> dict:
    done = subprocess.run([sys.executable, str(REPO_ROOT / "scripts" / "issue_claim.py"), *args, "--json"],
                          cwd=str(repo), capture_output=True, text=True, check=False)
    try:
        payload = json.loads(done.stdout or "{}")
    except ValueError:
        payload = {"ok": False, "error": (done.stdout or done.stderr).strip()}
    if done.returncode != 0:
        payload.setdefault("ok", False)
    return payload


def checkpoint(args: argparse.Namespace, signal: coordinator.Signal, local: Path) -> tuple[dict, Path]:
    """Capture or export the checkpoint deterministically."""
    from scripts import handover as handover_tool

    if args.envelope:
        path = Path(args.envelope).resolve()
        envelope, errors = handover_tool.validate_file(path)
        if errors or envelope is None:
            raise coordinator.CoordinatorError(f"invalid handover envelope: {'; '.join(errors)}")
        return envelope, path
    if args.candidate:
        if not args.child_cancelled:
            raise coordinator.CoordinatorError(
                "T3 candidate export requires --child-cancelled after task_cancel; a zombie child must "
                "not share the candidate checkout")
        result = handover_tool.export_t3(handover_tool.ExportOptions(
            candidate=Path(args.candidate).resolve(), branch=args.branch or "",
            issue=signal.issue, pr=signal.pr, repo=Path(args.repo).resolve(),
            provider=signal.from_provider, harness=signal.from_harness, model=args.from_model,
            agent_name=args.agent_name, session_id=signal.from_session,
            risk_tier=signal.tier, role=signal.role,
            completed=args.completed, remaining=args.remaining, decisions=args.decisions,
            key_pointers=args.key_pointers, thread_id=args.t3_thread, child_id=args.t3_child,
            child_cancelled=args.child_cancelled, push=not args.no_push,
            root=local / "handovers"))
        return result["envelope"], Path(result["path"])
    result = handover_tool.capture(Path(args.worktree or ".").resolve(), handover_tool.CaptureOptions(
        issue=signal.issue, reason=signal.reason, pr=signal.pr,
        provider=signal.from_provider, harness=signal.from_harness, model=args.from_model,
        agent_name=args.agent_name, session_id=signal.from_session,
        risk_tier=signal.tier, role=signal.role, excluded_providers=list(signal.excluded_providers),
        completed=args.completed, remaining=args.remaining, decisions=args.decisions,
        key_pointers=args.key_pointers, verify_command=args.verify_command,
        verify_status=args.verify_status, verify_summary=args.verify_summary,
        base=args.base, push=not args.no_push, root=local / "handovers"))
    return result["envelope"], Path(result["path"])


def handover(args: argparse.Namespace) -> int:
    signal = coordinator.Signal(
        issue=args.issue, reason=args.reason, role=args.role, tier=args.tier,
        from_provider=args.from_provider, from_harness=args.from_harness,
        from_session=args.from_session, excluded_providers=tuple(args.excluded_provider or ()),
        pr=args.pr, worktree=str(Path(args.worktree or ".").resolve()),
        failed_repairs=args.failed_repairs,
    ).validate()
    local = local_root(args.state_root)
    repo = Path(args.repo).resolve()
    health = load_health(args)
    catalog = load_catalog(args)
    registry = coordinator.load_registry(Path(args.registry))

    if not args.envelope and not args.dry_run:
        envelope, path = checkpoint(args, signal, local)
    elif args.envelope:
        envelope, path = checkpoint(args, signal, local)
    else:  # dry run without a checkpoint: a minimal preview envelope is not written
        envelope = {"handover_id": f"ho-{signal.issue}-000", "reason": signal.reason,
                    "git_state": {"issue": signal.issue, "pr": signal.pr, "branch": args.branch or "",
                                  "worktree_path": str(Path(args.worktree or ".").resolve())}}
        path = None

    if not args.dry_run and not args.no_transfer and (
            signal.from_harness in ("", "unknown") or signal.from_session in ("", "unknown")):
        raise coordinator.CoordinatorError(
            "a live transfer needs --from-harness and --from-session "
            "(use --dry-run or --no-transfer to plan without transferring)")

    labels: list[str] = []
    if not args.offline:
        from scripts import issue_claim as claim_tool

        labels = claim_tool.read_labels(gh_runner, repo_slug(), signal.issue)
    count = claim_tool_handover_count(labels) if labels else 0
    if args.handover_count is not None:
        count = args.handover_count

    targets = coordinator.targets_from_registry(registry, catalog, health,
                                                coordinator.load_launchers(Path(args.launchers)))
    decision = coordinator.decide(signal, targets=targets, health=health, handover_count=count,
                                  transport=args.transport, available_t3=(
                                      None if catalog is None else
                                      {p.get("providerInstanceId") for p in catalog.get("providers", [])
                                       if p.get("canRunChildTask")}))
    record = execute(signal, envelope, path, decision, args, local, repo)
    if args.json:
        print(json.dumps(record, indent=2, sort_keys=True))
    else:
        print(f"#{signal.issue}: {decision.action} ({decision.reason})")
        if decision.target:
            print(f"  target: {decision.target.get('model')} via {decision.transport}")
        if decision.escalation:
            print(f"  escalation: {decision.escalation['reason']} -> reviewer")
        if record.get("dispatch"):
            print(f"  dispatch: {record['dispatch'].get('status')} "
                  f"{record['dispatch'].get('pickup_path') or record['dispatch'].get('payload_path') or ''}".rstrip())
    if decision.action == "park" or record["status"] in ("transfer_failed", "failed"):
        return 1
    return 0


def execute(signal: coordinator.Signal, envelope: dict, path: Path | None,
            decision: coordinator.Decision, args: argparse.Namespace,
            local: Path, repo: Path) -> dict:
    """Transfer and dispatch one decision; shared by `handover` and the daemon loop."""
    options = coordinator.DispatchOptions(
        root=local, repo=repo, worktree=Path(args.worktree).resolve() if args.worktree else None,
        branch=args.branch, pr=signal.pr, envelope_path=path, dry_run=args.dry_run,
        launchers=coordinator.load_launchers(Path(args.launchers)),
        incoming_harness=args.to_harness, incoming_session=args.to_session,
        spawn_timeout=args.spawn_timeout)
    record: dict[str, Any] = {"decision": decision.to_dict(),
                              "envelope_path": str(path) if path else None}
    if decision.action == "park":
        record["status"] = "parked"
    else:
        record["status"] = "dry_run" if args.dry_run else "dispatched"
        if decision.transport in ("cli", "copilot_cli") and not args.dry_run:
            options.worktree = incoming_worktree(args, envelope, local)
            record["incoming_worktree"] = str(options.worktree)
        if not args.dry_run and not args.no_transfer:
            identity = coordinator.incoming_identity(decision, envelope["handover_id"], options)
            transfer_args = ["transfer", str(signal.issue), "--harness", signal.from_harness,
                             "--session", signal.from_session, "--to-harness", identity["harness"],
                             "--to-session", identity["session"], "--to-model", identity["model"]]
            if signal.pr:
                transfer_args += ["--pr", str(signal.pr)]
            transferred = run_issue_claim(transfer_args, repo)
            record["transfer"] = transferred
            if not transferred.get("ok"):
                record["status"] = "transfer_failed"
        if record["status"] in ("dispatched", "dry_run") and (
                not args.dry_run or bool(envelope.get("checksum_sha256"))):
            record["dispatch"] = coordinator.dispatch(decision, envelope, options)
            if record["dispatch"].get("status") == "failed":
                record["status"] = "failed"
    if decision.escalation is not None and not args.dry_run:
        key = decision.escalation.get("handover_id") or f"issue-{signal.issue}"
        coordinator.write_escalation(local, decision.escalation, key=str(key))
    return record


def claim_tool_handover_count(labels: list[str]) -> int:
    from scripts import issue_claim as claim_tool

    return claim_tool.handover_count(labels)


def incoming_worktree(args: argparse.Namespace, envelope: dict, local: Path) -> Path:
    """The isolated worktree an auto-spawned CLI worker runs in."""
    if args.incoming_worktree:
        return Path(args.incoming_worktree).resolve()
    branch = args.branch or envelope["git_state"]["branch"]
    if not branch or branch == "(detached)":
        raise coordinator.CoordinatorError(
            "a CLI dispatch needs --branch (or a branch in the envelope) for its fresh worktree")
    path = local / "coordinator" / "worktrees" / envelope["handover_id"]
    return coordinator.prepare_worktree(Path(args.repo).resolve(), branch, path)


def pending_signal(envelope: dict) -> coordinator.Signal:
    """Rebuild the outgoing identity from a stored envelope."""
    origin, constraints, state = envelope["from"], envelope["target_constraints"], envelope["git_state"]
    return coordinator.Signal(
        issue=state["issue"], reason=envelope["reason"], role=constraints["role"],
        tier=constraints["risk_tier"], from_provider=origin["provider"],
        from_harness=origin["harness"], from_session=origin["session_id"] or "unknown",
        excluded_providers=tuple(constraints["excluded_providers"]), pr=state["pr"],
        worktree=state["worktree_path"] or ".").validate()


def pending_label_issues() -> list[int]:
    """Open issues labeled `handover:pending` (the GitHub side of the signal)."""
    out = gh_runner(["issue", "list", "--label", "handover:pending", "--state", "open",
                     "--json", "number", "--limit", "50"])
    return [int(item["number"]) for item in json.loads(out or "[]") if isinstance(item, dict)]


def cmd_serve(args: argparse.Namespace) -> int:
    """The 0-token daemon loop: watchdog pass, then dispatch pending checkpoints."""
    from scripts import handover as handover_tool

    local = local_root(args.state_root)
    repo = Path(args.repo).resolve()
    health = load_health(args)
    catalog = load_catalog(args)
    registry = coordinator.load_registry(Path(args.registry))
    launchers = coordinator.load_launchers(Path(args.launchers))
    passes = 1 if args.once else (args.passes or 0)
    completed = 0
    escalated = 0
    while True:
        completed += 1
        report = {"counts": {}}
        if not args.no_recover:
            report = coordinator.recover(local, dry_run=args.dry_run, t3_db=args.t3_db,
                                         sessions_root=args.sessions_dir or local / "sessions")
        escalated += int(report["counts"].get("escalate", 0))
        handled: list[dict] = []
        local_pending = coordinator.pending_handovers(local / "handovers", local)
        local_issues = coordinator.known_handover_issues(local / "handovers")
        if not args.offline:
            try:
                for number in pending_label_issues():
                    if number in local_issues:
                        continue
                    escalation = coordinator.escalation(
                        coordinator.INVALID_CHECKPOINT,
                        f"#{number} carries `handover:pending` but no local handover envelope exists; "
                        "the outgoing session must capture one before dispatch.")
                    if not args.dry_run:
                        coordinator.write_escalation(local, escalation, key=f"issue-{number}")
                    handled.append({"issue": number, "status": "invalid_checkpoint",
                                    "escalation": escalation})
                    escalated += 1
            except coordinator.CoordinatorError:
                handled.append({"status": "labels_unavailable"})
        for item in local_pending:
            if item.get("errors") or "handover_id" not in item:
                escalated += 1
                continue
            envelope, errors = handover_tool.validate_file(Path(item["path"]))
            if envelope is None or errors:
                escalated += 1
                continue
            signal = pending_signal(envelope)
            if signal.from_session == "unknown":
                escalation = coordinator.escalation(
                    coordinator.INVALID_CHECKPOINT,
                    f"{envelope['handover_id']} records no outgoing session, so the claim cannot be "
                    "transferred safely; a human or the outgoing session must supply it.")
                if not args.dry_run:
                    coordinator.write_escalation(local, escalation, key=envelope["handover_id"])
                handled.append({"envelope": envelope["handover_id"], "status": "invalid_checkpoint",
                                "escalation": escalation})
                escalated += 1
                continue
            labels: list[str] = []
            if not args.offline:
                from scripts import issue_claim as claim_tool

                labels = claim_tool.read_labels(gh_runner, repo_slug(), signal.issue)
            count = claim_tool_handover_count(labels) if labels else 0
            decision = coordinator.decide(
                signal, targets=coordinator.targets_from_registry(registry, catalog, health, launchers),
                health=health, handover_count=count, transport="auto",
                available_t3=(None if catalog is None else
                              {p.get("providerInstanceId") for p in catalog.get("providers", [])
                               if p.get("canRunChildTask")}))
            record = execute(signal, envelope, Path(item["path"]), decision, args, local, repo)
            handled.append(record)
            if decision.action == "park" or record["status"] in ("transfer_failed", "failed"):
                escalated += 1
        if args.json:
            print(json.dumps({"schema_version": 1, "pass": completed, "recover": report,
                              "handled": handled}, indent=2, sort_keys=True))
        else:
            print(f"pass {completed}: watchdog {report['counts']}, handled {len(handled)} handover(s)")
        if passes and completed >= passes:
            break
        import time
        time.sleep(args.interval)
    return 1 if escalated else 0


def cmd_heartbeat(args: argparse.Namespace) -> int:
    harness = args.harness or os.environ.get("AGENT_HARNESS")
    session = args.session or os.environ.get("AGENT_SESSION_ID")
    if not harness or not session:
        raise coordinator.CoordinatorError("--harness/--session (or $AGENT_HARNESS/$AGENT_SESSION_ID) are required")
    lease = leases.Lease(
        harness=harness, session=session, model=args.model or os.environ.get("AGENT_MODEL", "unknown"),
        agent_name=args.agent_name, issue=args.issue, pr=args.pr,
        worktree=str(Path(args.worktree).resolve()) if args.worktree else None,
        branch=args.branch, transport=args.transport,
        context_pct=args.context_pct, quota_pct=args.quota_pct,
        ttl_seconds=args.ttl, pid=args.pid if args.pid is not None else None,
    ).validate()
    path = leases.LeaseStore(args.sessions_dir or local_root(args.state_root) / "sessions").write(lease)
    payload = {"ok": True, "path": str(path), "lease": lease.to_dict()}
    print(json.dumps(payload, indent=2, sort_keys=True) if args.json else f"lease {path}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    local = local_root(args.state_root)
    snapshot = leases.scan(args.sessions_dir or local / "sessions", args.stale_factor)
    pending = coordinator.pending_handovers(local / "handovers", local)
    escalations = []
    directory = local / "coordinator" / "escalations"
    if directory.is_dir():
        for path in sorted(directory.glob("*.json")):
            try:
                escalations.append(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, ValueError):
                continue
    t3_expired = []
    if args.t3_db:
        t3_expired = [lease.__dict__ for lease in leases.t3_leases(args.t3_db)]
    payload = {"schema_version": 1, "local_root": str(local), "leases": snapshot,
               "pending_handovers": pending, "escalations": escalations,
               "providers": load_health(args), "t3_expired": t3_expired}
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        counts = snapshot["counts"]
        print(f"leases: {counts['alive']} alive, {counts['stale']} stale, {counts['expired']} expired")
        print(f"pending handovers: {len(pending)}; escalations: {len(escalations)}; "
              f"T3 expired: {len(t3_expired)}")
        for lease in snapshot["leases"]["expired"]:
            print(f"  expired: {lease['harness']}/{lease['session']} issue {lease.get('issue')}")
    return 0


def cmd_recover(args: argparse.Namespace) -> int:
    local = local_root(args.state_root)
    report = coordinator.recover(local, dry_run=args.dry_run, stale_factor=args.stale_factor,
                                 t3_db=args.t3_db,
                                 sessions_root=args.sessions_dir or local / "sessions")
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"watchdog: {report['counts']}")
        for action in report["actions"]:
            print(f"  {action.get('kind')} {action.get('action')}: "
                  f"{action.get('detail') or action.get('lease', {}).get('session', '')}")
    return 1 if report["counts"].get("escalate") else 0


def cmd_provider_failed(args: argparse.Namespace) -> int:
    from scripts.token_tracker.ledger import TokenLedger

    ledger_path = Path(args.ledger or (local_root(args.state_root) / "token_ledger.sqlite3"))
    ledger = TokenLedger(ledger_path)
    ledger.record_quota_snapshot(provider=args.provider, model_family=args.model_family,
                                 status=args.status, reset_at=args.reset_at,
                                 utilization_pct=args.utilization_pct, source="coordinator")
    print(json.dumps({"ok": True, "provider": args.provider.lower(), "status": args.status.upper(),
                      "reset_at": args.reset_at}, indent=2) if args.json
          else f"{args.provider}: {args.status.upper()}"
          + (f" until {args.reset_at}" if args.reset_at else ""))
    return 0


def cmd_simulate(args: argparse.Namespace) -> int:
    try:
        cases = json.loads(Path(args.cases).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise coordinator.CoordinatorError(f"cannot read scenarios {args.cases}: {exc}") from exc
    result = coordinator.run_simulation(cases, coordinator.load_registry(Path(args.registry)))
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        for entry in result["results"]:
            status = "ok" if entry["ok"] else "FAIL"
            print(f"{status:4} {entry['id']}: {entry['actual']['action']} "
                  f"{entry['actual'].get('provider') or entry['actual'].get('escalation') or ''}")
            if not entry["ok"]:
                print(f"     mismatches: {json.dumps(entry['mismatches'])}")
        print(f"{result['passed']} passed, {result['failed']} failed")
    return 0 if result["failed"] == 0 else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(target: argparse.ArgumentParser, defaults: bool = True) -> None:
        target.add_argument("--json", action="store_true", help="machine-readable output")
        target.add_argument("--state-root", help="local state root (default: main checkout .agents/local)")
        if defaults:
            target.add_argument("--sessions-dir", help="lease directory (default: <state-root>/sessions)")

    hb = sub.add_parser("heartbeat", help="record or refresh this session's lease")
    common(hb)
    hb.add_argument("--harness", help="harness name (default: $AGENT_HARNESS)")
    hb.add_argument("--session", help="session id (default: $AGENT_SESSION_ID)")
    hb.add_argument("--model", help="model id (default: $AGENT_MODEL)")
    hb.add_argument("--agent-name", help="reserved agent name")
    hb.add_argument("--issue", type=int)
    hb.add_argument("--pr", type=int)
    hb.add_argument("--worktree", help="recorded worktree path")
    hb.add_argument("--branch")
    hb.add_argument("--transport", default="cli", help="t3, claude, codex, gemini, copilot, or cli")
    hb.add_argument("--context-pct", help="context used, 0-100 (decimal string)")
    hb.add_argument("--quota-pct", help="quota used, 0-100 (decimal string)")
    hb.add_argument("--ttl", type=int, default=leases.DEFAULT_TTL_SECONDS, help="liveness window in seconds")
    hb.add_argument("--pid", type=int)
    hb.set_defaults(func=cmd_heartbeat)

    st = sub.add_parser("status", help="snapshot leases, pending handovers, escalations and health")
    common(st)
    st.add_argument("--stale-factor", type=int, default=leases.STALE_FACTOR)
    st.add_argument("--t3-db", help="runs.sqlite3 with T3 attempt leases")
    st.add_argument("--health-file", help="provider_health JSON (default: token ledger)")
    st.add_argument("--ledger", help="token ledger path")
    st.set_defaults(func=cmd_status)

    sv = sub.add_parser("serve", help="run the 0-token daemon loop (watchdog + pending dispatch)")
    common(sv)
    sv.add_argument("--once", action="store_true", help="one pass, then exit")
    sv.add_argument("--passes", type=int, help="number of passes before exit (default: forever)")
    sv.add_argument("--interval", type=float, default=60.0, help="seconds between passes")
    sv.add_argument("--no-recover", action="store_true", help="skip the Layer-3 watchdog")
    sv.add_argument("--t3-db")
    sv.add_argument("--repo", default=".")
    sv.add_argument("--offline", action="store_true", help="do not read GitHub labels")
    sv.add_argument("--no-transfer", action="store_true")
    sv.add_argument("--dry-run", action="store_true")
    sv.add_argument("--registry", default=str(coordinator.t3.DEFAULT_REGISTRY))
    sv.add_argument("--launchers", default=str(coordinator.DEFAULT_LAUNCHERS))
    sv.add_argument("--t3-catalog")
    sv.add_argument("--health-file")
    sv.add_argument("--ledger")
    sv.add_argument("--to-harness")
    sv.add_argument("--to-session")
    sv.add_argument("--branch")
    sv.add_argument("--worktree")
    sv.add_argument("--incoming-worktree")
    sv.add_argument("--spawn-timeout", type=int, default=1800)
    sv.set_defaults(func=cmd_serve)

    ho = sub.add_parser("handover", help="checkpoint, transfer the claim and dispatch")
    common(ho)
    ho.add_argument("--issue", type=int, required=True)
    ho.add_argument("--reason", default="manual")
    ho.add_argument("--role", default="developer")
    ho.add_argument("--tier", default="medium")
    ho.add_argument("--from-provider", default="unknown")
    ho.add_argument("--from-harness", default="unknown")
    ho.add_argument("--from-session", default="unknown")
    ho.add_argument("--from-model", default="unknown")
    ho.add_argument("--agent-name")
    ho.add_argument("--excluded-provider", action="append", help="provider to exclude (repeatable)")
    ho.add_argument("--pr", type=int)
    ho.add_argument("--worktree", help="checkpoint worktree (default: current directory)")
    ho.add_argument("--incoming-worktree",
                    help="existing worktree for the incoming CLI worker (default: fresh detached worktree)")
    ho.add_argument("--branch")
    ho.add_argument("--repo", default=".", help="repository path for worktree/claim operations")
    ho.add_argument("--envelope", help="reuse an existing envelope instead of capturing")
    ho.add_argument("--candidate", help="T3 candidate checkout to export onto --branch")
    ho.add_argument("--child-cancelled", action="store_true", help="confirm task_cancel before export")
    ho.add_argument("--t3-thread")
    ho.add_argument("--t3-child")
    ho.add_argument("--transport", default="auto", choices=(*coordinator.TRANSPORTS, "auto"))
    ho.add_argument("--to-harness", help="incoming harness override")
    ho.add_argument("--to-session", help="incoming session override")
    ho.add_argument("--handover-count", type=int, help="override the label-based handover count")
    ho.add_argument("--failed-repairs", type=int, default=0)
    ho.add_argument("--completed", action="append", default=[])
    ho.add_argument("--remaining", action="append", default=[])
    ho.add_argument("--decisions", action="append", default=[])
    ho.add_argument("--key-pointers", action="append", default=[])
    ho.add_argument("--verify-command")
    ho.add_argument("--verify-status", choices=("passed", "failed", "unverified"))
    ho.add_argument("--verify-summary")
    ho.add_argument("--base")
    ho.add_argument("--no-push", action="store_true", help="keep the WIP commit local")
    ho.add_argument("--no-transfer", action="store_true", help="skip issue_claim transfer (planning only)")
    ho.add_argument("--offline", action="store_true", help="do not read GitHub labels")
    ho.add_argument("--dry-run", action="store_true", help="plan only; write nothing and spawn nothing")
    ho.add_argument("--registry", default=str(coordinator.t3.DEFAULT_REGISTRY))
    ho.add_argument("--launchers", default=str(coordinator.DEFAULT_LAUNCHERS))
    ho.add_argument("--t3-catalog", help="live orchestrator_capabilities JSON")
    ho.add_argument("--health-file", help="provider_health JSON (default: token ledger)")
    ho.add_argument("--ledger")
    ho.add_argument("--spawn-timeout", type=int, default=1800)
    ho.set_defaults(func=handover)

    rc = sub.add_parser("recover", help="watchdog: snapshot expired workers, never delete work")
    common(rc)
    rc.add_argument("--dry-run", action="store_true")
    rc.add_argument("--stale-factor", type=int, default=leases.STALE_FACTOR)
    rc.add_argument("--t3-db")
    rc.set_defaults(func=cmd_recover)

    pf = sub.add_parser("provider-failed", help="mark a provider THROTTLED/EXHAUSTED after a hard 429")
    common(pf, defaults=False)
    pf.add_argument("--provider", required=True)
    pf.add_argument("--model-family", default="all")
    pf.add_argument("--status", default="EXHAUSTED", choices=("THROTTLED", "EXHAUSTED"))
    pf.add_argument("--reset-at")
    pf.add_argument("--utilization-pct")
    pf.add_argument("--ledger")
    pf.set_defaults(func=cmd_provider_failed)

    sim = sub.add_parser("simulate", help="evaluate synthetic 429/context/thrash scenarios")
    common(sim, defaults=False)
    sim.add_argument("--cases", default=str(REPO_ROOT / "config" / "engineering-harness"
                                             / "coordinator-scenarios.json"))
    sim.add_argument("--registry", default=str(coordinator.t3.DEFAULT_REGISTRY))
    sim.set_defaults(func=cmd_simulate)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except (coordinator.CoordinatorError, leases.LeaseError, HarnessError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}) if getattr(args, "json", False)
              else f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
