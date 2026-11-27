"""SQLite WAL ledger for usage events, quota snapshots, and collector cursors."""
from __future__ import annotations

import contextlib
from datetime import datetime, timezone, timedelta
from decimal import Decimal, ROUND_HALF_UP
import json
import os
from pathlib import Path
import sqlite3
import subprocess
from typing import Any, Dict, List, Optional, Tuple

from .quotas import QuotaConfig, money, decimal_str

DEFAULT_LEDGER_RELATIVE = Path(".agents") / "local" / "token_ledger.sqlite3"
AGENT_NAMES_RELATIVE = Path(".agents") / "local" / "agent-names.json"


def find_main_checkout() -> Path:
    repo_root = Path(__file__).resolve().parents[2]
    done = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True, check=False
    )
    if done.returncode == 0 and done.stdout.strip():
        git_dir = Path(done.stdout.strip())
        return git_dir.parent if git_dir.name == ".git" else git_dir
    return repo_root


def default_ledger_path() -> Path:
    env_override = os.environ.get("TOKEN_TRACKER_DB")
    if env_override:
        return Path(env_override).resolve()
    return find_main_checkout() / DEFAULT_LEDGER_RELATIVE


def normalize_iso_utc(ts: Optional[str]) -> str:
    """Normalize any timestamp string to standard ISO UTC with timezone offset."""
    if not ts:
        return datetime.now(timezone.utc).isoformat()
    try:
        clean = ts.strip().replace("Z", "+00:00")
        dt = datetime.fromisoformat(clean)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt.isoformat()
    except Exception:
        return ts


