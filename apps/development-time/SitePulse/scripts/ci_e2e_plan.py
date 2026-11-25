#!/usr/bin/env python3
"""Select SitePulse browser tests for the current GitHub Actions lane."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
TRACEABILITY = ROOT / "scripts" / "feature_traceability.py"
LINKED_SUITE_IGNORE = "--ignore=tests/test_linked_backend_suites.py"


def selection_plan(event: str, ref: str, selection: dict[str, Any]) -> dict[str, Any]:
    """Return the safe lane and pytest marker for a GitHub event and impact-map result."""
    if event == "pull_request":
        mode = str(selection.get("mode", "full"))
        if mode == "none":
            return {"run_e2e": False, "mode": "none", "marker": "", "pytest_addopts": LINKED_SUITE_IGNORE,
                    "epics": [], "reason": "no SitePulse behavior paths changed"}
        if mode == "full":
            return {"run_e2e": True, "mode": "full", "marker": "", "pytest_addopts": LINKED_SUITE_IGNORE,
                    "epics": [], "reason": "impact map requires the full suite"}
        epics = sorted(set(selection.get("epics", [])))
        markers = ["smoke", "core", *(f"epic_{epic[5:]}" for epic in epics)]
        marker = " or ".join(markers)
        return {"run_e2e": True, "mode": "targeted", "marker": marker,
                "pytest_addopts": f"{LINKED_SUITE_IGNORE} -m '{marker}'", "epics": epics,
                "reason": "smoke/core plus impact-map epics"}

    if event == "push" and ref not in {"refs/heads/master", "master"}:
        return {"run_e2e": False, "mode": "none", "marker": "", "pytest_addopts": LINKED_SUITE_IGNORE,
                "epics": [], "reason": "push is not to master"}
    return {"run_e2e": True, "mode": "full", "marker": "", "pytest_addopts": LINKED_SUITE_IGNORE,
            "epics": [], "reason": "full suite lane"}


def affected_selection() -> dict[str, Any]:
    process = subprocess.run([sys.executable, str(TRACEABILITY), "--json", "affected"], cwd=ROOT,
                             capture_output=True, text=True, check=False)
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or process.stdout.strip() or "feature traceability failed")
    try:
        result = json.loads(process.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("feature traceability returned invalid JSON") from exc
    if not isinstance(result, dict) or result.get("mode") not in {"none", "targeted", "full"}:
        raise RuntimeError("feature traceability returned an invalid affected selection")
    return result


def write_github_output(path: Path, plan: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as output:
        output.write(f"run_e2e={str(plan['run_e2e']).lower()}\n")
        output.write(f"mode={plan['mode']}\n")
        output.write(f"marker={plan['marker']}\n")
        output.write(f"pytest_addopts={plan['pytest_addopts']}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch"),
                        help="GitHub event name (defaults to GITHUB_EVENT_NAME)")
    parser.add_argument("--ref", default=os.environ.get("GITHUB_REF", "refs/heads/master"),
                        help="Git ref (defaults to GITHUB_REF)")
    parser.add_argument("--json", action="store_true", help="print the lane selection as JSON")
    parser.add_argument("--github-output", type=Path, default=Path(os.environ["GITHUB_OUTPUT"])
                        if os.environ.get("GITHUB_OUTPUT") else None,
                        help="append outputs for a later GitHub Actions step")
    args = parser.parse_args(argv)
    try:
        selection = affected_selection() if args.event == "pull_request" else {"mode": "full", "epics": []}
        plan = selection_plan(args.event, args.ref, selection)
    except RuntimeError as exc:
        print(f"E2E lane planning failed: {exc}", file=sys.stderr)
        return 2
    if args.github_output:
        write_github_output(args.github_output, plan)
    print(json.dumps(plan, indent=2) if args.json else
          f"E2E lane: {plan['mode']} ({'run' if plan['run_e2e'] else 'skip'}); {plan['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
