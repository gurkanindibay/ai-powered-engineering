"""Cross-Provider Token Consumption Tracker CLI implementation.

Delivers unified visibility across Claude, Codex, Gemini, Copilot (DeepSeek overflow),
and T3 Code child sessions, and exposes the read-only provider_health JSON contract.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from decimal import Decimal
import json
from pathlib import Path
import sys
from typing import Any, Dict, List, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from .ledger import TokenLedger, default_ledger_path
from .quotas import QuotaConfig, money, decimal_str
from .collectors import (
    ClaudeCollector,
    CodexCollector,
    GeminiCollector,
    CopilotCollector,
    HarnessCollector,
)


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="token_tracker.py",
        description="Cross-provider token consumption tracker and quota monitor",
    )
    parser.add_argument("--db", type=Path, default=None, help="Path to token_ledger.sqlite3")
    parser.add_argument("--config", type=Path, default=None, help="Path to provider-quotas.json")

    subparsers = parser.add_subparsers(dest="command", required=True)

    # 1. ingest
    ingest_p = subparsers.add_parser("ingest", help="Ingest telemetry logs into SQLite ledger")
    ingest_p.add_argument(
        "--provider",
        choices=["all", "claude", "codex", "gemini", "copilot", "harness"],
        default="all",
        help="Provider to ingest (default: all)",
    )
    ingest_p.add_argument("--source-dir", type=Path, default=None, help="Override root directory for collector files")
    ingest_p.add_argument("--json", action="store_true", help="Output JSON result")

    # 2. record
    record_p = subparsers.add_parser("record", help="Directly record usage or rate-limit events")
    record_p.add_argument("--provider", required=True, help="Provider name (claude, codex, gemini, copilot)")
    record_p.add_argument("--model", required=True, help="Model identifier")
    record_p.add_argument("--input", type=int, default=0, help="Input prompt tokens")
    record_p.add_argument("--output", type=int, default=0, help="Output tokens")
    record_p.add_argument("--cache-read", type=int, default=0, help="Cache read input tokens")
    record_p.add_argument("--cache-write", type=int, default=0, help="Cache creation input tokens")
    record_p.add_argument("--reasoning", type=int, default=0, help="Reasoning/thinking tokens")
    record_p.add_argument("--premium-requests", default="0", help="Copilot premium requests (Decimal string)")
    record_p.add_argument("--harness", default="cli", help="Harness name (claude_code, antigravity, etc.)")
    record_p.add_argument("--session-id", default=None, help="Session identifier")
    record_p.add_argument("--agent-name", default=None, help="Agent name")
    record_p.add_argument("--issue", type=int, default=None, help="GitHub issue number")
    record_p.add_argument("--pr", type=int, default=None, help="GitHub PR number")
    record_p.add_argument("--run-id", default=None, help="Durable harness run ID")
    record_p.add_argument("--attempt-id", default=None, help="Harness attempt ID")
    record_p.add_argument("--event", default="usage", help="Event type: usage, 429, throttle, exhausted")
    record_p.add_argument("--reset-at", default=None, help="ISO-8601 UTC reset timestamp for 429/throttle")
    record_p.add_argument("--status", default=None, choices=["HEALTHY", "THROTTLED", "EXHAUSTED"])
    record_p.add_argument("--accuracy", default="exact", choices=["exact", "request_metered", "estimated", "reserved_estimated"])
    record_p.add_argument("--billing-mode", default="subscription", choices=["subscription", "api", "enterprise"])
    record_p.add_argument("--json", action="store_true", help="Output JSON result")

    # 3. health
    health_p = subparsers.add_parser("health", help="Check provider health and quota burn")
    health_p.add_argument("--provider", default=None, help="Filter by provider")
    health_p.add_argument("--json", action="store_true", help="Output JSON result")

    # 4. report
    report_p = subparsers.add_parser("report", help="Generate usage and cost report")
    report_p.add_argument(
        "--by",
        choices=["provider", "model", "issue", "pr", "agent", "run"],
        default="provider",
        help="Grouping dimension (default: provider)",
    )
    report_p.add_argument("--since", default="7d", help="Lookback window (e.g. 7d, 24h, 30d, or ISO timestamp)")
    report_p.add_argument("--json", action="store_true", help="Output JSON result")

    # 5. budget-check
    check_p = subparsers.add_parser("budget-check", help="Fast pre-dispatch budget & quota check")
    check_p.add_argument("--provider", required=True, help="Provider name")
    check_p.add_argument("--model", required=True, help="Model name")
    check_p.add_argument("--json", action="store_true", help="Output JSON result")

    return parser


def cmd_ingest(args: argparse.Namespace, ledger: TokenLedger) -> int:
    collectors = []
    p = args.provider.lower()
    if p in ("all", "claude"):
        collectors.append(ClaudeCollector(ledger))
    if p in ("all", "codex"):
        collectors.append(CodexCollector(ledger))
    if p in ("all", "gemini"):
        collectors.append(GeminiCollector(ledger))
    if p in ("all", "copilot"):
        collectors.append(CopilotCollector(ledger))
    if p in ("all", "harness"):
        collectors.append(HarnessCollector(ledger))

    results = []
    for c in collectors:
        res = c.collect(source_override=args.source_dir)
        results.append(res)

    total_new = sum(r["new_events"] for r in results)
    total_scanned = sum(r["files_scanned"] for r in results)

    output_data = {
        "status": "ok",
        "total_files_scanned": total_scanned,
        "total_new_events": total_new,
        "collectors": results,
    }

    if args.json:
        print(json.dumps(output_data, indent=2))
    else:
        print(f"Ingestion complete: {total_new} new events from {total_scanned} files scanned.")
        for r in results:
            print(f"  [{r['provider']}] {r['new_events']} new events ({r['files_scanned']} files scanned)")

    return 0


def cmd_record(args: argparse.Namespace, ledger: TokenLedger) -> int:
    now_iso = datetime.now(timezone.utc).isoformat()
    ev_type = args.event.lower()

    snapshot_id = None
    if args.status or ev_type in ("429", "throttle", "exhausted"):
        status = args.status or ("EXHAUSTED" if ev_type in ("429", "exhausted") else "THROTTLED")
        snapshot_id = ledger.record_quota_snapshot(
            provider=args.provider,
            model_family=ledger.config.resolve_model_family(args.model),
            status=status,
            reset_at=args.reset_at,
            source="manual_status" if args.status else ("429_event" if ev_type == "429" else "manual_cap"),
            observed_at=now_iso,
        )

    event_inserted = False
    source_key = f"manual:{args.provider}:{datetime.now(timezone.utc).timestamp()}:{args.session_id or 'direct'}"
    if args.input > 0 or args.output > 0 or money(args.premium_requests) > 0 or ev_type == "usage":
        event_inserted = ledger.record_usage_event(
            source_event_key=source_key,
            recorded_at=now_iso,
            provider=args.provider,
            harness=args.harness,
            model=args.model,
            session_id=args.session_id,
            agent_name=args.agent_name,
            issue_number=args.issue,
            pr_number=args.pr,
            harness_run_id=args.run_id,
            harness_attempt_id=args.attempt_id,
            input_tokens=args.input,
            output_tokens=args.output,
            cache_read_tokens=args.cache_read,
            cache_write_tokens=args.cache_write,
            reasoning_tokens=args.reasoning,
            premium_requests=args.premium_requests,
            accuracy=args.accuracy,
            billing_mode=args.billing_mode,
        )

    out = {
        "status": "recorded",
        "quota_snapshot_id": snapshot_id,
        "usage_event_inserted": event_inserted,
        "source_event_key": source_key if event_inserted else None,
    }
    if args.json:
        print(json.dumps(out, indent=2))
    else:
        print(f"Recorded successfully: event_inserted={event_inserted}, snapshot_id={snapshot_id}")
    return 0


def cmd_health(args: argparse.Namespace, ledger: TokenLedger) -> int:
    health_data = ledger.get_health(provider_filter=args.provider)
    if args.json:
        print(json.dumps(health_data, indent=2))
    else:
        print(f"System Health: {health_data['status']} (checked at {health_data['checked_at']})")
        print("-" * 65)
        for p, info in health_data["providers"].items():
            util = f"{info['utilization_pct']}%" if info['utilization_pct'] is not None else "N/A"
            reset = f" (resets: {info['reset_at']})" if info['reset_at'] else ""
            burn = info["burn"]
            print(f"  {p.upper():<10} {info['status']:<10} util: {util:<8} tokens: {burn['total_tokens']:<10} cost: ${burn['estimated_cost_usd']}{reset}")
    return 0 if health_data["status"] == "HEALTHY" else (10 if health_data["status"] == "THROTTLED" else 20)


def cmd_report(args: argparse.Namespace, ledger: TokenLedger) -> int:
    report_data = ledger.get_report(by=args.by, since=args.since)
    if args.json:
        print(json.dumps(report_data, indent=2))
    else:
        print(f"Token Consumption Report by {args.by.upper()} (since: {args.since})")
        print("=" * 80)
        print(f"{'Key':<20} {'Events':<7} {'Tokens':<12} {'CacheHit':<9} {'Reqs':<6} {'Cost ($)':<12} {'Accuracy'}")
        print("-" * 80)
        for g in report_data["groups"]:
            acc_str = f"E:{g['accuracy_breakdown']['exact']} R:{g['accuracy_breakdown']['request_metered']} Est:{g['accuracy_breakdown']['estimated']} Res:{g['accuracy_breakdown'].get('reserved_estimated', 0)}"
            print(f"{g['key']:<20} {g['events']:<7} {g['total_tokens']:<12} {g['cache_hit_rate_pct']}%{'':<3} {g['premium_requests']:<6} ${g['estimated_cost_usd']:<11} {acc_str}")
        print("-" * 80)
        tot = report_data["total"]
        acc_tot = f"E:{tot['accuracy_breakdown']['exact']} R:{tot['accuracy_breakdown']['request_metered']} Est:{tot['accuracy_breakdown']['estimated']} Res:{tot['accuracy_breakdown'].get('reserved_estimated', 0)}"
        print(f"{'TOTAL':<20} {tot['events']:<7} {tot['total_tokens']:<12} {tot['cache_hit_rate_pct']}%{'':<3} {tot['premium_requests']:<6} ${tot['estimated_cost_usd']:<11} {acc_tot}")
    return 0


def cmd_budget_check(args: argparse.Namespace, ledger: TokenLedger) -> int:
    health_data = ledger.get_health(provider_filter=args.provider)
    p_info = health_data["providers"].get(args.provider.lower())
    if not p_info:
        res = {"provider": args.provider, "model": args.model, "status": "EXHAUSTED", "reason": "Unknown provider"}
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"Unknown provider '{args.provider}'")
        return 20

    status = p_info["status"]
    out = {
        "provider": args.provider,
        "model": args.model,
        "status": status,
        "utilization_pct": p_info.get("utilization_pct"),
        "reset_at": p_info.get("reset_at"),
        "burn": p_info.get("burn"),
    }
    if args.json:
        print(json.dumps(out, indent=2))
    else:
        print(f"Budget Check [{args.provider}/{args.model}]: {status} (utilization: {p_info.get('utilization_pct', 'N/A')}%)")

    if status == "HEALTHY":
        return 0
    elif status == "THROTTLED":
        return 10
    else:
        return 20


def main(argv: Optional[List[str]] = None) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)

    quota_cfg = QuotaConfig(args.config) if args.config else QuotaConfig()
    ledger = TokenLedger(db_path=args.db, quota_config=quota_cfg)

    try:
        if args.command == "ingest":
            return cmd_ingest(args, ledger)
        elif args.command == "record":
            return cmd_record(args, ledger)
        elif args.command == "health":
            return cmd_health(args, ledger)
        elif args.command == "report":
            return cmd_report(args, ledger)
        elif args.command == "budget-check":
            return cmd_budget_check(args, ledger)
        return 0
    finally:
        ledger.close()


if __name__ == "__main__":
    sys.exit(main())
