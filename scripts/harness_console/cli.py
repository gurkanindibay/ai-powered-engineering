#!/usr/bin/env python3
"""Unified Local Control Console (Web + CLI) for Phase 5.

Provides live visibility into cross-provider quotas (Claude, Codex, Gemini,
DeepSeek-on-Copilot USD cap), active leases, T3/durable runs (reserved vs.
correlated tokens), handover counts, real-time log tail/SSE streaming, and
anytime operator intervention backed by an append-only SQLite command queue.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.engineering_harness.routing import HarnessError, TIERS  # noqa: E402
from .service import (  # noqa: E402
    ConsoleService,
    DEFAULT_LAUNCHERS_PATH,
    DEFAULT_QUOTAS_PATH,
    DEFAULT_REGISTRY_PATH,
)
from .store import ConsoleError  # noqa: E402
from .web import DEFAULT_UI_HOST, DEFAULT_UI_PORT, serve as serve_web  # noqa: E402


def _make_service(args: argparse.Namespace) -> ConsoleService:
    return ConsoleService(
        local_root=getattr(args, "state_root", None),
        repo_root=getattr(args, "repo", None),
        console_db=getattr(args, "console_db", None),
        ledger_db=getattr(args, "ledger", None),
        runs_db=getattr(args, "runs_db", None),
        sessions_dir=getattr(args, "sessions_dir", None),
        handovers_dir=getattr(args, "handovers_dir", None),
        agent_names_path=getattr(args, "agent_names", None),
        quotas_path=getattr(args, "quotas", None) or DEFAULT_QUOTAS_PATH,
        registry_path=getattr(args, "registry", None) or DEFAULT_REGISTRY_PATH,
        launchers_path=getattr(args, "launchers", None) or DEFAULT_LAUNCHERS_PATH,
        t3_catalog_path=getattr(args, "t3_catalog", None),
        offline=bool(getattr(args, "offline", False)),
    )


def _emit(payload: dict[str, Any] | list[Any], as_json: bool, summary: str) -> None:
    if as_json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(summary)


def _format_status(data: dict[str, Any]) -> str:
    lines: list[str] = []
    ph = data["provider_health"]
    lines.append(f"Provider Health: {ph['status']} (checked {ph['checked_at']})")
    for name, info in ph.get("providers", {}).items():
        cap = f" / ${info['budget_usd']}" if info.get("budget_usd") else ""
        lines.append(
            f"  {name:<10} {info['status']:<10} util={info.get('utilization_pct', 'N/A')}%{cap} "
            f"tokens={info['burn']['total_tokens']} cost=${info['burn']['estimated_cost_usd']}"
        )
    ds = ph.get("deepseek_overflow") or {}
    lines.append(
        f"DeepSeek Overflow: {ds.get('status')} spent=${ds.get('spent_usd')} / cap=${ds.get('budget_usd')}"
    )
    board = data["board"]
    lines.append(
        f"Board: {len(board['items'])} issue(s), {len(board['runs'])} run(s), "
        f"{len(board['leases'])} lease(s), {len(data['pickups'])} pickup(s)"
    )
    for item in board["items"]:
        flags = []
        if item.get("paused"):
            flags.append("PAUSED")
        if item.get("pinned_to"):
            flags.append(f"PIN:{item['pinned_to']}")
        flag_str = f" [{', '.join(flags)}]" if flags else ""
        lines.append(
            f"  #{item['issue']} agent={item.get('agent_name') or '-'} model={item.get('model') or '-'} "
            f"ctx={item.get('context_pct') or '-'}% hb={item.get('heartbeat_age_seconds')}s "
            f"ho={item.get('handover_count')}{flag_str}"
        )
    ctl = data["controls"]
    lines.append(
        f"Controls: {len(ctl['pauses'])} pause(s), {len(ctl['pins'])} pin(s), "
        f"{len(ctl['pending_steering'])} steering note(s), {len(ctl['approval_gates'])} gate(s)"
    )
    return "\n".join(lines)


def _resolve_tail_target(args: argparse.Namespace) -> tuple[int | None, str | None]:
    issue = args.issue
    run_id = args.run
    if getattr(args, "target", None) and issue is None and run_id is None:
        raw = str(args.target).strip()
        if raw.isdigit():
            issue = int(raw)
        else:
            run_id = raw
    return issue, run_id


def cmd_serve(args: argparse.Namespace, service: ConsoleService) -> int:
    serve_web(service, host=args.host, port=args.port)
    return 0


def cmd_status(args: argparse.Namespace, service: ConsoleService) -> int:
    data = service.status(issue=args.issue, run_id=args.run, include_github=args.github)
    _emit(data, args.json, _format_status(data))
    return 0


def cmd_tail(args: argparse.Namespace, service: ConsoleService) -> int:
    issue, run_id = _resolve_tail_target(args)
    if not args.follow:
        data = service.tail(issue=issue, run_id=run_id, lines=args.lines)
        if args.json:
            print(json.dumps(data, indent=2, sort_keys=True))
        else:
            for e in data["entries"]:
                print(f"[{e['timestamp']}] [{e['source']}] {e['message']}")
        return 0

    seen: set[tuple[str, str, str]] = set()
    try:
        while True:
            data = service.tail(issue=issue, run_id=run_id, lines=args.lines)
            for e in data["entries"]:
                key = (e["timestamp"], e["source"], e["message"])
                if key in seen:
                    continue
                seen.add(key)
                if args.json:
                    print(json.dumps(e, sort_keys=True), flush=True)
                else:
                    print(f"[{e['timestamp']}] [{e['source']}] {e['message']}", flush=True)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0


def cmd_timeline(args: argparse.Namespace, service: ConsoleService) -> int:
    data = service.timeline(issue=args.issue, pr=args.pr, run_id=args.run)
    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        burn = data["burn_summary"]
        print(f"Timeline ({len(data['events'])} events, {burn['total_tokens']} tokens, ${burn['estimated_cost_usd']})")
        for ev in data["events"]:
            print(f"  [{ev['timestamp']}] {ev['kind']}: {ev['title']}")
    return 0


def cmd_commands(args: argparse.Namespace, service: ConsoleService) -> int:
    cmds = service.store.list_commands(limit=args.limit, unacked_only=args.unacked)
    payload = {"count": len(cmds), "commands": cmds}
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        for c in cmds:
            ack = c["ack"]["status"] if c["ack"] else "pending"
            print(f"{c['command_id']} [{c['created_at']}] {c['command']} {c['target_type']}={c.get('target_id') or '*'} ({ack})")
    return 0


def cmd_dispatch(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.dispatch_task(
        task=args.task,
        complexity=args.complexity,
        files=args.files,
        financial=args.financial,
        schema=args.schema,
        auth=args.auth,
        scope=args.scope,
        policy_path=args.policy,
        revision=args.revision,
        actor=args.actor,
        transport="cli",
    )
    _emit(
        res,
        args.json,
        f"Dispatched {res['command']['command_id']}: tier={res['plan']['complexity']} run_id={res.get('run_id') or '-'}",
    )
    return 0


def cmd_pause(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.pause(
        all_scopes=args.all,
        issue=args.issue,
        run_id=args.run,
        provider=args.provider,
        reason=args.reason,
        actor=args.actor,
        transport="cli",
    )
    _emit(res, args.json, f"Paused ({res['command']['command_id']}): {len(res['paused'])} active pause(s)")
    return 0


def cmd_resume(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.resume(
        all_scopes=args.all,
        issue=args.issue,
        run_id=args.run,
        provider=args.provider,
        reason=args.reason,
        actor=args.actor,
        transport="cli",
    )
    _emit(res, args.json, f"Resumed ({res['command']['command_id']}): {len(res['paused'])} active pause(s)")
    return 0


def cmd_kill(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.kill(issue=args.issue, run_id=args.run, reason=args.reason, actor=args.actor, transport="cli")
    _emit(res, args.json, f"Killed ({res['command']['command_id']}): {json.dumps(res['actions'])}")
    return 0


def cmd_steer(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.steer(note=args.note, issue=args.issue, run_id=args.run, actor=args.actor, transport="cli")
    _emit(res, args.json, f"Steered ({res['command']['command_id']}): {res['note']}")
    return 0


def cmd_handover(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.handover(
        to=args.to,
        issue=args.issue,
        run_id=args.run,
        reason=args.reason,
        pin=not args.no_pin,
        actor=args.actor,
        transport="cli",
    )
    _emit(res, args.json, f"Handover queued ({res['command']['command_id']}): to={args.to} pinned={res['pinned_to']}")
    return 0


def cmd_pin(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.pin(to=args.to, issue=args.issue, run_id=args.run, actor=args.actor, transport="cli")
    _emit(res, args.json, f"Pinned ({res['command']['command_id']}): to={args.to}")
    return 0


def cmd_unpin(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.unpin(issue=args.issue, run_id=args.run, actor=args.actor, transport="cli")
    _emit(res, args.json, f"Unpinned ({res['command']['command_id']})")
    return 0


def cmd_takeover(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.takeover(
        issue=args.issue,
        run_id=args.run,
        release_claim=args.release_claim,
        harness=args.harness,
        session=args.session,
        pr=args.pr,
        actor=args.actor,
        transport="cli",
    )
    _emit(
        res,
        args.json,
        f"Takeover ({res['command']['command_id']}): branch={res.get('branch') or '-'} worktree={res.get('worktree') or '-'}",
    )
    return 0


def cmd_set_budget(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.set_budget(provider=args.provider, usd=args.usd, actor=args.actor, transport="cli")
    _emit(res, args.json, f"Budget updated ({res['command']['command_id']}): {res['provider']} = ${res['budget_usd']}")
    return 0


def cmd_mark_status(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.mark_status(
        provider=args.provider,
        status=args.status,
        model_family=args.model_family,
        reset_at=args.reset_at,
        utilization_pct=args.utilization_pct,
        actor=args.actor,
        transport="cli",
    )
    _emit(res, args.json, f"Status marked ({res['command']['command_id']}): {res['provider']} -> {res['status']}")
    return 0


def cmd_set_gate(args: argparse.Namespace, service: ConsoleService) -> int:
    req = not args.no_require_approval
    res = service.set_gate(tier=args.tier, require_approval=req, actor=args.actor, transport="cli")
    _emit(
        res,
        args.json,
        f"Gate updated ({res['command']['command_id']}): tier={res['tier']} require_approval={res['require_approval']}",
    )
    return 0


def cmd_approve(args: argparse.Namespace, service: ConsoleService) -> int:
    res = service.approve(
        issue=args.issue, run_id=args.run, handover_id=args.handover_id, actor=args.actor, transport="cli"
    )
    _emit(res, args.json, f"Approved ({res['command']['command_id']}): {res['approved']}")
    return 0


def cmd_pickups(args: argparse.Namespace, service: ConsoleService) -> int:
    pickups = service.list_pickups()
    payload = {"count": len(pickups), "pickups": pickups}
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        if not pickups:
            print("No pending pickup briefs.")
        for p in pickups:
            print(f"=== {p['handover_id']} (issue #{p.get('issue')}) ===")
            print(p["brief"])
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="harness_console.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(target: argparse.ArgumentParser, *, with_actor: bool = False) -> None:
        target.add_argument("--json", action="store_true", help="machine-readable JSON output")
        target.add_argument("--state-root", help="local state root (default: main checkout .agents/local)")
        target.add_argument("--repo", help="repository checkout path")
        target.add_argument("--console-db", help="path to harness_console.sqlite3")
        target.add_argument("--ledger", help="path to token_ledger.sqlite3")
        target.add_argument("--runs-db", help="path to runs.sqlite3")
        target.add_argument("--sessions-dir", help="path to leases directory")
        target.add_argument("--handovers-dir", help="path to handovers directory")
        target.add_argument("--agent-names", help="path to agent-names.json")
        target.add_argument("--quotas", help="path to provider-quotas.json")
        target.add_argument("--registry", help="path to t3-registry.json")
        target.add_argument("--launchers", help="path to launchers.json")
        target.add_argument("--t3-catalog", help="optional saved T3 orchestrator_capabilities JSON")
        target.add_argument("--offline", action="store_true", help="disable GitHub CLI queries")
        if with_actor:
            target.add_argument("--actor", default="operator", help="operator identity recorded in command log")

    sv = sub.add_parser("serve", help="run loopback-only web dashboard and SSE server")
    add_common(sv)
    sv.add_argument("--host", default=DEFAULT_UI_HOST, help="loopback interface (127.0.0.1, localhost, ::1)")
    sv.add_argument("--port", type=int, default=DEFAULT_UI_PORT, help="TCP port")
    sv.set_defaults(func=cmd_serve)

    st = sub.add_parser("status", help="unified provider health, board, controls, and pickups")
    add_common(st)
    st.add_argument("--issue", type=int)
    st.add_argument("--run", dest="run")
    st.add_argument("--github", action="store_true", help="include live GitHub issue/PR status")
    st.set_defaults(func=cmd_status)

    tl = sub.add_parser("tail", help="stream or print sanitized operational logs and run events")
    add_common(tl)
    tl.add_argument("target", nargs="?", help="optional issue number or run id")
    tl.add_argument("--issue", type=int)
    tl.add_argument("--run")
    tl.add_argument("--lines", type=int, default=100)
    tl.add_argument("--follow", action="store_true", help="poll for new sanitized log lines")
    tl.add_argument("--interval", type=float, default=1.0)
    tl.set_defaults(func=cmd_tail)

    tm = sub.add_parser("timeline", help="correlated timeline and token/USD burn for an issue, PR, or run")
    add_common(tm)
    tm.add_argument("--issue", type=int)
    tm.add_argument("--pr", type=int)
    tm.add_argument("--run")
    tm.set_defaults(func=cmd_timeline)

    cm = sub.add_parser("commands", help="inspect append-only operator command queue")
    add_common(cm)
    cm.add_argument("--limit", type=int, default=50)
    cm.add_argument("--unacked", action="store_true")
    cm.set_defaults(func=cmd_commands)

    dp = sub.add_parser("dispatch", help="plan or create a routed task dispatch")
    add_common(dp, with_actor=True)
    dp.add_argument("--task", required=True)
    dp.add_argument("--complexity", choices=TIERS)
    dp.add_argument("--files", type=int)
    dp.add_argument("--financial", action="store_true")
    dp.add_argument("--schema", action="store_true")
    dp.add_argument("--auth", action="store_true")
    dp.add_argument("--scope", choices=("fullstack", "backend", "frontend", "mechanical"), default="fullstack")
    dp.add_argument("--policy")
    dp.add_argument("--revision", default="HEAD")
    dp.set_defaults(func=cmd_dispatch)

    for name, fn, help_text in (
        ("pause", cmd_pause, "pause automation globally or for an issue/run/provider"),
        ("resume", cmd_resume, "resume paused automation"),
    ):
        p = sub.add_parser(name, help=help_text)
        add_common(p, with_actor=True)
        p.add_argument("--all", action="store_true")
        p.add_argument("--issue", type=int)
        p.add_argument("--run")
        p.add_argument("--provider")
        p.add_argument("--reason", default=f"operator_{name}")
        p.set_defaults(func=fn)

    kl = sub.add_parser("kill", help="stop an active run/worker and snapshot dirty WIP safely")
    add_common(kl, with_actor=True)
    kl.add_argument("--issue", type=int)
    kl.add_argument("--run")
    kl.add_argument("--reason", default="operator_kill")
    kl.set_defaults(func=cmd_kill)

    sr = sub.add_parser("steer", help="attach a mid-run steering note for the next checkpoint/handover")
    add_common(sr, with_actor=True)
    sr.add_argument("--issue", type=int)
    sr.add_argument("--run")
    sr.add_argument("--note", required=True)
    sr.set_defaults(func=cmd_steer)

    ho = sub.add_parser("handover", help="force handover routing and pin target provider/T3 instance")
    add_common(ho, with_actor=True)
    ho.add_argument("--issue", type=int)
    ho.add_argument("--run")
    ho.add_argument("--to", required=True, help="target provider or T3 providerInstanceId")
    ho.add_argument("--reason", default="manual")
    ho.add_argument("--no-pin", action="store_true")
    ho.set_defaults(func=cmd_handover)

    pn = sub.add_parser("pin", help="pin an issue or run to a provider/T3 instance")
    add_common(pn, with_actor=True)
    pn.add_argument("--issue", type=int)
    pn.add_argument("--run")
    pn.add_argument("--to", required=True)
    pn.set_defaults(func=cmd_pin)

    upn = sub.add_parser("unpin", help="clear a provider/T3 instance pin")
    add_common(upn, with_actor=True)
    upn.add_argument("--issue", type=int)
    upn.add_argument("--run")
    upn.set_defaults(func=cmd_unpin)

    tk = sub.add_parser("takeover", help="pause automation, optionally release claim, and print worktree/branch")
    add_common(tk, with_actor=True)
    tk.add_argument("--issue", type=int)
    tk.add_argument("--run")
    tk.add_argument("--release-claim", action="store_true")
    tk.add_argument("--harness")
    tk.add_argument("--session")
    tk.add_argument("--pr", type=int)
    tk.set_defaults(func=cmd_takeover)

    sb = sub.add_parser("set-budget", help="override Decimal USD budget ceiling (e.g. copilot-deepseek)")
    add_common(sb, with_actor=True)
    sb.add_argument("--provider", required=True)
    sb.add_argument("--usd", required=True)
    sb.set_defaults(func=cmd_set_budget)

    ms = sub.add_parser("mark-status", help="manually set provider HEALTHY/THROTTLED/EXHAUSTED status")
    add_common(ms, with_actor=True)
    ms.add_argument("--provider", required=True)
    ms.add_argument("--status", required=True, choices=("HEALTHY", "THROTTLED", "EXHAUSTED"))
    ms.add_argument("--model-family", default="all")
    ms.add_argument("--reset-at")
    ms.add_argument("--utilization-pct")
    ms.set_defaults(func=cmd_mark_status)

    sg = sub.add_parser("set-gate", help="require or clear operator approval gate for a risk tier")
    add_common(sg, with_actor=True)
    sg.add_argument("--tier", required=True, choices=TIERS)
    group = sg.add_mutually_exclusive_group()
    group.add_argument("--require-approval", action="store_true", default=True)
    group.add_argument("--no-require-approval", action="store_true")
    sg.set_defaults(func=cmd_set_gate)

    ap = sub.add_parser("approve", help="approve a gated issue, run, or handover")
    add_common(ap, with_actor=True)
    ap.add_argument("--issue", type=int)
    ap.add_argument("--run")
    ap.add_argument("--handover-id")
    ap.set_defaults(func=cmd_approve)

    pk = sub.add_parser("pickups", help="list ready-to-paste IDE/Desktop handover briefs")
    add_common(pk)
    pk.set_defaults(func=cmd_pickups)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    service: ConsoleService | None = None
    try:
        service = _make_service(args)
        return int(args.func(args, service))
    except (ConsoleError, HarnessError, ValueError, OSError) as exc:
        if getattr(args, "json", False):
            print(json.dumps({"ok": False, "error": str(exc)}))
        else:
            print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        if service is not None:
            service.close()
