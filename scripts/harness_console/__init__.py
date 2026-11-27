"""Unified Local Control Console & Desktop MCP Adapter (Phase 5)."""
from __future__ import annotations

from .cli import main
from .store import ConsoleError, ConsoleStore, default_console_db_path

__all__ = ["ConsoleError", "ConsoleStore", "default_console_db_path", "main"]
