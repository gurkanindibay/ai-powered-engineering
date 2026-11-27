"""Collector for Claude Code JSONL logs (~/.claude/projects/*/*.jsonl)."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Dict, Optional

from .base import BaseCollector
from ..ledger import TokenLedger


class ClaudeCollector(BaseCollector):
    def __init__(self, ledger: TokenLedger):
        super().__init__(ledger, "claude")

    def collect(self, source_override: Optional[Path] = None) -> Dict[str, Any]:
        base_dir = Path(source_override or (Path.home() / ".claude" / "projects")).resolve()
        new_events = 0
        files_scanned = 0

        if not base_dir.exists():
            return {"provider": "claude", "files_scanned": 0, "new_events": 0}

        jsonl_files = list(base_dir.rglob("*.jsonl"))
        for file_path in jsonl_files:
            files_scanned += 1
            str_path = str(file_path)
            offset = self.get_cursor(str_path)

            try:
                file_size = file_path.stat().st_size
                if offset > file_size:
                    # File was truncated or rotated
                    offset = 0

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
                            # Unterminated trailing line (partially written); stop and resume later
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

                        msg = data.get("message")
                        if not isinstance(msg, dict):
                            continue
                        usage = msg.get("usage")
                        if not isinstance(usage, dict):
                            continue

                        session_id = str(data.get("sessionId") or file_path.stem)
                        # Key on message.id (or requestId) to avoid duplicate counting of multi-block turns
                        msg_id = msg.get("id") or data.get("requestId")
                        if msg_id:
                            source_key = f"claude:{session_id}:{msg_id}"
                        else:
                            uuid_val = str(data.get("uuid") or f"line_{line_no}_{line_start}")
                            source_key = f"claude:{session_id}:{uuid_val}"

                        timestamp = str(data.get("timestamp") or "").strip()
                        if not timestamp:
                            timestamp = datetime.now(timezone.utc).isoformat()

                        model = str(msg.get("model") or "claude-sonnet-5-5")

                        input_tokens = int(usage.get("input_tokens") or 0)
                        output_tokens = int(usage.get("output_tokens") or 0)
                        cache_read = int(usage.get("cache_read_input_tokens") or 0)
                        cache_write = int(usage.get("cache_creation_input_tokens") or 0)
                        output_details = usage.get("output_tokens_details") or {}
                        reasoning = int(output_details.get("thinking_tokens") or 0)

                        inserted = self.ledger.record_usage_event(
                            source_event_key=source_key,
                            recorded_at=timestamp,
                            provider="claude",
                            harness="claude_code",
                            model=model,
                            session_id=session_id,
                            input_tokens=input_tokens,
                            output_tokens=output_tokens,
                            cache_read_tokens=cache_read,
                            cache_write_tokens=cache_write,
                            reasoning_tokens=reasoning,
                            accuracy="exact",
                            billing_mode="subscription",
                        )
                        if inserted:
                            new_events += 1

                    self.set_cursor(str_path, last_valid_offset)
            except OSError:
                continue

        return {"provider": "claude", "files_scanned": files_scanned, "new_events": new_events}
