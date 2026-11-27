"""Collector for durable harness runs.sqlite3 (T3/Docker attempts & correlation)."""
from __future__ import annotations

import json
from pathlib import Path
import sqlite3
from typing import Any, Dict, List, Optional, Tuple

from .base import BaseCollector
from ..ledger import TokenLedger
from ..quotas import decimal_str, money


class HarnessCollector(BaseCollector):
    def __init__(self, ledger: TokenLedger):
        super().__init__(ledger, "harness")

    def collect(self, source_override: Optional[Path] = None) -> Dict[str, Any]:
        runs_db_path = None
        if source_override:
            p = Path(source_override).resolve()
            if p.is_file() and p.name.endswith(".sqlite3"):
                runs_db_path = p
            elif p.is_dir():
                cand = p / "runs.sqlite3"
                if cand.exists():
                    runs_db_path = cand
        if not runs_db_path:
            cand = Path(__file__).resolve().parents[3] / ".engineering-harness" / "runs.sqlite3"
            if cand.exists():
                runs_db_path = cand

        if not runs_db_path or not runs_db_path.exists():
            return {"provider": "harness", "files_scanned": 0, "new_events": 0}

        new_events = 0
        try:
            conn = sqlite3.connect(str(runs_db_path), timeout=10.0)
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()

            # Query attempts and associated run details
            cursor.execute("""
                SELECT
                    a.id AS attempt_id,
                    a.run_id,
                    a.task_id,
                    a.status AS attempt_status,
                    a.lease,
                    a.envelope,
                    a.reservation,
                    a.tokens AS reserved_tokens,
                    r.status AS run_status,
                    r.candidate,
                    r.created AS run_created
                FROM attempts a
                JOIN runs r ON a.run_id = r.id
                ORDER BY a.run_id, a.id
            """)
            attempts = cursor.fetchall()

            for att in attempts:
                attempt_id = att["attempt_id"]
                run_id = att["run_id"]
                source_key = f"t3:{run_id}:{attempt_id}"

                try:
                    envelope = json.loads(att["envelope"])
                except Exception:
                    envelope = {}

                provider = envelope.get("provider", "claude")
                model = envelope.get("model", "claude-sonnet-5-5")
                role = envelope.get("role", att["task_id"])
                candidate = att["candidate"]
                reserved_tokens = int(att["reserved_tokens"] or 0)
                reserved_cost = str(att["reservation"] or "0")

                # Get attempt claim timestamp from events if available
                cursor.execute("""
                    SELECT created FROM events
                    WHERE run_id=? AND body LIKE ?
                    ORDER BY seq ASC LIMIT 1
                """, (run_id, f'%"{attempt_id}"%'))
                ev_row = cursor.fetchone()
                claim_ts = ev_row[0] if ev_row else att["run_created"]

                import datetime
                dt_iso = datetime.datetime.fromtimestamp(claim_ts, tz=datetime.timezone.utc).isoformat()

                # Check if underlying correlated usage exists in ledger
                correlated_rows = self.ledger.db.execute("""
                    SELECT id, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                           reasoning_tokens, estimated_cost_usd
                    FROM usage_events
                    WHERE (harness_attempt_id = ? OR session_id = ?)
                      AND source_event_key != ?
                """, (attempt_id, attempt_id, source_key)).fetchall()

                if correlated_rows:
                    # Correlated: exact usage from underlying session
                    actual_in = sum(r["input_tokens"] for r in correlated_rows)
                    actual_out = sum(r["output_tokens"] for r in correlated_rows)
                    actual_cread = sum(r["cache_read_tokens"] for r in correlated_rows)
                    actual_cwrite = sum(r["cache_write_tokens"] for r in correlated_rows)
                    actual_reas = sum(r["reasoning_tokens"] for r in correlated_rows)
                    actual_cost = sum((money(r["estimated_cost_usd"]) for r in correlated_rows), money("0"))

                    # Update or insert canonical attempt record with exact usage (refunding unused reservation)
                    existing = self.ledger.db.execute(
                        "SELECT id, accuracy FROM usage_events WHERE source_event_key=?", (source_key,)
                    ).fetchone()

                    if existing:
                        with self.ledger.transaction():
                            self.ledger.db.execute("""
                                UPDATE usage_events
                                SET input_tokens=?, output_tokens=?, cache_read_tokens=?,
                                    cache_write_tokens=?, reasoning_tokens=?, estimated_cost_usd=?,
                                    accuracy='exact'
                                WHERE source_event_key=?
                            """, (actual_in, actual_out, actual_cread, actual_cwrite, actual_reas,
                                  decimal_str(actual_cost, places=6), source_key))
                    else:
                        inserted = self.ledger.record_usage_event(
                            source_event_key=source_key,
                            recorded_at=dt_iso,
                            provider=provider,
                            harness="t3",
                            model=model,
                            session_id=attempt_id,
                            harness_run_id=run_id,
                            harness_attempt_id=attempt_id,
                            input_tokens=actual_in,
                            output_tokens=actual_out,
                            cache_read_tokens=actual_cread,
                            cache_write_tokens=actual_cwrite,
                            reasoning_tokens=actual_reas,
                            estimated_cost_usd=decimal_str(actual_cost, places=6),
                            accuracy="exact",
                            billing_mode="subscription",
                        )
                        if inserted:
                            new_events += 1
                else:
                    # Uncorrelated: record baseline reserved estimated ceiling
                    inserted = self.ledger.record_usage_event(
                        source_event_key=source_key,
                        recorded_at=dt_iso,
                        provider=provider,
                        harness="t3",
                        model=model,
                        session_id=attempt_id,
                        harness_run_id=run_id,
                        harness_attempt_id=attempt_id,
                        input_tokens=reserved_tokens,
                        output_tokens=0,
                        estimated_cost_usd=decimal_str(money(reserved_cost), places=6),
                        accuracy="reserved_estimated",
                        billing_mode="subscription",
                    )
                    if inserted:
                        new_events += 1

            conn.close()
            return {"provider": "harness", "files_scanned": 1, "new_events": new_events}
        except Exception:
            return {"provider": "harness", "files_scanned": 0, "new_events": new_events}
