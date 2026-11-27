"""Unified Control Console service shared by Web UI, CLI, and MCP Adapter."""
from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
from typing import Any, Callable

from scripts import handover as handover_tool
from scripts.engineering_harness import leases, routing, t3
from scripts.engineering_harness.contracts import redact
from scripts.engineering_harness.engine import Engine
from scripts.engineering_harness.store import Store as RunsStore
from scripts.token_tracker.ledger import TokenLedger
from scripts.token_tracker.quotas import QuotaConfig, decimal_str, money

from .store import (
    ConsoleError,
    ConsoleStore,
    default_console_db_path,
    default_local_root,
    find_main_checkout,
    normalize_budget_provider,
    utc_now_iso,
)

SCHEMA_VERSION = 1
DEFAULT_QUOTAS_PATH = Path(__file__).resolve().parents[2] / "config" / "provider-quotas.json"
DEFAULT_REGISTRY_PATH = t3.DEFAULT_REGISTRY
DEFAULT_LAUNCHERS_PATH = Path(__file__).resolve().parents[2] / "config" / "engineering-harness" / "launchers.json"
_PICKUP_ISSUE_RE = re.compile(r"^#\s*Handover pickup:\s*issue\s*#(\d+)", re.MULTILINE)
_HO_ISSUE_RE = re.compile(r"^ho-(\d+)-(\d+)")


