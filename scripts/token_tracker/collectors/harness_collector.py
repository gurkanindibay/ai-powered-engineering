"""Collector for durable harness runs.sqlite3 (T3/Docker attempts & correlation)."""
from __future__ import annotations

from datetime import datetime, timezone
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

                target = envelope.get("target") if isinstance(envelope.get("target"), dict) else {}
                raw_prov = target.get("provider") or envelope.get("provider", "claude")
                raw_prov_str = str(raw_prov).lower()
                if raw_prov_str.startswith("claude"):
                    provider = "claude"
                elif "codex" in raw_prov_str:
                    provider = "codex"
                elif "gemini" in raw_prov_str:
                    provider = "gemini"
                elif "copilot" in raw_prov_str:
                    provider = "copilot"
                else:
                    provider = raw_prov_str

                model = target.get("model") or envelope.get("model", "claude-sonnet-5-5")
                transport = str(envelope.get("transport") or "t3")
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
                dt_iso = datetime.fromtimestamp(claim_ts, tz=timezone.utc).isoformat()

                # Discover candidate session IDs from project directories
                cand_session_ids = set()
                if candidate:
                    try:
                        cand_path = Path(candidate).resolve()
                        cand_slug = "-" + str(cand_path).strip("/").replace("/", "-")
                        claude_dir = Path.home() / ".claude" / "projects" / cand_slug
                        if claude_dir.exists():
                            for f in claude_dir.glob("*.jsonl"):
                                cand_session_ids.add(f.stem)
                    except Exception:
                        pass

                # Check if underlying child sessions already exist in ledger
                where_clauses = ["(harness_attempt_id = ? OR session_id = ?)"]
                params = [attempt_id, attempt_id]
                if cand_session_ids:
                    placeholders = ",".join("?" for _ in cand_session_ids)
                    where_clauses.append(f"(session_id IN ({placeholders}) AND recorded_at >= ?)")
                    params.extend(list(cand_session_ids))
                    params.append(dt_iso)

                query = f"""
                    SELECT id, input_tokens, output_tokens
                    FROM usage_events
                    WHERE ({" OR ".join(where_clauses)})
                      AND source_event_key != ?
                """
                params.append(source_key)
                correlated_rows = self.ledger.db.execute(query, tuple(params)).fetchall()

                if correlated_rows:
                    # Child events already record exact usage in usage_events.
                    # Remove any placeholder reservation row to avoid double counting,
                    # and ensure child rows are tagged with harness_run_id and harness_attempt_id.
                    row_ids = [r["id"] for r in correlated_rows]
                    placeholders = ",".join("?" for _ in row_ids)
                    with self.ledger.transaction():
                        self.ledger.db.execute("DELETE FROM usage_events WHERE source_event_key=?", (source_key,))
                        self.ledger.db.execute(
                            f"""
                            UPDATE usage_events
                            SET harness_run_id=?, harness_attempt_id=?
                            WHERE id IN ({placeholders})
                            """,
                            (run_id, attempt_id, *row_ids)
                        )
                else:
                    # Uncorrelated: record baseline reserved estimated ceiling
                    inserted = self.ledger.record_usage_event(
                        source_event_key=source_key,
                        recorded_at=dt_iso,
                        provider=provider,
                        harness=transport,
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
        except Exception as exc:
            return {"provider": "harness", "files_scanned": 0, "new_events": new_events, "error": str(exc)}
