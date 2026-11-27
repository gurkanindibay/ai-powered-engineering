#!/usr/bin/env python3
"""Cross-Provider Token Consumption Tracker CLI.

Delivers unified visibility across Claude, Codex, Gemini, Copilot (DeepSeek overflow),
and T3 Code child sessions, and exposes the read-only provider_health JSON contract.

Usage:
    python3 scripts/token_tracker.py ingest [--provider all|claude|codex|gemini|copilot|harness] [--json]
    python3 scripts/token_tracker.py record --provider ... --model ... --input N --output N [--event 429 --reset-at ...]
    python3 scripts/token_tracker.py health [--json]
    python3 scripts/token_tracker.py report --by provider|model|issue|pr|agent|run --since 7d [--json]
    python3 scripts/token_tracker.py budget-check --provider ... --model ... [--json]
"""
from __future__ import annotations

import sys
from pathlib import Path

# Ensure repository root is on sys.path
REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.token_tracker.cli import main

if __name__ == "__main__":
    sys.exit(main())
