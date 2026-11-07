#!/usr/bin/env python3
"""SitePulse full verification run: every gate, real tools, no shortcuts.

Runs, in order: harness self-tests, Rust build, clippy (-D warnings), Rust tests,
the shared financial fixtures (Rust + Dart), Flutter analyze, Flutter tests,
the persistence lint, the testId lint, the schema integrity gate, the API
system check and the browser end-to-end suite (gui-e2e).

* A missing toolchain (cargo, flutter, psql/docker) fails its gate.
* Results are reported exactly as the tools returned them; nothing is printed
  as passed unless the tool exited successfully.
* Nothing in the repository is modified (task status changes only through
  `harness_cli.py verify --record` in CI).
* `--skip-db` skips the gates that need PostgreSQL (schema-integrity, api-system,
  gui-e2e); `--skip-gui` skips only gui-e2e (it also needs Chrome and takes about
  15 minutes). Skipped gates are reported as SKIPPED, never as passed.

Usage:
    python3 scripts/run_tests.py [--skip-db] [--skip-gui] [--only gate1,gate2] [--json]

Exit code 0 only when every gate that ran passed.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.loop.verification_gates import GATES, run_gate  # noqa: E402

ORDER = [
    "harness-selftest", "rust-build", "rust-clippy", "rust-test", "money-fixtures",
    "flutter-analyze", "flutter-test", "persistence-lint", "testid-lint", "schema-integrity", "api-system",
    "gui-e2e",
]
DB_GATES = {"schema-integrity", "api-system", "gui-e2e"}
GUI_GATES = {"gui-e2e"}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--skip-db", action="store_true", help="Skip gates that need PostgreSQL (reported as SKIPPED)")
    parser.add_argument("--skip-gui", action="store_true",
                        help="Skip the browser end-to-end suite (reported as SKIPPED)")
    parser.add_argument("--only", help="Comma-separated gate names to run")
    parser.add_argument("--json", action="store_true", help="Print a JSON report")
    args = parser.parse_args(argv)

    selected = [g.strip() for g in args.only.split(",")] if args.only else ORDER
    unknown = [g for g in selected if g not in GATES]
    if unknown:
        print(f"Unknown gates: {unknown}. Known: {sorted(GATES)}", file=sys.stderr)
        return 2

    report = []
    for name in selected:
        reason = "--skip-db" if args.skip_db and name in DB_GATES else (
            "--skip-gui" if args.skip_gui and name in GUI_GATES else None)
        if reason:
            report.append({"name": name, "status": "SKIPPED", "duration_s": 0.0, "diagnostics": [reason]})
            if not args.json:
                print(f"SKIPPED  {name} ({reason})")
            continue
        if not args.json:
            print(f"RUNNING  {name} ...", flush=True)
        res = run_gate(name, ROOT)
        report.append({"name": name, "status": "PASSED" if res.passed else "FAILED",
                       "duration_s": round(res.duration_s, 1), "command": res.command, "diagnostics": res.diagnostics})
        if not args.json:
            print(f"{'PASSED' if res.passed else 'FAILED'}   {name} ({res.duration_s:.1f}s)")
            if not res.passed:
                for d in res.diagnostics[:40]:
                    print(f"           {d}")

    failed = [r["name"] for r in report if r["status"] == "FAILED"]
    skipped = [r["name"] for r in report if r["status"] == "SKIPPED"]
    if args.json:
        print(json.dumps({"passed": not failed, "failed": failed, "skipped": skipped, "gates": report}, indent=2))
    else:
        print("=" * 72)
        if failed:
            print(f"FAILED: {', '.join(failed)}")
        else:
            print(f"All {len(report) - len(skipped)} gate(s) that ran passed." + (f" Skipped: {', '.join(skipped)}." if skipped else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
