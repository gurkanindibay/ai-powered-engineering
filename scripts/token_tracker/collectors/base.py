"""Base collector class for telemetry ingestion."""
from __future__ import annotations

import abc
from pathlib import Path
from typing import Any, Dict, Optional

from ..ledger import TokenLedger


class BaseCollector(abc.ABC):
    def __init__(self, ledger: TokenLedger, name: str):
        self.ledger = ledger
        self.name = name

    @abc.abstractmethod
    def collect(self, source_override: Optional[Path] = None) -> Dict[str, Any]:
        """Ingest usage metadata from telemetry sources into the ledger."""
        raise NotImplementedError

    def get_cursor(self, file_path: str) -> int:
        cur = self.ledger.get_cursor(f"{self.name}:{file_path}")
        return cur[1] if cur else 0

    def set_cursor(self, file_path: str, offset: int) -> None:
        self.ledger.set_cursor(f"{self.name}:{file_path}", file_path, offset)
