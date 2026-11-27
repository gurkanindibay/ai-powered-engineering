"""Collector for Gemini CLI telemetry (~/.gemini/tmp/) and Antigravity transcripts."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from .base import BaseCollector
from ..ledger import TokenLedger


class GeminiCollector(BaseCollector):
    def __init__(self, ledger: TokenLedger):
        super().__init__(ledger, "gemini")

    def collect(self, source_override: Optional[Path] = None) -> Dict[str, Any]:
        targets: List[Path] = []
        if source_override:
            src = Path(source_override).resolve()
            if src.exists():
                targets.append(src)
        else:
            gemini_tmp = Path.home() / ".gemini" / "tmp"
            if gemini_tmp.exists():
                targets.append(gemini_tmp)
            antigravity_brain = Path.home() / ".gemini" / "antigravity" / "brain"
            if antigravity_brain.exists():
                targets.append(antigravity_brain)

        files_scanned = 0
        new_events = 0

        for target_dir in targets:
            jsonl_files = list(target_dir.rglob("*.jsonl"))
            for file_path in jsonl_files:
                files_scanned += 1
                str_path = str(file_path)
                offset = self.get_cursor(str_path)

                try:
                    file_size = file_path.stat().st_size
                    if offset > file_size:
                        offset = 0

                    session_id = file_path.stem
                    parts = file_path.parts
                    if "brain" in parts:
                        idx = parts.index("brain")
                        if idx + 1 < len(parts):
                            session_id = parts[idx + 1]

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

                            has_exact = "input_tokens" in data or "usageMetadata" in data or "usage" in data
                            step_idx = data.get("step_index", line_no)
                            timestamp = str(data.get("created_at") or data.get("timestamp") or "").strip()
                            if not timestamp:
                                timestamp = datetime.now(timezone.utc).isoformat()

                            model = str(data.get("model") or "gemini-3-8-flash")
                            source_key = f"gemini:{session_id}:{step_idx}"

                            if has_exact:
                                usage = data.get("usageMetadata") or data.get("usage") or {}
                                input_tokens = int(data.get("input_tokens") or usage.get("promptTokenCount") or usage.get("input_tokens") or 0)
                                output_tokens = int(data.get("output_tokens") or usage.get("candidatesTokenCount") or usage.get("output_tokens") or 0)
                                cache_read = int(data.get("cache_read_tokens") or usage.get("cachedContentTokenCount") or 0)

                                inserted = self.ledger.record_usage_event(
                                    source_event_key=source_key,
                                    recorded_at=timestamp,
                                    provider="gemini",
                                    harness="antigravity" if "brain" in parts else "gemini_cli",
                                    model=model,
                                    session_id=session_id,
                                    input_tokens=input_tokens,
                                    output_tokens=output_tokens,
                                    cache_read_tokens=cache_read,
                                    accuracy="exact",
                                    billing_mode="subscription",
                                )
                                if inserted:
                                    new_events += 1

                            elif data.get("source") in ("MODEL", "PLANNER_RESPONSE") or data.get("type") in ("PLANNER_RESPONSE", "MODEL"):
                                content = str(data.get("content") or "")
                                thinking = str(data.get("thinking") or "")
                                est_output = (len(content) + len(thinking)) // 4
                                est_input = 1000

                                inserted = self.ledger.record_usage_event(
                                    source_event_key=source_key,
                                    recorded_at=timestamp,
                                    provider="gemini",
                                    harness="antigravity" if "brain" in parts else "gemini_cli",
                                    model=model,
                                    session_id=session_id,
                                    input_tokens=est_input,
                                    output_tokens=est_output,
                                    accuracy="estimated",
                                    billing_mode="subscription",
                                )
                                if inserted:
                                    new_events += 1

                        self.set_cursor(str_path, last_valid_offset)
                except OSError:
                    continue

        return {"provider": "gemini", "files_scanned": files_scanned, "new_events": new_events}
