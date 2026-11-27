"""Collector for Codex rollout JSONL logs (~/.codex/sessions/YYYY/MM/DD/*.jsonl)."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Dict, Optional

from .base import BaseCollector
from ..ledger import TokenLedger


class CodexCollector(BaseCollector):
    def __init__(self, ledger: TokenLedger):
        super().__init__(ledger, "codex")

    def collect(self, source_override: Optional[Path] = None) -> Dict[str, Any]:
        base_dir = Path(source_override or (Path.home() / ".codex" / "sessions")).resolve()
        new_events = 0
        files_scanned = 0

        if not base_dir.exists():
            return {"provider": "codex", "files_scanned": 0, "new_events": 0}

        jsonl_files = list(base_dir.rglob("*.jsonl"))
        for file_path in jsonl_files:
            files_scanned += 1
            str_path = str(file_path)
            offset = self.get_cursor(str_path)

            try:
                file_size = file_path.stat().st_size
                if offset > file_size:
                    offset = 0

                current_model = "gpt-6-2-sol"
                session_id = file_path.stem

                last_valid_offset = offset
                with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                    f.seek(offset)
                    line_no = 0
                    while True:
                        line_start = f.tell()
                        line = f.readline()
                        if not line:
                            break
                        if not line.endswith("\n"):
                            # Unterminated line; stop here and resume on next run
                            f.seek(line_start)
                            break
                        last_valid_offset = f.tell()
                        line_no += 1
                        line_str = line.strip()
                        if not line_str:
                            continue

                        try:
                            data = json.loads(line_str)
                        except json.JSONDecodeError:
                            continue

                        event_type = data.get("type")
                        payload = data.get("payload") if isinstance(data.get("payload"), dict) else {}

                        if event_type in ("session_meta", "turn_context"):
                            if "model" in payload:
                                current_model = payload["model"]
                            if "session_id" in payload:
                                session_id = payload["session_id"]
                            continue

                        if event_type == "token_usage_record":
                            usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
                            sess = payload.get("session_id") or session_id
                            resp_id = payload.get("response_id") or payload.get("turn_id") or f"line_{line_no}"
                            ordinal = data.get("ordinal", line_no)
                            source_key = f"codex:{sess}:{resp_id}:{ordinal}"
                            timestamp = str(data.get("timestamp") or "").strip()
                            if not timestamp:
                                timestamp = datetime.now(timezone.utc).isoformat()

                            input_tokens = int(usage.get("input_tokens") or 0)
                            cache_read = int(usage.get("cached_input_tokens") or 0)
                            output_tokens = int(usage.get("output_tokens") or 0)
                            reasoning = int(usage.get("reasoning_output_tokens") or 0)

                            inserted = self.ledger.record_usage_event(
                                source_event_key=source_key,
                                recorded_at=timestamp,
                                provider="codex",
                                harness="codex_cli",
                                model=current_model,
                                session_id=sess,
                                input_tokens=input_tokens,
                                output_tokens=output_tokens,
                                cache_read_tokens=cache_read,
                                reasoning_tokens=reasoning,
                                accuracy="exact",
                                billing_mode="subscription",
                            )
                            if inserted:
                                new_events += 1

                        elif event_type == "event_msg" and payload.get("type") == "token_count":
                            info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
                            rate_limits = info.get("rate_limits")
                            if isinstance(rate_limits, dict) and "utilization_pct" in rate_limits:
                                obs = str(data.get("timestamp") or "").strip() or datetime.now(timezone.utc).isoformat()
                                self.ledger.record_quota_snapshot(
                                    provider="codex",
                                    model_family=current_model,
                                    status="HEALTHY" if float(rate_limits.get("utilization_pct", 0)) < 85 else "THROTTLED",
                                    utilization_pct=str(rate_limits["utilization_pct"]),
                                    reset_at=rate_limits.get("reset_at"),
                                    source="codex_rollout",
                                    observed_at=obs,
                                )

                    self.set_cursor(str_path, last_valid_offset)
            except OSError:
                continue

        return {"provider": "codex", "files_scanned": files_scanned, "new_events": new_events}