class TokenLedger:
    def __init__(self, db_path: Optional[Path] = None, quota_config: Optional[QuotaConfig] = None):
        self.path = Path(db_path or default_ledger_path()).resolve()
        self.config = quota_config or QuotaConfig()
        self._init_db()

    def _init_db(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass

        self.db = sqlite3.connect(str(self.path), timeout=30.0, isolation_level=None)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")

        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS usage_events (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            source_event_key    TEXT NOT NULL UNIQUE,
            recorded_at         TEXT NOT NULL,
            provider            TEXT NOT NULL,
            harness             TEXT NOT NULL,
            model               TEXT NOT NULL,
            session_id          TEXT,
            agent_name          TEXT,
            issue_number        INTEGER,
            pr_number           INTEGER,
            harness_run_id      TEXT,
            harness_attempt_id  TEXT,
            input_tokens        INTEGER NOT NULL DEFAULT 0,
            output_tokens       INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens  INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens    INTEGER NOT NULL DEFAULT 0,
            premium_requests    TEXT NOT NULL DEFAULT '0',
            estimated_cost_usd  TEXT NOT NULL DEFAULT '0',
            accuracy            TEXT NOT NULL,
            billing_mode        TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS quota_snapshots (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            observed_at         TEXT NOT NULL,
            provider            TEXT NOT NULL,
            model_family        TEXT NOT NULL,
            window_type         TEXT NOT NULL,
            utilization_pct     TEXT,
            status              TEXT NOT NULL,
            reset_at            TEXT,
            source              TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS collector_cursors (
            collector_name      TEXT PRIMARY KEY,
            file_path           TEXT NOT NULL,
            byte_offset         INTEGER NOT NULL DEFAULT 0,
            updated_at          TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_usage_recorded ON usage_events(recorded_at);
        CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage_events(provider);
        CREATE INDEX IF NOT EXISTS idx_usage_harness_attempt ON usage_events(harness_run_id, harness_attempt_id);
        CREATE INDEX IF NOT EXISTS idx_quota_provider ON quota_snapshots(provider, observed_at);
        """)

    def close(self) -> None:
        if self.db:
            self.db.close()

    @contextlib.contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        else:
            self.db.execute("COMMIT")

    def resolve_agent_name(self, session_id: Optional[str], issue_number: Optional[int]) -> Optional[str]:
        """Try to resolve agent name from .agents/local/agent-names.json."""
        state_file = find_main_checkout() / AGENT_NAMES_RELATIVE
        if not state_file.exists():
            return None
        try:
            data = json.loads(state_file.read_text(encoding="utf-8"))
            for res in data.get("reservations", []):
                if session_id and res.get("session") == session_id:
                    return res.get("name")
                if issue_number and issue_number in res.get("issues", []):
                    return res.get("name")
        except Exception:
            pass
        return None

    def record_usage_event(
        self,
        source_event_key: str,
        recorded_at: str,
        provider: str,
        harness: str,
        model: str,
        session_id: Optional[str] = None,
        agent_name: Optional[str] = None,
        issue_number: Optional[int] = None,
        pr_number: Optional[int] = None,
        harness_run_id: Optional[str] = None,
        harness_attempt_id: Optional[str] = None,
        input_tokens: int = 0,
        output_tokens: int = 0,
        cache_read_tokens: int = 0,
        cache_write_tokens: int = 0,
        reasoning_tokens: int = 0,
        premium_requests: str = "0",
        estimated_cost_usd: Optional[str] = None,
        accuracy: str = "exact",
        billing_mode: str = "subscription",
    ) -> bool:
        """Insert a usage event. Return True if inserted, False if duplicate source_event_key."""
        agent_name = agent_name or self.resolve_agent_name(session_id, issue_number)
        
        # Calculate cost if not provided
        if estimated_cost_usd is None:
            estimated_cost_usd = self.config.calculate_cost(
                model=model,
                input_tokens=input_tokens,
                output_tokens=output_tokens,
                cache_read_tokens=cache_read_tokens,
                cache_write_tokens=cache_write_tokens,
            )
        else:
            estimated_cost_usd = decimal_str(money(estimated_cost_usd))

        premium_requests_str = decimal_str(money(premium_requests), places=2)
        norm_recorded_at = normalize_iso_utc(recorded_at)

        try:
            with self.transaction():
                self.db.execute(
                    """
                    INSERT INTO usage_events (
                        source_event_key, recorded_at, provider, harness, model,
                        session_id, agent_name, issue_number, pr_number,
                        harness_run_id, harness_attempt_id, input_tokens, output_tokens,
                        cache_read_tokens, cache_write_tokens, reasoning_tokens,
                        premium_requests, estimated_cost_usd, accuracy, billing_mode
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        source_event_key, norm_recorded_at, provider.lower(), harness.lower(), model,
                        session_id, agent_name, issue_number, pr_number,
                        harness_run_id, harness_attempt_id, input_tokens, output_tokens,
                        cache_read_tokens, cache_write_tokens, reasoning_tokens,
                        premium_requests_str, estimated_cost_usd, accuracy, billing_mode
                    )
                )
            return True
        except sqlite3.IntegrityError:
            # Duplicate key -> idempotent no-op
            return False

    def record_quota_snapshot(
        self,
        provider: str,
        model_family: str,
        status: str,
        window_type: str = "weekly",
        utilization_pct: Optional[str] = None,
        reset_at: Optional[str] = None,
        source: str = "rate_limit_header",
        observed_at: Optional[str] = None,
    ) -> int:
        norm_observed_at = normalize_iso_utc(observed_at)
        norm_reset_at = normalize_iso_utc(reset_at) if reset_at else None
        pct_str = decimal_str(money(utilization_pct), places=2) if utilization_pct is not None else None
        with self.transaction():
            cur = self.db.execute(
                """
                INSERT INTO quota_snapshots (
                    observed_at, provider, model_family, window_type,
                    utilization_pct, status, reset_at, source
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    norm_observed_at, provider.lower(), model_family, window_type,
                    pct_str, status.upper(), norm_reset_at, source
                )
            )
            return cur.lastrowid

    def get_cursor(self, collector_name: str) -> Optional[Tuple[str, int]]:
        row = self.db.execute(
            "SELECT file_path, byte_offset FROM collector_cursors WHERE collector_name=?",
            (collector_name,)
        ).fetchone()
        if row:
            return (row["file_path"], row["byte_offset"])
        return None

    def set_cursor(self, collector_name: str, file_path: str, byte_offset: int) -> None:
        now = datetime.now(timezone.utc).isoformat()
        with self.transaction():
            self.db.execute(
                """
                INSERT INTO collector_cursors (collector_name, file_path, byte_offset, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(collector_name) DO UPDATE SET
                    file_path=excluded.file_path,
                    byte_offset=excluded.byte_offset,
                    updated_at=excluded.updated_at
                """,
                (collector_name, file_path, byte_offset, now)
            )

    def get_health(self, provider_filter: Optional[str] = None) -> Dict[str, Any]:
        """Compute provider health status contract consumed by Track A."""
        now = datetime.now(timezone.utc)
        valid_providers = set(self.config.data.get("quotas", {}).keys()) | {"claude", "codex", "gemini", "copilot"}
        if provider_filter:
            p_low = provider_filter.lower()
            if p_low not in valid_providers:
                return {
                    "status": "HEALTHY",
                    "checked_at": normalize_iso_utc(now.isoformat()),
                    "providers": {}
                }
            providers_to_check = [p_low]
        else:
            providers_to_check = ["claude", "codex", "gemini", "copilot"]
        provider_results: Dict[str, Any] = {}
        overall_status = "HEALTHY"

        for p in providers_to_check:
            quota_cfg = self.config.get_quota(p)
            window_hours = quota_cfg.get("window_hours", 168)
            since_time = normalize_iso_utc((now - timedelta(hours=window_hours)).isoformat())

            # 1. Check recent active 429 / cooldown snapshots
            active_snapshot = self.db.execute(
                """
                SELECT status, reset_at, utilization_pct, source
                FROM quota_snapshots
                WHERE provider=?
                ORDER BY id DESC LIMIT 1
                """,
                (p,)
            ).fetchone()

            p_status = "HEALTHY"
            reset_at_str = None
            if active_snapshot:
                snap_status = active_snapshot["status"]
                snap_reset = active_snapshot["reset_at"]
                if snap_status in ("THROTTLED", "EXHAUSTED"):
                    if snap_reset:
                        try:
                            # Replace trailing 'Z' if present for fromisoformat
                            clean_reset = snap_reset.replace("Z", "+00:00")
                            r_dt = datetime.fromisoformat(clean_reset)
                            if r_dt > now:
                                p_status = snap_status
                                reset_at_str = snap_reset
                        except Exception:
                            p_status = snap_status
                            reset_at_str = snap_reset
                    else:
                        p_status = snap_status

            # 2. Query usage within rolling window
            row = self.db.execute(
                """
                SELECT
                    COALESCE(SUM(input_tokens), 0) AS total_input,
                    COALESCE(SUM(output_tokens), 0) AS total_output,
                    COALESCE(SUM(cache_read_tokens), 0) AS total_cache_read,
                    COALESCE(SUM(cache_write_tokens), 0) AS total_cache_write,
                    COALESCE(SUM(reasoning_tokens), 0) AS total_reasoning,
                    COUNT(*) AS event_count
                FROM usage_events
                WHERE provider=? AND recorded_at >= ?
                """,
                (p, since_time)
            ).fetchone()

            total_tokens = (
                row["total_input"] + row["total_output"] +
                row["total_cache_read"] + row["total_cache_write"]
            )

            # Sum monetary cost as Decimal strings
            cost_rows = self.db.execute(
                "SELECT estimated_cost_usd, premium_requests FROM usage_events WHERE provider=? AND recorded_at >= ?",
                (p, since_time)
            ).fetchall()
            total_cost = sum((money(r["estimated_cost_usd"]) for r in cost_rows), Decimal("0"))
            total_premium = sum((money(r["premium_requests"]) for r in cost_rows), Decimal("0"))

            # Calculate utilization
            utilization_pct = None
            if quota_cfg.get("type") == "rolling_window":
                max_tokens = quota_cfg.get("max_tokens", 10000000)
                util_dec = (Decimal(total_tokens) / Decimal(max_tokens)) * Decimal("100")
                utilization_pct = decimal_str(util_dec, places=2)
                warn_pct = money(quota_cfg.get("warning_threshold_pct", "85.00"))
                exh_pct = money(quota_cfg.get("exhaustion_threshold_pct", "100.00"))

                if p_status == "HEALTHY":
                    if util_dec >= exh_pct:
                        p_status = "EXHAUSTED"
                    elif util_dec >= warn_pct:
                        p_status = "THROTTLED"

            elif quota_cfg.get("type") == "monetary_budget":
                budget_usd = money(quota_cfg.get("budget_usd", "25.00"))
                if p == "copilot":
                    # Monetary budget for Copilot scopes to DeepSeek API overflow
                    api_rows = self.db.execute(
                        "SELECT estimated_cost_usd FROM usage_events WHERE provider=? AND billing_mode='api' AND recorded_at >= ?",
                        (p, since_time)
                    ).fetchall()
                    effective_cost = sum((money(r["estimated_cost_usd"]) for r in api_rows), Decimal("0"))
                else:
                    effective_cost = total_cost

                util_dec = (effective_cost / budget_usd) * Decimal("100") if budget_usd > 0 else Decimal("0")
                utilization_pct = decimal_str(util_dec, places=2)
                warn_pct = money(quota_cfg.get("warning_threshold_pct", "85.00"))
                exh_pct = money(quota_cfg.get("exhaustion_threshold_pct", "100.00"))

                if p_status == "HEALTHY":
                    if effective_cost >= budget_usd or util_dec >= exh_pct:
                        p_status = "EXHAUSTED"
                    elif util_dec >= warn_pct:
                        p_status = "THROTTLED"

            # Rank overall status
            if p_status == "EXHAUSTED":
                overall_status = "EXHAUSTED"
            elif p_status == "THROTTLED" and overall_status != "EXHAUSTED":
                overall_status = "THROTTLED"

            provider_results[p] = {
                "status": p_status,
                "window_hours": window_hours,
                "utilization_pct": utilization_pct,
                "reset_at": reset_at_str,
                "burn": {
                    "input_tokens": row["total_input"],
                    "output_tokens": row["total_output"],
                    "cache_read_tokens": row["total_cache_read"],
                    "cache_write_tokens": row["total_cache_write"],
                    "total_tokens": total_tokens,
                    "premium_requests": decimal_str(total_premium, places=2),
                    "estimated_cost_usd": decimal_str(total_cost, places=6),
                    "event_count": row["event_count"],
                }
            }

        return {
            "status": overall_status,
            "checked_at": now.isoformat(),
            "providers": provider_results,
        }

    def get_report(self, by: str = "provider", since: str = "7d") -> Dict[str, Any]:
        """Aggregate usage events grouped by dimension."""
        now = datetime.now(timezone.utc)
        since_dt = self._parse_since(since, now)
        since_iso = normalize_iso_utc(since_dt.isoformat())

        valid_dims = {
            "provider": "provider",
            "model": "model",
            "issue": "issue_number",
            "pr": "pr_number",
            "agent": "agent_name",
            "run": "harness_run_id"
        }
        dim_col = valid_dims.get(by.lower(), "provider")

        rows = self.db.execute(
            f"""
            SELECT
                COALESCE({dim_col}, 'unknown') AS group_key,
                accuracy,
                input_tokens,
                output_tokens,
                cache_read_tokens,
                cache_write_tokens,
                reasoning_tokens,
                premium_requests,
                estimated_cost_usd
            FROM usage_events
            WHERE recorded_at >= ?
            """,
            (since_iso,)
        ).fetchall()

        groups: Dict[str, Dict[str, Any]] = {}
        grand_total = {
            "events": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "reasoning_tokens": 0,
            "premium_requests": Decimal("0"),
            "estimated_cost_usd": Decimal("0"),
            "accuracy_breakdown": {
                "exact": 0,
                "request_metered": 0,
                "estimated": 0,
                "reserved_estimated": 0,
            }
        }

        for r in rows:
            gk = str(r["group_key"])
            if gk not in groups:
                groups[gk] = {
                    "key": gk,
                    "events": 0,
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                    "reasoning_tokens": 0,
                    "premium_requests": Decimal("0"),
                    "estimated_cost_usd": Decimal("0"),
                    "accuracy_breakdown": {
                        "exact": 0,
                        "request_metered": 0,
                        "estimated": 0,
                        "reserved_estimated": 0,
                    }
                }
            g = groups[gk]
            g["events"] += 1
            g["input_tokens"] += r["input_tokens"]
            g["output_tokens"] += r["output_tokens"]
            g["cache_read_tokens"] += r["cache_read_tokens"]
            g["cache_write_tokens"] += r["cache_write_tokens"]
            g["reasoning_tokens"] += r["reasoning_tokens"]
            g["premium_requests"] += money(r["premium_requests"])
            g["estimated_cost_usd"] += money(r["estimated_cost_usd"])
            acc = r["accuracy"]
            if acc in g["accuracy_breakdown"]:
                g["accuracy_breakdown"][acc] += 1

            grand_total["events"] += 1
            grand_total["input_tokens"] += r["input_tokens"]
            grand_total["output_tokens"] += r["output_tokens"]
            grand_total["cache_read_tokens"] += r["cache_read_tokens"]
            grand_total["cache_write_tokens"] += r["cache_write_tokens"]
            grand_total["reasoning_tokens"] += r["reasoning_tokens"]
            grand_total["premium_requests"] += money(r["premium_requests"])
            grand_total["estimated_cost_usd"] += money(r["estimated_cost_usd"])
            if acc in grand_total["accuracy_breakdown"]:
                grand_total["accuracy_breakdown"][acc] += 1

        # Format groups
        formatted_groups = []
        for gk, g in sorted(groups.items()):
            cache_read = g["cache_read_tokens"]
            input_t = g["input_tokens"]
            total_cache_in = cache_read + input_t
            cache_hit_rate = (
                decimal_str((Decimal(cache_read) / Decimal(total_cache_in)) * Decimal("100"), places=2)
                if total_cache_in > 0 else "0.00"
            )
            formatted_groups.append({
                "key": gk,
                "events": g["events"],
                "input_tokens": g["input_tokens"],
                "output_tokens": g["output_tokens"],
                "cache_read_tokens": g["cache_read_tokens"],
                "cache_write_tokens": g["cache_write_tokens"],
                "reasoning_tokens": g["reasoning_tokens"],
                "total_tokens": input_t + g["output_tokens"] + cache_read + g["cache_write_tokens"],
                "cache_hit_rate_pct": cache_hit_rate,
                "premium_requests": decimal_str(g["premium_requests"], places=2),
                "estimated_cost_usd": decimal_str(g["estimated_cost_usd"], places=6),
                "accuracy_breakdown": g["accuracy_breakdown"],
            })

        total_cache_in = grand_total["cache_read_tokens"] + grand_total["input_tokens"]
        grand_cache_hit_rate = (
            decimal_str((Decimal(grand_total["cache_read_tokens"]) / Decimal(total_cache_in)) * Decimal("100"), places=2)
            if total_cache_in > 0 else "0.00"
        )
        grand_total_tokens = (
            grand_total["input_tokens"] + grand_total["output_tokens"] +
            grand_total["cache_read_tokens"] + grand_total["cache_write_tokens"]
        )

        return {
            "by": by,
            "since": since,
            "since_utc": since_iso,
            "groups": formatted_groups,
            "total": {
                "events": grand_total["events"],
                "input_tokens": grand_total["input_tokens"],
                "output_tokens": grand_total["output_tokens"],
                "cache_read_tokens": grand_total["cache_read_tokens"],
                "cache_write_tokens": grand_total["cache_write_tokens"],
                "reasoning_tokens": grand_total["reasoning_tokens"],
                "total_tokens": grand_total_tokens,
                "cache_hit_rate_pct": grand_cache_hit_rate,
                "premium_requests": decimal_str(grand_total["premium_requests"], places=2),
                "estimated_cost_usd": decimal_str(grand_total["estimated_cost_usd"], places=6),
                "accuracy_breakdown": grand_total["accuracy_breakdown"],
            }
        }

    def _parse_since(self, since_str: str, now: datetime) -> datetime:
        s = since_str.strip().lower()
        if s.endswith("d"):
            days = int(s[:-1])
            return now - timedelta(days=days)
        if s.endswith("h"):
            hours = int(s[:-1])
            return now - timedelta(hours=hours)
        if s.endswith("m"):
            minutes = int(s[:-1])
            return now - timedelta(minutes=minutes)
        try:
            return datetime.fromisoformat(since_str.replace("Z", "+00:00"))
        except Exception:
            return now - timedelta(days=7)
