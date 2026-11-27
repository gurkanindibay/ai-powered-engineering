"""Collector for local GitHub Copilot CLI logs and premium request multipliers."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from .base import BaseCollector
from ..ledger import TokenLedger
from ..quotas import decimal_str


class CopilotCollector(BaseCollector):
    def __init__(self, ledger: TokenLedger):
        super().__init__(ledger, "copilot")

    def collect(self, source_override: Optional[Path] = None) -> Dict[str, Any]:
        targets: List[Path] = []
        if source_override:
            src = Path(source_override).resolve()
            if src.exists():
                targets.append(src)
        else:
            default_paths = [
                Path.home() / ".config" / "github-copilot",
                Path.home() / ".copilot" / "sessions",
            ]
            for p in default_paths:
                if p.exists():
                    targets.append(p)

        files_scanned = 0
        new_events = 0

        for target_dir in targets:
            log_files = list(target_dir.rglob("*.json*")) + list(target_dir.rglob("*.log"))
            for file_path in log_files:
                files_scanned += 1
                str_path = str(file_path)
                offset = self.get_cursor(str_path)

                try:
                    file_size = file_path.stat().st_size
                    if offset > file_size:
                        offset = 0

                    if file_path.suffix == ".json" and offset == 0:
                        try:
                            with open(file_path, "r", encoding="utf-8", errors="replace") as jf:
                                whole_data = json.load(jf)
                            items = whole_data if isinstance(whole_data, list) else ([whole_data] if isinstance(whole_data, dict) else [])
                            for idx, data in enumerate(items):
                                if isinstance(data, dict):
                                    event_id = str(data.get("id") or data.get("event_id") or f"doc_{idx}")
                                    session_id = str(data.get("session_id") or file_path.stem)
                                    source_key = f"copilot:{session_id}:{event_id}"
                                    timestamp = str(data.get("timestamp") or data.get("created_at") or "").strip()
                                    if not timestamp:
                                        timestamp = datetime.now(timezone.utc).isoformat()
                                    model = str(data.get("model") or "gpt-4o")
                                    is_deepseek = "deepseek" in model.lower()
                                    billing_mode = "api" if is_deepseek else "subscription"
                                    multiplier = self.ledger.config.get_copilot_multiplier(model)
                                    count_requests = int(data.get("request_count", 1))
                                    premium_reqs = multiplier * count_requests
                                    input_tokens = int(data.get("input_tokens") or data.get("prompt_tokens") or 0)
                                    output_tokens = int(data.get("output_tokens") or data.get("completion_tokens") or 0)
                                    accuracy = "request_metered" if (input_tokens == 0 and output_tokens == 0) else "exact"
                                    if input_tokens == 0 and "prompt_length" in data:
                                        input_tokens = int(data["prompt_length"]) // 4
                                        accuracy = "request_metered"
                                    inserted = self.ledger.record_usage_event(
                                        source_event_key=source_key,
                                        recorded_at=timestamp,
                                        provider="copilot",
                                        harness="copilot_cli",
                                        model=model,
                                        session_id=session_id,
                                        input_tokens=input_tokens,
                                        output_tokens=output_tokens,
                                        premium_requests=decimal_str(premium_reqs, places=2),
                                        accuracy=accuracy,
                                        billing_mode=billing_mode,
                                    )
                                    if inserted:
                                        new_events += 1
                            self.set_cursor(str_path, file_size)
                            continue
                        except json.JSONDecodeError:
                            pass

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

                            if not isinstance(data, dict):
                                continue

                            event_id = str(data.get("id") or data.get("event_id") or f"line_{line_no}_{line_start}")
                            session_id = str(data.get("session_id") or file_path.stem)
                            source_key = f"copilot:{session_id}:{event_id}"
                            timestamp = str(data.get("timestamp") or data.get("created_at") or "").strip()
                            if not timestamp:
                                timestamp = datetime.now(timezone.utc).isoformat()

                            model = str(data.get("model") or "gpt-4o")

                            is_deepseek = "deepseek" in model.lower()
                            billing_mode = "api" if is_deepseek else "subscription"

                            multiplier = self.ledger.config.get_copilot_multiplier(model)
                            count_requests = int(data.get("request_count", 1))
                            premium_reqs = multiplier * count_requests

                            input_tokens = int(data.get("input_tokens") or data.get("prompt_tokens") or 0)
                            output_tokens = int(data.get("output_tokens") or data.get("completion_tokens") or 0)
                            accuracy = "request_metered" if (input_tokens == 0 and output_tokens == 0) else "exact"

                            if input_tokens == 0 and "prompt_length" in data:
                                input_tokens = int(data["prompt_length"]) // 4
                                accuracy = "request_metered"

                            inserted = self.ledger.record_usage_event(
                                source_event_key=source_key,
                                recorded_at=timestamp,
                                provider="copilot",
                                harness="copilot_cli",
                                model=model,
                                session_id=session_id,
                                input_tokens=input_tokens,
                                output_tokens=output_tokens,
                                premium_requests=decimal_str(premium_reqs, places=2),
                                accuracy=accuracy,
                                billing_mode=billing_mode,
                            )
                            if inserted:
                                new_events += 1

                        self.set_cursor(str_path, last_valid_offset)
                except OSError:
                    continue

        return {"provider": "copilot", "files_scanned": files_scanned, "new_events": new_events}
