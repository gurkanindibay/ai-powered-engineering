#!/usr/bin/env python3
"""Unified Local Control Console (Web + CLI) for Phase 5.

Usage:
    python3 scripts/harness_console.py serve --port 9096
    python3 scripts/harness_console.py status --json
    python3 scripts/harness_console.py tail --issue 550 --lines 40
    python3 scripts/harness_console.py timeline --issue 550 --json
    python3 scripts/harness_console.py pause --issue 550 --json
    python3 scripts/harness_console.py steer --issue 550 --note "Keep Decimal precision" --json
    python3 scripts/harness_console.py handover --issue 550 --to codex --json
    python3 scripts/harness_console.py set-budget --provider copilot-deepseek --usd 30.00 --json
    python3 scripts/harness_console.py pickups --json
"""
from __future__ import annotations

from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.harness_console.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