def _read_json_safe(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _ro_sqlite(path: Path) -> sqlite3.Connection | None:
    if not path.is_file():
        return None
    uri = f"file:{path.resolve()}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=5.0)
        conn.row_factory = sqlite3.Row
        return conn
    except sqlite3.Error:
        return None


def _normalize_iso(ts: str | float | int | None) -> str:
    if ts is None or ts == "":
        return utc_now_iso()
    if isinstance(ts, (int, float)):
        return datetime.fromtimestamp(float(ts), tz=timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    text = str(ts).strip()
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        else:
            parsed = parsed.astimezone(timezone.utc)
        return parsed.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    except ValueError:
        return text


def _safe_kill_pid(pid: int) -> dict[str, Any]:
    if pid <= 1 or pid == os.getpid():
        return {"attempted": False, "pid": pid, "reason": "unsafe_pid"}
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return {"attempted": False, "pid": pid, "reason": "not_running"}
    except PermissionError:
        return {"attempted": False, "pid": pid, "reason": "permission_denied"}
    try:
        os.kill(pid, signal.SIGTERM)
        return {"attempted": True, "pid": pid, "signal": "SIGTERM"}
    except OSError as exc:
        return {"attempted": False, "pid": pid, "error": str(exc)}


class ConsoleService:
    """Unified observability and operator control facade for Phase 5."""

    def __init__(
        self,
        *,
        local_root: Path | str | None = None,
        repo_root: Path | str | None = None,
        console_db: Path | str | None = None,
        ledger_db: Path | str | None = None,
        runs_db: Path | str | None = None,
        sessions_dir: Path | str | None = None,
        handovers_dir: Path | str | None = None,
        agent_names_path: Path | str | None = None,
        quotas_path: Path | str | None = None,
        registry_path: Path | str | None = None,
        launchers_path: Path | str | None = None,
        t3_catalog_path: Path | str | None = None,
        offline: bool = False,
        gh_runner: Callable[[list[str]], str] | None = None,
    ) -> None:
        self.local_root = Path(local_root).resolve() if local_root else default_local_root()
        self.repo_root = Path(repo_root).resolve() if repo_root else find_main_checkout()
        self.console_db = Path(console_db).resolve() if console_db else (
            self.local_root / "harness_console.sqlite3" if local_root else default_console_db_path()
        )
        self.ledger_db = Path(ledger_db).resolve() if ledger_db else (self.local_root / "token_ledger.sqlite3")
        if runs_db is not None:
            self.runs_db = Path(runs_db).resolve()
        else:
            repo_runs = self.repo_root / ".engineering-harness" / "runs.sqlite3"
            local_runs = self.local_root / "runs.sqlite3"
            self.runs_db = local_runs if (not repo_runs.is_file() and local_runs.is_file()) else repo_runs
        self.sessions_dir = Path(sessions_dir).resolve() if sessions_dir else (self.local_root / "sessions")
        self.handovers_dir = Path(handovers_dir).resolve() if handovers_dir else (self.local_root / "handovers")
        self.agent_names_path = Path(agent_names_path).resolve() if agent_names_path else (
            self.local_root / "agent-names.json"
        )
        self.quotas_path = Path(quotas_path).resolve() if quotas_path else DEFAULT_QUOTAS_PATH
        self.registry_path = Path(registry_path).resolve() if registry_path else DEFAULT_REGISTRY_PATH
        self.launchers_path = Path(launchers_path).resolve() if launchers_path else DEFAULT_LAUNCHERS_PATH
        self.t3_catalog_path = Path(t3_catalog_path).resolve() if t3_catalog_path else None
        self.offline = offline
        self._gh_runner = gh_runner
        self.store = ConsoleStore(self.console_db)

    def close(self) -> None:
        self.store.close()

    def _quota_config(self) -> QuotaConfig:
        return QuotaConfig(self.quotas_path)

    # ------------------------------------------------------------------ health

    def provider_health(self) -> dict[str, Any]:
        """Compute Track B provider health, T3 instance coverage, and DeepSeek USD budget."""
        cfg = self._quota_config()
        if self.ledger_db.is_file():
            ledger = TokenLedger(db_path=self.ledger_db, quota_config=cfg)
            try:
                health = ledger.get_health()
            finally:
                ledger.close()
        else:
            health = self._empty_health(cfg)

        # Apply operator DeepSeek / Copilot USD budget override if set.
        override = self.store.get_budget_override("copilot")
        copilot_cfg = cfg.get_quota("copilot")
        default_budget = money(
            (copilot_cfg.get("deepseek_overflow") or {}).get("budget_usd")
            or copilot_cfg.get("budget_usd", "25.00")
        )
        effective_budget = override if override is not None else default_budget

        copilot_info = health.get("providers", {}).get("copilot")
        if copilot_info is not None:
            api_spend = self._copilot_api_spend(cfg)
            util_dec = (
                (api_spend / effective_budget) * Decimal("100")
                if effective_budget > 0
                else Decimal("100")
            )
            warn_pct = money(copilot_cfg.get("warning_threshold_pct", "85.00"))
            exh_pct = money(copilot_cfg.get("exhaustion_threshold_pct", "100.00"))

            # Preserve an active manual/429 snapshot already enforced by get_health(),
            # otherwise recompute status against the effective USD budget ceiling.
            latest_snap = self._latest_quota_snapshot("copilot")
            snapshot_active = (
                copilot_info["status"] != "HEALTHY"
                or (
                    latest_snap is not None
                    and latest_snap.get("source") == "manual_status"
                    and latest_snap.get("status") == "HEALTHY"
                )
            )
            if snapshot_active:
                pass
            elif api_spend >= effective_budget or util_dec >= exh_pct:
                copilot_info["status"] = "EXHAUSTED"
            elif util_dec >= warn_pct:
                copilot_info["status"] = "THROTTLED"
            else:
                copilot_info["status"] = "HEALTHY"

            copilot_info["utilization_pct"] = decimal_str(util_dec, places=2)
            copilot_info["budget_usd"] = decimal_str(effective_budget, places=2)
            copilot_info["api_spend_usd"] = decimal_str(api_spend, places=6)
            copilot_info["budget_override_active"] = override is not None

        # Recompute overall health status across providers.
        statuses = [info.get("status", "HEALTHY") for info in health.get("providers", {}).values()]
        if "EXHAUSTED" in statuses:
            health["status"] = "EXHAUSTED"
        elif "THROTTLED" in statuses:
            health["status"] = "THROTTLED"
        else:
            health["status"] = "HEALTHY"

        # Enrich with T3 providerInstanceIds and CLI launcher coverage.
        registry = _read_json_safe(self.registry_path) or {}
        launchers = _read_json_safe(self.launchers_path) or {}
        catalog = _read_json_safe(self.t3_catalog_path) if self.t3_catalog_path else None
        live_t3_ids = None
        if isinstance(catalog, dict):
            live_t3_ids = {
                p.get("providerInstanceId")
                for p in catalog.get("providers", [])
                if p.get("canRunChildTask")
            }

        t3_instances: list[dict[str, Any]] = []
        seen_t3: set[tuple[str, str]] = set()
        for target in registry.get("targets", []):
            if target.get("transport") != "t3":
                continue
            prov_id = str(target.get("provider", ""))
            model = str(target.get("model", ""))
            if (prov_id, model) in seen_t3:
                continue
            seen_t3.add((prov_id, model))
            canon = routing.canonical_provider(target)
            t3_instances.append(
                {
                    "providerInstanceId": prov_id,
                    "canonical_provider": canon,
                    "model": model,
                    "tiers": list(target.get("tiers", [])),
                    "live_available": None if live_t3_ids is None else (prov_id in live_t3_ids),
                    "health_status": health.get("providers", {}).get(canon, {}).get("status", "HEALTHY"),
                }
            )

        for canon, info in health.get("providers", {}).items():
            qcfg = cfg.get_quota(canon)
            info["quota_type"] = qcfg.get("type", "rolling_window")
            if qcfg.get("type") == "rolling_window":
                info["max_tokens"] = qcfg.get("max_tokens")
            info["has_cli_launcher"] = canon in (launchers.get("launchers") or {})
            info["t3_instances"] = [inst for inst in t3_instances if inst["canonical_provider"] == canon]

        copilot = health.get("providers", {}).get("copilot", {})
        health["t3_instances"] = t3_instances
        health["deepseek_overflow"] = {
            "provider": "copilot",
            "model_family": "deepseek",
            "budget_usd": copilot.get("budget_usd", decimal_str(effective_budget, places=2)),
            "spent_usd": copilot.get("api_spend_usd", "0.000000"),
            "remaining_usd": decimal_str(
                max(Decimal("0"), money(copilot.get("budget_usd", effective_budget)) - money(copilot.get("api_spend_usd", "0"))),
                places=6,
            ),
            "utilization_pct": copilot.get("utilization_pct", "0.00"),
            "status": copilot.get("status", "HEALTHY"),
            "override_active": override is not None,
        }
        return health

    def _empty_health(self, cfg: QuotaConfig) -> dict[str, Any]:
        providers: dict[str, Any] = {}
        for p in ("claude", "codex", "gemini", "copilot"):
            qcfg = cfg.get_quota(p)
            providers[p] = {
                "status": "HEALTHY",
                "window_hours": qcfg.get("window_hours", 168),
                "utilization_pct": "0.00",
                "reset_at": None,
                "burn": {
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                    "total_tokens": 0,
                    "premium_requests": "0.00",
                    "estimated_cost_usd": "0.000000",
                    "event_count": 0,
                },
            }
        return {"status": "HEALTHY", "checked_at": utc_now_iso(), "providers": providers}

    def _copilot_api_spend(self, cfg: QuotaConfig) -> Decimal:
        conn = _ro_sqlite(self.ledger_db)
        if conn is None:
            return Decimal("0")
        try:
            qcfg = cfg.get_quota("copilot")
            window_hours = int(qcfg.get("window_hours", 168))
            from datetime import timedelta

            since = (datetime.now(timezone.utc) - timedelta(hours=window_hours)).isoformat()
            rows = conn.execute(
                "SELECT estimated_cost_usd FROM usage_events WHERE provider='copilot' AND billing_mode='api' AND recorded_at >= ?",
                (since,),
            ).fetchall()
            return sum((money(r["estimated_cost_usd"]) for r in rows), Decimal("0"))
        except sqlite3.Error:
            return Decimal("0")
        finally:
            conn.close()

    def _latest_quota_snapshot(self, provider: str) -> dict[str, Any] | None:
        conn = _ro_sqlite(self.ledger_db)
        if conn is None:
            return None
        try:
            row = conn.execute(
                "SELECT status, reset_at, utilization_pct, source, observed_at FROM quota_snapshots WHERE provider=? ORDER BY id DESC LIMIT 1",
                (provider.lower(),),
            ).fetchone()
            return dict(row) if row else None
        except sqlite3.Error:
            return None
        finally:
            conn.close()

    # ------------------------------------------------------------------ board

    def _correlated_usage_by_run(self) -> dict[str, dict[str, Any]]:
        conn = _ro_sqlite(self.ledger_db)
        if conn is None:
            return {}
        try:
            rows = conn.execute(
                """
                SELECT harness_run_id, harness_attempt_id,
                       input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                       estimated_cost_usd
                FROM usage_events
                WHERE harness_run_id IS NOT NULL
                """
            ).fetchall()
        except sqlite3.Error:
            return {}
        finally:
            conn.close()

        by_run: dict[str, dict[str, Any]] = {}
        for r in rows:
            run_id = str(r["harness_run_id"])
            entry = by_run.setdefault(
                run_id,
                {"tokens": 0, "cost_usd": Decimal("0"), "events": 0, "attempts": {}},
            )
            tok = (
                int(r["input_tokens"])
                + int(r["output_tokens"])
                + int(r["cache_read_tokens"])
                + int(r["cache_write_tokens"])
            )
            cost = money(r["estimated_cost_usd"])
            entry["tokens"] += tok
            entry["cost_usd"] += cost
            entry["events"] += 1
            att_id = r["harness_attempt_id"]
            if att_id:
                att = entry["attempts"].setdefault(str(att_id), {"tokens": 0, "cost_usd": Decimal("0"), "events": 0})
                att["tokens"] += tok
                att["cost_usd"] += cost
                att["events"] += 1

        for entry in by_run.values():
            entry["cost_usd"] = decimal_str(entry["cost_usd"], places=6)
            for att in entry["attempts"].values():
                att["cost_usd"] = decimal_str(att["cost_usd"], places=6)
        return by_run

    def _read_runs(self) -> list[dict[str, Any]]:
        conn = _ro_sqlite(self.runs_db)
        if conn is None:
            return []
        try:
            runs = [dict(r) for r in conn.execute("SELECT * FROM runs ORDER BY created DESC").fetchall()]
            correlated = self._correlated_usage_by_run()
            out: list[dict[str, Any]] = []
            for run in runs:
                run_id = run["id"]
                tasks = [
                    {
                        "id": t["id"],
                        "role": t["role"],
                        "status": t["status"],
                        "repairs": t["repairs"],
                    }
                    for t in conn.execute("SELECT id, role, status, repairs FROM tasks WHERE run_id=? ORDER BY id", (run_id,))
                ]
                attempts_rows = conn.execute(
                    "SELECT id, task_id, status, lease, envelope, reservation, tokens FROM attempts WHERE run_id=? ORDER BY rowid DESC",
                    (run_id,),
                ).fetchall()
                attempts: list[dict[str, Any]] = []
                active_attempt = None
                for a in attempts_rows:
                    env = json.loads(a["envelope"]) if a["envelope"] else {}
                    att_corr = correlated.get(run_id, {}).get("attempts", {}).get(a["id"], {})
                    att_dict = {
                        "attempt_id": a["id"],
                        "task_id": a["task_id"],
                        "status": a["status"],
                        "transport": env.get("transport"),
                        "target": env.get("target"),
                        "reserved_tokens": int(a["tokens"]),
                        "reserved_cost_usd": a["reservation"],
                        "correlated_tokens": att_corr.get("tokens", 0),
                        "correlated_cost_usd": att_corr.get("cost_usd", "0.000000"),
                        "lease_expires_epoch": float(a["lease"]),
                    }
                    attempts.append(att_dict)
                    if a["status"] == "RUNNING" and active_attempt is None:
                        active_attempt = att_dict
                run_corr = correlated.get(run_id, {})
                out.append(
                    {
                        "run_id": run_id,
                        "status": run["status"],
                        "candidate": run["candidate"],
                        "source_revision": run["source_revision"],
                        "reserved_tokens": int(run["tokens"]),
                        "reserved_cost_usd": run["cost"],
                        "correlated_tokens": run_corr.get("tokens", 0),
                        "correlated_cost_usd": run_corr.get("cost_usd", "0.000000"),
                        "created_at": _normalize_iso(run["created"]),
                        "deadline_epoch": float(run["deadline"]),
                        "tasks": tasks,
                        "active_attempt": active_attempt,
                        "attempts": attempts,
                        "paused": self.store.is_paused(run_id=run_id) is not None,
                        "pin": self.store.get_pin(run_id=run_id),
                    }
                )
            return out
        except sqlite3.Error:
            return []
        finally:
            conn.close()

    def _read_handovers(self) -> tuple[list[dict[str, Any]], dict[int, int]]:
        envelopes: list[dict[str, Any]] = []
        counts: dict[int, int] = {}
        dispatched_dir = self.local_root / "coordinator" / "dispatched"
        if not self.handovers_dir.is_dir():
            return envelopes, counts
        for path in sorted(self.handovers_dir.glob("*.json")):
            data = _read_json_safe(path)
            if not isinstance(data, dict) or "handover_id" not in data:
                continue
            git_state = data.get("git_state") or {}
            issue = git_state.get("issue")
            if isinstance(issue, int):
                counts[issue] = counts.get(issue, 0) + 1
            disp_file = dispatched_dir / f"{data['handover_id']}.json"
            disp = _read_json_safe(disp_file) if disp_file.is_file() else None
            envelopes.append(
                {
                    "handover_id": data["handover_id"],
                    "created_at": data.get("created_at"),
                    "reason": data.get("reason"),
                    "issue": issue,
                    "pr": git_state.get("pr"),
                    "branch": git_state.get("branch"),
                    "head_sha": git_state.get("head_sha"),
                    "wip_committed": git_state.get("wip_committed"),
                    "worktree_path": git_state.get("worktree_path"),
                    "from": data.get("from"),
                    "risk_tier": (data.get("target_constraints") or {}).get("risk_tier"),
                    "dispatched": disp is not None,
                    "dispatch_status": disp.get("status") if isinstance(disp, dict) else "pending",
                    "dispatch_transport": disp.get("transport") if isinstance(disp, dict) else None,
                    "path": str(path),
                }
            )
        return envelopes, counts

    def _read_escalations(self) -> list[dict[str, Any]]:
        directory = self.local_root / "coordinator" / "escalations"
        if not directory.is_dir():
            return []
        out = []
        for path in sorted(directory.glob("*.json")):
            data = _read_json_safe(path)
            if isinstance(data, dict):
                out.append(data)
        return out

    def _read_agent_reservations(self) -> list[dict[str, Any]]:
        data = _read_json_safe(self.agent_names_path)
        if not isinstance(data, dict):
            return []
        return [r for r in data.get("reservations", []) if isinstance(r, dict)]

    def _github_snapshot(self) -> dict[str, Any]:
        if self.offline:
            return {"available": False, "reason": "offline"}
        runner = self._gh_runner
        if runner is None:
            def _default_gh(argv: list[str]) -> str:
                proc = subprocess.run(["gh", *argv], capture_output=True, text=True, check=False, timeout=20)
                if proc.returncode != 0:
                    raise ConsoleError(proc.stderr.strip()[:200] or "gh failed")
                return proc.stdout

            runner = _default_gh
        try:
            issues_raw = runner(
                ["issue", "list", "--label", "in progress", "--state", "open", "--json", "number,title,labels,updatedAt", "--limit", "50"]
            )
            prs_raw = runner(
                ["pr", "list", "--state", "open", "--json", "number,title,isDraft,headRefOid,reviewDecision,statusCheckRollup,labels,url", "--limit", "50"]
            )
            return {
                "available": True,
                "claimed_issues": json.loads(issues_raw or "[]"),
                "open_prs": json.loads(prs_raw or "[]"),
            }
        except Exception as exc:
            return {"available": False, "reason": str(exc)[:200]}

    def active_board(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        include_github: bool = False,
    ) -> dict[str, Any]:
        """Collect live leases, agent reservations, T3/durable runs, handovers, and escalations."""
        now = datetime.now(timezone.utc)
        lease_snapshot = leases.scan(self.sessions_dir, now=now)
        all_leases: list[dict[str, Any]] = []
        for state_name, items in lease_snapshot["leases"].items():
            for item in items:
                updated = item.get("updated_at")
                age_sec = None
                if updated:
                    try:
                        age_sec = round((now - leases.parse_timestamp(updated)).total_seconds(), 1)
                    except leases.LeaseError:
                        age_sec = None
                enriched = {**item, "state": state_name, "heartbeat_age_seconds": age_sec}
                if issue is not None and enriched.get("issue") != issue:
                    continue
                all_leases.append(enriched)

        runs = self._read_runs()
        if run_id is not None:
            runs = [r for r in runs if r["run_id"] == run_id]

        envelopes, ho_counts = self._read_handovers()
        if issue is not None:
            envelopes = [e for e in envelopes if e.get("issue") == issue]

        escalations = self._read_escalations()
        if issue is not None:
            escalations = [e for e in escalations if e.get("issue") == issue]

        reservations = self._read_agent_reservations()
        if issue is not None:
            reservations = [r for r in reservations if issue in (r.get("issues") or [])]

        gh_data = self._github_snapshot() if include_github else {"available": False, "reason": "skipped"}

        # Build correlated per-issue summary items.
        issue_numbers: set[int] = set()
        for l in all_leases:
            if isinstance(l.get("issue"), int):
                issue_numbers.add(l["issue"])
        for e in envelopes:
            if isinstance(e.get("issue"), int):
                issue_numbers.add(e["issue"])
        for r in reservations:
            for num in r.get("issues") or []:
                if isinstance(num, int):
                    issue_numbers.add(num)
        for esc in escalations:
            if isinstance(esc.get("issue"), int):
                issue_numbers.add(esc["issue"])

        items_by_issue: list[dict[str, Any]] = []
        for num in sorted(issue_numbers):
            matching_leases = [l for l in all_leases if l.get("issue") == num]
            latest_lease = max(matching_leases, key=lambda l: l.get("updated_at") or "") if matching_leases else None
            matching_envs = [e for e in envelopes if e.get("issue") == num]
            latest_env = matching_envs[-1] if matching_envs else None
            matching_res = [r for r in reservations if num in (r.get("issues") or [])]
            active_res = matching_res[0] if matching_res else None
            pause = self.store.is_paused(issue=num)
            pin = self.store.get_pin(issue=num)
            items_by_issue.append(
                {
                    "issue": num,
                    "pr": (latest_lease or {}).get("pr") or (latest_env or {}).get("pr"),
                    "agent_name": (latest_lease or {}).get("agent_name") or (active_res or {}).get("name"),
                    "harness": (latest_lease or {}).get("harness") or (active_res or {}).get("harness"),
                    "model": (latest_lease or {}).get("model") or (active_res or {}).get("model"),
                    "transport": (latest_lease or {}).get("transport") or (latest_env or {}).get("dispatch_transport"),
                    "branch": (latest_lease or {}).get("branch") or (latest_env or {}).get("branch"),
                    "worktree": (latest_lease or {}).get("worktree") or (latest_env or {}).get("worktree_path"),
                    "context_pct": (latest_lease or {}).get("context_pct"),
                    "quota_pct": (latest_lease or {}).get("quota_pct"),
                    "heartbeat_age_seconds": (latest_lease or {}).get("heartbeat_age_seconds"),
                    "lease_state": (latest_lease or {}).get("state"),
                    "handover_count": ho_counts.get(num, 0),
                    "escalation_count": sum(1 for esc in escalations if esc.get("issue") == num),
                    "paused": pause is not None,
                    "pause_reason": pause.get("reason") if pause else None,
                    "pinned_to": pin.get("provider") if pin else None,
                }
            )

        return {
            "leases": all_leases,
            "lease_counts": lease_snapshot["counts"],
            "reservations": reservations,
            "runs": runs,
            "handovers": envelopes,
            "handover_counts": {str(k): v for k, v in sorted(ho_counts.items())},
            "escalations": escalations,
            "items": items_by_issue,
            "github": gh_data,
        }

    def list_pickups(self) -> list[dict[str, Any]]:
        """List ready-to-paste handover pickup briefs for IDE/Desktop sessions."""
        pickup_dir = self.handovers_dir / "pickup"
        if not pickup_dir.is_dir():
            return []
        out: list[dict[str, Any]] = []
        for path in sorted(pickup_dir.glob("*.md"), reverse=True):
            try:
                content = redact(path.read_text(encoding="utf-8"))
            except OSError:
                continue
            stat = path.stat()
            handover_id = path.stem
            issue_num = None
            m = _PICKUP_ISSUE_RE.search(content) or _HO_ISSUE_RE.match(handover_id)
            if m:
                issue_num = int(m.group(1))
            out.append(
                {
                    "handover_id": handover_id,
                    "issue": issue_num,
                    "path": str(path),
                    "updated_at": _normalize_iso(stat.st_mtime),
                    "brief": content,
                }
            )
        return out

    def status(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        include_github: bool = False,
    ) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "checked_at": utc_now_iso(),
            "local_root": str(self.local_root),
            "provider_health": self.provider_health(),
            "board": self.active_board(issue=issue, run_id=run_id, include_github=include_github),
            "controls": self.store.state_snapshot(),
            "pickups": self.list_pickups(),
            "recent_commands": self.store.list_commands(limit=25),
        }

    # -------------------------------------------------------- timeline & tail

    def timeline(
        self,
        *,
        issue: int | None = None,
        pr: int | None = None,
        run_id: str | None = None,
    ) -> dict[str, Any]:
        """Correlated chronological timeline per issue, PR, or durable run."""
        if issue is None and pr is None and not run_id:
            raise ConsoleError("timeline requires at least one of --issue, --pr, or --run")

        events: list[dict[str, Any]] = []

        # 1. Handover envelopes & dispatches
        envelopes, _ = self._read_handovers()
        for env in envelopes:
            if issue is not None and env.get("issue") != issue:
                continue
            if pr is not None and env.get("pr") != pr:
                continue
            if run_id is not None and issue is None and pr is None:
                continue
            events.append(
                {
                    "timestamp": _normalize_iso(env.get("created_at")),
                    "kind": "handover_envelope",
                    "title": f"Handover {env['handover_id']} ({env.get('reason')})",
                    "detail": {
                        "handover_id": env["handover_id"],
                        "issue": env.get("issue"),
                        "pr": env.get("pr"),
                        "branch": env.get("branch"),
                        "head_sha": env.get("head_sha"),
                        "wip_committed": env.get("wip_committed"),
                        "dispatch_status": env.get("dispatch_status"),
                        "dispatch_transport": env.get("dispatch_transport"),
                    },
                }
            )

        # 2. Escalations
        for esc in self._read_escalations():
            if issue is not None and esc.get("issue") != issue:
                continue
            if pr is not None and esc.get("pr") != pr:
                continue
            events.append(
                {
                    "timestamp": _normalize_iso(esc.get("created_at")),
                    "kind": "escalation",
                    "title": f"Escalation: {esc.get('reason')}",
                    "detail": {
                        "reason": esc.get("reason"),
                        "issue": esc.get("issue"),
                        "pr": esc.get("pr"),
                        "detail": redact(str(esc.get("detail", ""))),
                    },
                }
            )

        # 3. Operator commands
        for cmd in self.store.list_commands(limit=200):
            matched = False
            if issue is not None and cmd.get("target_type") == "issue" and cmd.get("target_id") == str(issue):
                matched = True
            if run_id is not None and cmd.get("target_type") == "run" and cmd.get("target_id") == run_id:
                matched = True
            if cmd.get("target_type") == "all":
                matched = True
            if matched:
                events.append(
                    {
                        "timestamp": _normalize_iso(cmd.get("created_at")),
                        "kind": "operator_command",
                        "title": f"Operator {cmd['command']} ({cmd['transport']})",
                        "detail": {
                            "command_id": cmd["command_id"],
                            "command": cmd["command"],
                            "actor": cmd["actor"],
                            "target_type": cmd["target_type"],
                            "target_id": cmd["target_id"],
                            "payload": cmd["payload"],
                            "ack": cmd["ack"],
                        },
                    }
                )

        # 4. Durable harness events (runs.sqlite3)
        if run_id is not None:
            conn = _ro_sqlite(self.runs_db)
            if conn is not None:
                try:
                    rows = conn.execute(
                        "SELECT seq, created, body FROM events WHERE run_id=? ORDER BY seq ASC",
                        (run_id,),
                    ).fetchall()
                    for r in rows:
                        body = json.loads(r["body"])
                        events.append(
                            {
                                "timestamp": _normalize_iso(r["created"]),
                                "kind": "harness_event",
                                "title": f"Run {run_id[:8]}: {body.get('kind', 'event')}",
                                "detail": {"seq": r["seq"], **body},
                            }
                        )
                except sqlite3.Error:
                    pass
                finally:
                    conn.close()

        # 5. Track B correlated token burn (numeric/cost metadata ONLY; never transcript text)
        burn_total = 0
        cost_total = Decimal("0")
        by_provider: dict[str, dict[str, Any]] = {}
        lconn = _ro_sqlite(self.ledger_db)
        if lconn is not None:
            try:
                clauses: list[str] = []
                params: list[Any] = []
                if issue is not None:
                    clauses.append("issue_number=?")
                    params.append(issue)
                if pr is not None:
                    clauses.append("pr_number=?")
                    params.append(pr)
                if run_id is not None:
                    clauses.append("harness_run_id=?")
                    params.append(run_id)
                if clauses:
                    rows = lconn.execute(
                        f"""
                        SELECT recorded_at, provider, harness, model,
                               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                               estimated_cost_usd, accuracy
                        FROM usage_events
                        WHERE {' OR '.join(clauses)}
                        ORDER BY recorded_at ASC
                        """,
                        params,
                    ).fetchall()
                    for r in rows:
                        tok = (
                            int(r["input_tokens"])
                            + int(r["output_tokens"])
                            + int(r["cache_read_tokens"])
                            + int(r["cache_write_tokens"])
                        )
                        c = money(r["estimated_cost_usd"])
                        burn_total += tok
                        cost_total += c
                        prov = str(r["provider"])
                        pentry = by_provider.setdefault(prov, {"tokens": 0, "cost_usd": Decimal("0"), "events": 0})
                        pentry["tokens"] += tok
                        pentry["cost_usd"] += c
                        pentry["events"] += 1
                        events.append(
                            {
                                "timestamp": _normalize_iso(r["recorded_at"]),
                                "kind": "token_usage",
                                "title": f"{prov}/{r['model']}: {tok} tokens (${r['estimated_cost_usd']})",
                                "detail": {
                                    "provider": prov,
                                    "harness": r["harness"],
                                    "model": r["model"],
                                    "tokens": tok,
                                    "estimated_cost_usd": r["estimated_cost_usd"],
                                    "accuracy": r["accuracy"],
                                },
                            }
                        )
            except sqlite3.Error:
                pass
            finally:
                lconn.close()

        events.sort(key=lambda item: item.get("timestamp") or "")
        formatted_by_provider = {
            k: {**v, "cost_usd": decimal_str(v["cost_usd"], places=6)} for k, v in sorted(by_provider.items())
        }
        return {
            "schema_version": SCHEMA_VERSION,
            "filter": {"issue": issue, "pr": pr, "run_id": run_id},
            "events": events,
            "burn_summary": {
                "total_tokens": burn_total,
                "estimated_cost_usd": decimal_str(cost_total, places=6),
                "by_provider": formatted_by_provider,
            },
        }

    def tail(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        lines: int = 100,
    ) -> dict[str, Any]:
        """Return bounded, redacted operational logs & events (never raw Track B transcripts)."""
        entries: list[dict[str, Any]] = []
        seq = 0

        # 1. Coordinator spawn logs (.agents/local/coordinator/logs/*.log)
        logs_dir = self.local_root / "coordinator" / "logs"
        if logs_dir.is_dir():
            for log_file in sorted(logs_dir.glob("*.log")):
                if issue is not None and not log_file.stem.startswith(f"ho-{issue}-"):
                    continue
                try:
                    raw_lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
                except OSError:
                    continue
                mtime = _normalize_iso(log_file.stat().st_mtime)
                for line in raw_lines[-lines:]:
                    seq += 1
                    entries.append(
                        {
                            "seq": seq,
                            "timestamp": mtime,
                            "source": f"coordinator:{log_file.name}",
                            "level": "INFO",
                            "message": redact(line),
                        }
                    )

        # 2. Durable harness events (runs.sqlite3)
        conn = _ro_sqlite(self.runs_db)
        if conn is not None:
            try:
                if run_id is not None:
                    rows = conn.execute(
                        "SELECT run_id, seq, created, body FROM events WHERE run_id=? ORDER BY seq DESC LIMIT ?",
                        (run_id, lines),
                    ).fetchall()
                elif issue is None:
                    rows = conn.execute(
                        "SELECT run_id, seq, created, body FROM events ORDER BY seq DESC LIMIT ?",
                        (lines,),
                    ).fetchall()
                else:
                    rows = []
                for r in reversed(rows):
                    seq += 1
                    body = json.loads(r["body"])
                    entries.append(
                        {
                            "seq": seq,
                            "timestamp": _normalize_iso(r["created"]),
                            "source": f"run:{r['run_id'][:8]}",
                            "level": "INFO",
                            "message": redact(f"{body.get('kind', 'event')} {json.dumps(body, sort_keys=True)}"),
                        }
                    )
            except sqlite3.Error:
                pass
            finally:
                conn.close()

        # 3. Operator commands & steering
        for cmd in reversed(self.store.list_commands(limit=lines)):
            if issue is not None and cmd.get("target_type") == "issue" and cmd.get("target_id") != str(issue):
                continue
            if run_id is not None and cmd.get("target_type") == "run" and cmd.get("target_id") != run_id:
                continue
            seq += 1
            entries.append(
                {
                    "seq": seq,
                    "timestamp": _normalize_iso(cmd.get("created_at")),
                    "source": f"console:{cmd['transport']}",
                    "level": "ACTION",
                    "message": redact(
                        f"{cmd['command']} {cmd['target_type']}={cmd.get('target_id') or '*'} "
                        f"by {cmd['actor']} {json.dumps(cmd['payload'], sort_keys=True)}"
                    ),
                }
            )

        entries.sort(key=lambda item: (item["timestamp"], item["seq"]))
        trimmed = entries[-max(1, min(int(lines), 1000)) :]
        return {
            "schema_version": SCHEMA_VERSION,
            "filter": {"issue": issue, "run_id": run_id},
            "count": len(trimmed),
            "entries": trimmed,
        }

    # ---------------------------------------------------------- interventions

    def dispatch_task(
        self,
        *,
        task: str,
        complexity: str | None = None,
        files: int | None = None,
        financial: bool = False,
        schema: bool = False,
        auth: bool = False,
        scope: str = "fullstack",
        policy_path: Path | str | None = None,
        revision: str = "HEAD",
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        task_text = str(task or "").strip()
        if not task_text:
            raise ConsoleError("dispatch_task requires a non-empty task description")
        registry = _read_json_safe(self.registry_path)
        catalog = _read_json_safe(self.t3_catalog_path) if self.t3_catalog_path else None
        health = self.provider_health()
        capabilities = None
        if isinstance(registry, dict):
            if isinstance(catalog, dict):
                capabilities = t3.capabilities_from_catalog(registry, catalog, health=health)
            else:
                capabilities = {"schema_version": 1, "targets": t3.validate_registry(registry)}
        plan = routing.plan(
            task_text,
            files_count=files,
            financial=financial,
            schema=schema,
            auth=auth,
            requested=complexity,
            scope=scope,
            capabilities=capabilities,
            health=health,
        )
        run_id = None
        if policy_path is not None:
            from scripts.engineering_harness.contracts import validate_policy

            policy = validate_policy(json.loads(Path(policy_path).read_text(encoding="utf-8")))
            store = RunsStore(self.runs_db.parent)
            try:
                run_id = Engine(store).create(
                    self.repo_root,
                    task_text,
                    policy,
                    revision=revision,
                    files_count=files,
                    financial=financial,
                    schema=schema,
                    auth=auth,
                    requested=complexity,
                    scope=scope,
                    capabilities=capabilities,
                )
            finally:
                store.close()
        cmd = self.store.enqueue(
            command="dispatch",
            target_type="run" if run_id else "task",
            target_id=run_id or f"plan-{plan['complexity']}",
            payload={
                "task": task_text,
                "complexity": plan["complexity"],
                "scope": scope,
                "run_id": run_id,
                "requires_approval": self.store.gate_requires_approval(plan["complexity"]),
            },
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "run_id": run_id, "plan": plan}

    def pause(
        self,
        *,
        all_scopes: bool = False,
        issue: int | None = None,
        run_id: str | None = None,
        provider: str | None = None,
        reason: str = "operator_pause",
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        target_type, target_id = self._resolve_scope(all_scopes=all_scopes, issue=issue, run_id=run_id, provider=provider)
        cmd = self.store.enqueue(
            command="pause",
            target_type=target_type,
            target_id=target_id,
            payload={"reason": reason},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "paused": self.store.state_snapshot()["pauses"]}

    def resume(
        self,
        *,
        all_scopes: bool = False,
        issue: int | None = None,
        run_id: str | None = None,
        provider: str | None = None,
        reason: str = "operator_resume",
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        target_type, target_id = self._resolve_scope(all_scopes=all_scopes, issue=issue, run_id=run_id, provider=provider)
        cmd = self.store.enqueue(
            command="resume",
            target_type=target_type,
            target_id=target_id,
            payload={"reason": reason},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "paused": self.store.state_snapshot()["pauses"]}

    def kill(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        reason: str = "operator_kill",
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("kill requires --issue or --run")

        actions: dict[str, Any] = {"run_cancel": None, "process_kills": [], "wip_captures": [], "t3_task_cancel_required": []}

        if run_id:
            if not self.runs_db.is_file():
                raise ConsoleError(f"Run database not found at {self.runs_db}")
            rstore = RunsStore(self.runs_db.parent)
            try:
                active = rstore.active(run_id)
                for att in active:
                    if att["envelope"].get("transport") == "t3":
                        actions["t3_task_cancel_required"].append(
                            {"run_id": run_id, "attempt_id": att["id"], "task_id": att["task_id"]}
                        )
                status = Engine(rstore).cancel(run_id)
                actions["run_cancel"] = {"run_id": run_id, "status": status}
            finally:
                rstore.close()

        if issue is not None:
            board = self.active_board(issue=issue)
            for lease in board["leases"]:
                if isinstance(lease.get("pid"), int):
                    actions["process_kills"].append(_safe_kill_pid(lease["pid"]))
                if lease.get("transport") == "t3":
                    actions["t3_task_cancel_required"].append(
                        {"issue": issue, "harness": lease.get("harness"), "session": lease.get("session")}
                    )
                wt = lease.get("worktree")
                if wt and Path(wt).is_dir():
                    try:
                        changed = handover_tool.changed_paths(Path(wt))
                        if changed:
                            captured = handover_tool.capture(
                                Path(wt),
                                handover_tool.CaptureOptions(
                                    issue=issue,
                                    reason="manual",
                                    pr=lease.get("pr"),
                                    provider=lease.get("transport") or "unknown",
                                    harness=lease.get("harness") or "unknown",
                                    model=lease.get("model") or "unknown",
                                    agent_name=lease.get("agent_name"),
                                    session_id=lease.get("session"),
                                    push=False,
                                    root=self.handovers_dir,
                                ),
                            )
                            actions["wip_captures"].append(
                                {
                                    "worktree": wt,
                                    "handover_id": captured["envelope"]["handover_id"],
                                    "wip_committed": captured["wip"].committed,
                                    "sha": captured["wip"].sha,
                                    "patch": captured["wip"].patch,
                                }
                            )
                    except Exception as exc:
                        actions["wip_captures"].append({"worktree": wt, "error": str(exc)})

        target_type = "run" if run_id and issue is None else "issue"
        target_id = run_id if target_type == "run" else str(issue)
        cmd = self.store.enqueue(
            command="kill",
            target_type=target_type,
            target_id=target_id,
            payload={"reason": reason, "issue": issue, "run_id": run_id, **actions},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "actions": actions}

    def steer(
        self,
        *,
        note: str,
        issue: int | None = None,
        run_id: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("steer requires --issue or --run")
        clean_note = redact(str(note or "").strip())
        if not clean_note:
            raise ConsoleError("steer requires a non-empty --note")
        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="steer",
            target_type=target_type,
            target_id=target_id,
            payload={"note": clean_note, "issue": issue, "run_id": run_id},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "note": clean_note}

    def handover(
        self,
        *,
        to: str,
        issue: int | None = None,
        run_id: str | None = None,
        reason: str = "manual",
        pin: bool = True,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("handover requires --issue or --run")
        to_val = str(to or "").strip()
        if not to_val:
            raise ConsoleError("handover requires --to <provider|t3-instance>")
        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="handover" if pin else "handover",
            target_type=target_type,
            target_id=target_id,
            payload={"to": to_val, "reason": reason, "pin": pin, "issue": issue, "run_id": run_id},
            actor=actor,
            transport=transport,
        )
        if not pin:
            # Remove implicit pin if caller explicitly opted out of pinning.
            self.store.enqueue(
                command="unpin",
                target_type=target_type,
                target_id=target_id,
                payload={"reason": "handover_without_pin"},
                actor=actor,
                transport=transport,
            )
        return {"ok": True, "command": cmd, "pinned_to": to_val if pin else None}

    def pin(
        self,
        *,
        to: str,
        issue: int | None = None,
        run_id: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("pin requires --issue or --run")
        to_val = str(to or "").strip()
        if not to_val:
            raise ConsoleError("pin requires --to <provider|t3-instance>")
        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="pin",
            target_type=target_type,
            target_id=target_id,
            payload={"to": to_val},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "pin": self.store.get_pin(issue=issue, run_id=run_id)}

    def unpin(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("unpin requires --issue or --run")
        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="unpin",
            target_type=target_type,
            target_id=target_id,
            payload={},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd}

    def takeover(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        release_claim: bool = False,
        harness: str | None = None,
        session: str | None = None,
        pr: int | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("takeover requires --issue or --run")
        board = self.active_board(issue=issue, run_id=run_id)
        worktree = None
        branch = None
        detected_harness = harness
        detected_session = session
        detected_pr = pr

        if issue is not None:
            for item in board["items"]:
                if item["issue"] == issue:
                    worktree = item.get("worktree")
                    branch = item.get("branch")
                    detected_harness = detected_harness or item.get("harness")
                    detected_pr = detected_pr or item.get("pr")
                    break
            for lease in board["leases"]:
                if lease.get("issue") == issue:
                    detected_harness = detected_harness or lease.get("harness")
                    detected_session = detected_session or lease.get("session")
                    worktree = worktree or lease.get("worktree")
                    branch = branch or lease.get("branch")
                    detected_pr = detected_pr or lease.get("pr")
                    break

        claim_release = None
        if release_claim and issue is not None and not self.offline:
            if detected_harness and detected_session:
                argv = [
                    "python3",
                    str(Path(__file__).resolve().parents[1] / "issue_claim.py"),
                    "release",
                    str(issue),
                    "--harness",
                    detected_harness,
                    "--session",
                    detected_session,
                    "--json",
                ]
                if detected_pr:
                    argv += ["--pr", str(detected_pr)]
                done = subprocess.run(argv, cwd=str(self.repo_root), capture_output=True, text=True, check=False)
                claim_release = {"returncode": done.returncode, "output": (done.stdout or done.stderr).strip()}
            else:
                claim_release = {"skipped": True, "reason": "missing_harness_or_session"}

        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="takeover",
            target_type=target_type,
            target_id=target_id,
            payload={
                "reason": "operator_takeover",
                "worktree": worktree,
                "branch": branch,
                "release_claim": release_claim,
            },
            actor=actor,
            transport=transport,
        )
        return {
            "ok": True,
            "command": cmd,
            "issue": issue,
            "run_id": run_id,
            "worktree": worktree,
            "branch": branch,
            "claim_release": claim_release,
        }

    def set_budget(
        self,
        *,
        provider: str,
        usd: str,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        norm = normalize_budget_provider(provider)
        amount = decimal_str(money(usd), places=2)
        cmd = self.store.enqueue(
            command="set_budget",
            target_type="provider",
            target_id=norm,
            payload={"provider": norm, "usd": amount},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "provider": norm, "budget_usd": amount}

    def mark_status(
        self,
        *,
        provider: str,
        status: str,
        model_family: str = "all",
        reset_at: str | None = None,
        utilization_pct: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        norm_provider = str(provider or "").strip().lower()
        norm_status = str(status or "").strip().upper()
        if norm_status not in ("HEALTHY", "THROTTLED", "EXHAUSTED"):
            raise ConsoleError("status must be HEALTHY, THROTTLED, or EXHAUSTED")
        if not norm_provider:
            raise ConsoleError("provider must not be empty")
        ledger = TokenLedger(db_path=self.ledger_db, quota_config=self._quota_config())
        try:
            snap_id = ledger.record_quota_snapshot(
                provider=norm_provider,
                model_family=model_family,
                status=norm_status,
                reset_at=reset_at,
                utilization_pct=utilization_pct,
                source="manual_status",
            )
        finally:
            ledger.close()
        cmd = self.store.enqueue(
            command="mark_status",
            target_type="provider",
            target_id=norm_provider,
            payload={
                "provider": norm_provider,
                "status": norm_status,
                "model_family": model_family,
                "reset_at": reset_at,
                "quota_snapshot_id": snap_id,
            },
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "provider": norm_provider, "status": norm_status, "snapshot_id": snap_id}

    def set_gate(
        self,
        *,
        tier: str,
        require_approval: bool = True,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        norm_tier = str(tier or "").strip().lower()
        if norm_tier not in routing.TIERS:
            raise ConsoleError(f"tier must be one of {', '.join(routing.TIERS)}")
        cmd = self.store.enqueue(
            command="set_gate",
            target_type="tier",
            target_id=norm_tier,
            payload={"tier": norm_tier, "require_approval": bool(require_approval)},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "tier": norm_tier, "require_approval": bool(require_approval)}

    def approve(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        handover_id: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is not None:
            target_type, target_id = "issue", str(issue)
        elif run_id:
            target_type, target_id = "run", run_id
        elif handover_id:
            target_type, target_id = "task", handover_id
        else:
            raise ConsoleError("approve requires --issue, --run, or --handover-id")
        cmd = self.store.enqueue(
            command="approve",
            target_type=target_type,
            target_id=target_id,
            payload={},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "approved": {"target_type": target_type, "target_id": target_id}}

    @staticmethod
    def _resolve_scope(
        *,
        all_scopes: bool,
        issue: int | None,
        run_id: str | None,
        provider: str | None,
    ) -> tuple[str, str | None]:
        chosen = [
            ("all", None) if all_scopes else None,
            ("issue", str(issue)) if issue is not None else None,
            ("run", run_id) if run_id else None,
            ("provider", provider.strip().lower()) if provider else None,
        ]
        active = [c for c in chosen if c is not None]
        if len(active) != 1:
            raise ConsoleError("specify exactly one of --all, --issue, --run, or --provider")
        return active[0]
