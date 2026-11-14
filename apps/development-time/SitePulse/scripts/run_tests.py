#!/usr/bin/env python3
"""SitePulse verification runner: whole platform, area-specific, or change-driven.

Supports:
1. Full platform verification run (default, every gate in strict dependency order).
2. Area-specific testing (--area finance,auth,residents,ui,db,core):
   Executes targeted unit/widget/integration tests and static linters for a specific functional area.
3. Change-driven selective testing (--changed):
   Inspects git status/diff, automatically detects which functional areas were modified,
   and runs the exact tests and gates needed to cover the changes made.
4. Area catalogue inspection (--list-areas, --plan).

Usage:
    python3 scripts/run_tests.py [--skip-db] [--skip-gui] [--only gate1,gate2] [--json]
    python3 scripts/run_tests.py --area finance [--skip-db]
    python3 scripts/run_tests.py --area auth,residents
    python3 scripts/run_tests.py --changed [--base HEAD~1] [--skip-db]
    python3 scripts/run_tests.py --list-areas
    python3 scripts/run_tests.py --area finance --plan

Exit code 0 only when every test and gate that ran passed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Set

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.loop.verification_gates import (  # noqa: E402
    GATES,
    CommandSpec,
    GateResult,
    run_command,
    run_gate,
)

ORDER = [
    "harness-selftest",
    "rust-build",
    "rust-clippy",
    "rust-test",
    "money-fixtures",
    "flutter-analyze",
    "flutter-test",
    "persistence-lint",
    "rust-standards-lint",
    "tenant-lint",
    "lock-lint",
    "testid-lint",
    "feature-traceability",
    "ui-style-lint",
    "flutter-reuse",
    "logging-standards-lint",
    "schema-integrity",
    "rust-db-test",
    "api-system",
    "gui-e2e",
]
DB_GATES = {"schema-integrity", "rust-db-test", "api-system", "gui-e2e"}
GUI_GATES = {"gui-e2e"}


@dataclass
class AreaSpec:
    name: str
    title: str
    description: str
    gates: List[str]
    rust_tests: List[str] = field(default_factory=list)
    rust_lib_tests: List[str] = field(default_factory=list)
    flutter_tags: List[str] = field(default_factory=list)
    flutter_files: List[str] = field(default_factory=list)
    e2e_markers: List[str] = field(default_factory=list)
    path_patterns: List[str] = field(default_factory=list)


AREAS: Dict[str, AreaSpec] = {
    "finance": AreaSpec(
        name="finance",
        title="Financial Ledger, Dues & Payments",
        description="Dues calculations, KMK penalty, tariffs, bank reconciliation, payment tracking, and capital apportionment.",
        gates=["money-fixtures", "persistence-lint", "rust-standards-lint"],
        rust_tests=[
            "financial_fixtures",
            "capital_apportionment_tests",
            "payment_compliance_tests",
            "payment_ledger_hardening_tests",
            "payments_phase2_tests",
        ],
        rust_lib_tests=[
            "apportionment::",
            "collection_metrics::",
            "double_entry::",
            "installments::",
            "payer_match::",
            "heat_share::",
            "iban::",
            "dues_calculation_service::",
            "dues_ledger::",
            "virtual_iban_service::",
            "bank_statement_parser::",
            "mt940_engine::",
            "reconciliation_service::",
        ],
        flutter_tags=["finance"],

        flutter_files=[
            "test/calculate_dues_usecase_test.dart",
            "test/financial_fixture_test.dart",
            "test/bank_file_parser_test.dart",
            "test/bank_statement_reconciliation_test.dart",
            "test/capital_expenditure_and_dues_e2e_test.dart",
            "test/capital_projects_view_test.dart",
            "test/dues_management_view_test.dart",
            "test/house_type_tariff_and_validation_test.dart",
            "test/payment_tracking_and_aging_test.dart",
            "test/payments_phase2_models_test.dart",
        ],
        e2e_markers=["area_finance"],
        path_patterns=[
            r"backend/src/domain/apportion\.rs",
            r"backend/src/domain/payer_match\.rs",
            r"backend/src/services/.*(?:aidat|payment|reconciliation|bank|capital|plan|budget|tariff|dispute|virtual_iban|receipt|autopay|collections|dunning|heat_share|operating_budget|accounting)",
            r"backend/src/db/finance_.*",
            r"backend/tests/.*(?:financial|payment|capital)",
            r"flutter/lib/ui/(?:dues|reconciliation|capital|payments)/",
            r"flutter/lib/models/.*(?:manager|payments)",
            r"flutter/lib/domain/usecases/calculate_dues",
            r"flutter/test/.*(?:bank|calculate|capital|dues|financial|payment)",
            r"harness/fixtures/financial_cases\.json",
        ],
    ),
    "auth": AreaSpec(
        name="auth",
        title="Identity, Authentication & Multi-Tenancy",
        description="Multi-tenant site provisioning, user credentials, JWT minting, RBAC permissions, and session security.",
        gates=["rust-standards-lint", "api-system"],
        rust_tests=[
            "aaa_security_tests",
            "api_security_tests",
        ],
        rust_lib_tests=[
            "auth::",
        ],
        flutter_tags=["auth"],
        flutter_files=[
            "test/session_security_test.dart",
        ],
        e2e_markers=["area_auth"],
        path_patterns=[
            r"backend/src/auth\.rs",
            r"backend/src/domain/password\.rs",
            r"backend/src/services/.*(?:auth|tenant|role|saas)",
            r"backend/tests/.*(?:security|auth)",
            r"flutter/lib/ui/(?:auth|saas)/",
            r"flutter/lib/ui/login_screen\.dart",
            r"flutter/test/session_security_test\.dart",
        ],
    ),
    "residents": AreaSpec(
        name="residents",
        title="Resident Directory, Units & Occupancy",
        description="Resident directory, unit administration, occupancy changes (dual ledger), and invitation workflows.",
        gates=["rust-standards-lint", "persistence-lint"],
        rust_tests=[
            "shared_rules_tests",
            "person_security_tests",
            "person_records_tests",
        ],
        rust_lib_tests=[
            "account_activation_service::",
            "person_record_service::",
            "person_import_service::",
            "person_directory_service::",
            "joint_liability::",
            "assembly_vote::",
            "dunning::",
            "kvkk::",
        ],
        flutter_tags=["residents"],
        flutter_files=[
            "test/home_owner_directory_and_edit_test.dart",
            "test/owners_residents_module_test.dart",
            "test/occupancy_lifecycle_and_dual_ledger_test.dart",
            "test/house_type_tariff_and_validation_test.dart",
        ],
        e2e_markers=["area_residents"],
        path_patterns=[
            r"backend/src/services/.*(?:site_admin|registration|invitation|occupancy|lease)",
            r"backend/tests/shared_rules_tests\.rs",
            r"flutter/lib/ui/(?:residents|home_owner_directory|invitation)/",
            r"flutter/test/.*(?:home_owner|owners_residents|occupancy)",
        ],
    ),
    "ui": AreaSpec(
        name="ui",
        title="Design System & UI Components",
        description="Papara-inspired design tokens, Material 3 components, UI styling, navigation shell, and theme consistency.",
        gates=["ui-style-lint", "testid-lint", "flutter-reuse", "flutter-analyze"],
        rust_tests=[],
        rust_lib_tests=[],
        flutter_tags=["ui"],
        flutter_files=[
            "test/design_system_test.dart",
            "test/reusable_components_test.dart",
            "test/ux_shell_and_navigation_test.dart",
            "test/zero_data_guidance_test.dart",
            "test/widget_test.dart",
            "test/dashboard_controller_test.dart",
        ],
        e2e_markers=["area_ui"],
        path_patterns=[
            r"flutter/lib/ui/design_system/",
            r"flutter/lib/ui/components/",
            r"flutter/lib/ui/theme/",
            r"flutter/lib/ui/shell/",
            r"flutter/lib/ui/.*\.dart",
            r"flutter/test/.*(?:design|reusable|ux_shell|zero_data|widget)",
            r"scripts/ui_style_.*",
            r"scripts/flutter_reuse_.*",
            r"scripts/testid_.*",
        ],
    ),
    "db": AreaSpec(
        name="db",
        title="Database Architecture & Schema Invariants",
        description="PostgreSQL relational schema, SQL migrations, decimal precision invariants, and memory persistence.",
        gates=["schema-integrity", "persistence-lint"],
        rust_tests=[
            "architecture_flaws_regression_tests",
        ],
        rust_lib_tests=[
            "migrations::",
        ],
        flutter_tags=[],
        flutter_files=[],
        e2e_markers=["area_db"],
        path_patterns=[
            r"backend/db/",
            r"backend/src/db\.rs",
            r"backend/src/migrations\.rs",
            r"backend/src/models/",
            r"scripts/schema_integrity_check\.py",
            r"scripts/memory_persistence_lint\.py",
            r"scripts/db_verify\.py",
        ],
    ),
    "core": AreaSpec(
        name="core",
        title="Core Infrastructure & Error Management",
        description="Axum HTTP routing, standardized error handling, request observability, self-tests, and system checks.",
        gates=["harness-selftest", "rust-build", "rust-clippy", "flutter-analyze", "api-system"],
        rust_tests=[
            "error_management_tests",
            "integration_tests",
        ],
        rust_lib_tests=[
            "error::",
            "email::",
            "fingerprint::",
            "tax_id::",
            "text::",
        ],
        flutter_tags=["core"],

        flutter_files=[
            "test/standardized_error_management_test.dart",
            "test/e2e_quality_verification_test.dart",
            "test/dashboard_controller_test.dart",
        ],
        e2e_markers=["area_core"],
        path_patterns=[
            r"backend/src/errors\.rs",
            r"backend/src/handlers/",
            r"backend/src/main\.rs",
            r"backend/src/app\.rs",
            r"backend/src/lib\.rs",
            r"flutter/lib/core/",
            r"flutter/lib/services/",
            r"harness/",
            r"scripts/run_tests\.py",
        ],
    ),
}


# --summary: one line per gate, capped failure diagnostics, no command echo for
# passing gates. Keeps agent context small when the runner is driven by an LLM.
SUMMARY_DIAGNOSTIC_LINES = 15
SUMMARY = False


def announce(name: str, is_json: bool) -> None:
    if not is_json and not SUMMARY:
        print(f"RUNNING  {name} ...", flush=True)


def record(report: List[Dict[str, object]], name: str, res, is_json: bool) -> None:
    """Appends a gate result to the report and prints its status line."""
    status = "PASSED" if res.passed else "FAILED"
    limit = SUMMARY_DIAGNOSTIC_LINES if SUMMARY else 40
    entry: Dict[str, object] = {"name": name, "status": status, "duration_s": round(res.duration_s, 1)}
    if not (SUMMARY and res.passed):
        entry["command"] = res.command
        entry["diagnostics"] = res.diagnostics[:limit] if SUMMARY else res.diagnostics
    report.append(entry)
    if not is_json:
        print(f"{status:<8} {name} ({res.duration_s:.1f}s)")
        if not res.passed:
            for d in res.diagnostics[:limit]:
                print(f"           {d}")
            if len(res.diagnostics) > limit:
                print(f"           ... {len(res.diagnostics) - limit} more line(s); rerun with --only {name} for all")


def dump_json(payload: object) -> None:
    print(json.dumps(payload, separators=(",", ":")) if SUMMARY else json.dumps(payload, indent=2))


def detect_changed_areas(base: Optional[str] = None) -> List[str]:
    """Detects modified files using git and matches them against area path patterns."""
    repo_root = ROOT
    try:
        git_root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            cwd=ROOT,
            check=True,
        ).stdout.strip()
        repo_root = Path(git_root)
    except Exception:
        pass

    changed_files: Set[str] = set()

    # 1. Staged and unstaged working tree changes
    try:
        proc = subprocess.run(
            ["git", "status", "--porcelain"],
            capture_output=True,
            text=True,
            cwd=repo_root,
            check=True,
        )
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # status format: XY <path> or XY <path1> -> <path2>
            parts = line.split(maxsplit=1)
            if len(parts) == 2:
                path = parts[1]
                if " -> " in path:
                    path = path.split(" -> ")[1]
                changed_files.add(path.strip('"'))
    except Exception as e:
        print(f"Warning: git status failed: {e}", file=sys.stderr)

    # 2. Diff against base if specified or if working tree clean
    diff_targets = []
    if base:
        diff_targets.append(base)
    elif not changed_files:
        diff_targets.extend(["HEAD~1", "origin/master...HEAD"])

    for target in diff_targets:
        try:
            proc = subprocess.run(
                ["git", "diff", "--name-only", target],
                capture_output=True,
                text=True,
                cwd=repo_root,
            )
            if proc.returncode == 0:
                for line in proc.stdout.splitlines():
                    if line.strip():
                        changed_files.add(line.strip())
                if changed_files:
                    break
        except Exception:
            continue

    if not changed_files:
        return []

    # Normalize paths relative to SitePulse ROOT
    sitepulse_rel_prefix = "apps/development-time/SitePulse/"
    matched_areas: Set[str] = set()

    print(f"\n[git change-detection] Detected {len(changed_files)} changed file(s){'' if SUMMARY else ':'}")
    for f in sorted(changed_files):
        if not SUMMARY:
            print(f"  • {f}")
        norm = f
        if norm.startswith(sitepulse_rel_prefix):
            norm = norm[len(sitepulse_rel_prefix):]

        for area_name, area in AREAS.items():
            for pat in area.path_patterns:
                if re.search(pat, norm) or re.search(pat, f):
                    matched_areas.add(area_name)
                    break

    selected = sorted(matched_areas)
    if selected:
        print(f"[git change-detection] Mapped to functional area(s): {', '.join(selected)}\n")
    else:
        print("[git change-detection] No domain-specific area matched; falling back to core.\n")
        selected = ["core"]
    return selected


def print_areas_catalogue() -> None:
    """Prints a structured table of all functional areas and their tests."""
    print("=" * 80)
    print(f"{'Area':<12} | {'Title':<30} | Description & Test Assets")
    print("-" * 80)
    for name, a in AREAS.items():
        print(f"{name:<12} | {a.title:<30} | {a.description}")
        print(f"{'':<12} | {'':<30} | Gates: {', '.join(a.gates) if a.gates else 'none'}")
        if a.rust_tests or a.rust_lib_tests:
            all_rust = [f"--test {t}" for t in a.rust_tests] + [f"--lib {u}" for u in a.rust_lib_tests]
            print(f"{'':<12} | {'':<30} | Rust: {', '.join(all_rust)}")
        if a.flutter_tags or a.flutter_files:
            flt_info = [f"tag:{t}" for t in a.flutter_tags] + [Path(f).name for f in a.flutter_files[:3]]
            if len(a.flutter_files) > 3:
                flt_info.append(f"+{len(a.flutter_files) - 3} more")
            print(f"{'':<12} | {'':<30} | Flutter: {', '.join(flt_info)}")
        print("-" * 80)
    print("=" * 80)


def build_area_execution_plan(area_names: List[str], skip_db: bool = False, skip_gui: bool = False) -> Dict[str, object]:
    """Computes the list of gates, targeted Rust tests, and Flutter commands for chosen areas."""
    selected_areas = [AREAS[a] for a in area_names if a in AREAS]
    gates_set: Set[str] = set()
    rust_test_targets: Set[str] = set()
    rust_lib_targets: Set[str] = set()
    flutter_tags: Set[str] = set()
    flutter_files: Set[str] = set()

    for a in selected_areas:
        gates_set.update(a.gates)
        rust_test_targets.update(a.rust_tests)
        rust_lib_targets.update(a.rust_lib_tests)
        flutter_tags.update(a.flutter_tags)
        flutter_files.update(a.flutter_files)

    ordered_gates = [g for g in ORDER if g in gates_set and g not in ("rust-test", "flutter-test")]

    return {
        "areas": [a.name for a in selected_areas],
        "gates": ordered_gates,
        "rust_tests": sorted(rust_test_targets),
        "rust_lib_tests": sorted(rust_lib_targets),
        "flutter_tags": sorted(flutter_tags),
        "flutter_files": sorted(flutter_files),
        "skip_db": skip_db,
        "skip_gui": skip_gui,
    }


def execute_area_plan(plan: Dict[str, object], root: Path, is_json: bool = False) -> List[Dict[str, object]]:
    """Executes gates and targeted test suites according to the area plan."""
    report: List[Dict[str, object]] = []

    # 1. Run area-specific static and integration gates
    for name in plan["gates"]:
        reason = "--skip-db" if plan["skip_db"] and name in DB_GATES else (
            "--skip-gui" if plan["skip_gui"] and name in GUI_GATES else None
        )
        if reason:
            report.append({"name": name, "status": "SKIPPED", "duration_s": 0.0, "diagnostics": [reason]})
            if not is_json:
                print(f"SKIPPED  {name} ({reason})")
            continue

        announce(name, is_json)
        res = run_gate(name, root)
        record(report, name, res, is_json)

    # 2. Run targeted Rust tests for selected areas
    rust_tests = plan["rust_tests"]
    rust_lib = plan["rust_lib_tests"]
    if rust_tests:
        cmd = ["cargo", "test", "--locked"]
        for t in rust_tests:
            cmd.extend(["--test", t])
        gate_name = f"rust-area-integration [{', '.join(rust_tests)}]"
        announce(gate_name, is_json)
        res = run_command(gate_name, CommandSpec(cmd, "backend", 600), root)
        record(report, gate_name, res, is_json)

    if rust_lib:
        filter_pattern = "|".join(rust_lib)
        cmd = ["cargo", "test", "--locked", "--lib", "--", filter_pattern]
        gate_name = f"rust-area-unit [{', '.join(rust_lib[:3])}{'...' if len(rust_lib) > 3 else ''}]"

        announce(gate_name, is_json)
        res = run_command(gate_name, CommandSpec(cmd, "backend", 600), root)
        record(report, gate_name, res, is_json)

    # 3. Run targeted Flutter tests using tags or files
    flutter_tags = plan["flutter_tags"]
    if flutter_tags:
        tag_expr = " || ".join(flutter_tags)
        gate_name = f"flutter-area-test [tags: {tag_expr}]"
        cmd = ["flutter", "test", "-t", tag_expr]
        announce(gate_name, is_json)
        res = run_command(gate_name, CommandSpec(cmd, "flutter", 600), root)
        record(report, gate_name, res, is_json)

    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--from-dev-container",
        action="store_true",
        help="Load database connection settings from the running local development PostgreSQL container",
    )
    parser.add_argument("--skip-db", action="store_true", help="Skip gates that need PostgreSQL (reported as SKIPPED)")
    parser.add_argument(
        "--skip-gui", action="store_true", help="Skip the browser end-to-end suite (reported as SKIPPED)"
    )
    parser.add_argument("--only", help="Comma-separated gate names to run")
    parser.add_argument(
        "--area",
        help="Comma-separated functional area names (finance, auth, residents, ui, db, core, all)",
    )
    parser.add_argument(
        "--changed",
        action="store_true",
        help="Auto-detect changed files via git status/diff and run tests covering the changes",
    )
    parser.add_argument(
        "--base",
        help="Base commit or branch to compare against for --changed (defaults to working tree + HEAD)",
    )
    parser.add_argument(
        "--list-areas",
        action="store_true",
        help="List all functional areas, their scope, and their mapped test suites",
    )
    parser.add_argument(
        "--plan",
        action="store_true",
        help="Print the planned gates and commands for the selected area without running them",
    )
    parser.add_argument("--json", action="store_true", help="Print a JSON report")
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Compact output for agents: one line per gate, at most 15 diagnostic lines per failure",
    )
    args = parser.parse_args(argv)
    global SUMMARY
    SUMMARY = args.summary
    if args.list_areas:
        print_areas_catalogue()
        return 0

    env_file = ROOT / "backend" / ".env"
    if "DB_PASS" not in os.environ and env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

    if args.from_dev_container:
        try:
            container = os.environ.get("SITEPULSE_PG_CONTAINER", "sitepulse-postgres")
            result = subprocess.run(
                ["docker", "inspect", container], capture_output=True, text=True, timeout=15, check=True
            )
            configuration = json.loads(result.stdout)[0]
            variables = dict(value.split("=", 1) for value in configuration["Config"]["Env"] if "=" in value)
            os.environ["DB_PASS"] = variables["POSTGRES_PASSWORD"]
            os.environ["DB_USER"] = variables.get("POSTGRES_USER", "sitepulse_user")
            os.environ["DB_HOST"] = "127.0.0.1"
            os.environ["DB_PORT"] = configuration["NetworkSettings"]["Ports"]["5432/tcp"][0]["HostPort"]
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError):
            print("Unable to load local development database settings; use DB_PASS explicitly.", file=sys.stderr)
            return 2

    # Determine execution mode: Area/Change-driven vs Standard Gates
    selected_areas: List[str] = []
    if args.changed:
        selected_areas = detect_changed_areas(base=args.base)
        if not selected_areas:
            print("No changes detected in working tree or diff; nothing to test.")
            return 0
    elif args.area:
        raw_areas = [a.strip() for a in args.area.split(",")]
        if "all" in raw_areas:
            selected_areas = list(AREAS.keys())
        else:
            invalid_areas = [a for a in raw_areas if a not in AREAS]
            if invalid_areas:
                print(f"Unknown area(s): {invalid_areas}. Available areas: {sorted(AREAS)}", file=sys.stderr)
                return 2
            selected_areas = raw_areas

    # Area Execution Mode
    if selected_areas:
        plan = build_area_execution_plan(selected_areas, skip_db=args.skip_db, skip_gui=args.skip_gui)
        if args.plan:
            if args.json:
                print(json.dumps(plan, indent=2))
            else:
                print("=" * 72)
                print(f"Execution Plan for Area(s): {', '.join(selected_areas)}")
                print("=" * 72)
                print(f"Gates:         {', '.join(plan['gates'])}")
                print(f"Rust Tests:    {', '.join(plan['rust_tests']) if plan['rust_tests'] else 'none'}")
                print(f"Rust Lib:      {', '.join(plan['rust_lib_tests']) if plan['rust_lib_tests'] else 'none'}")
                print(f"Flutter Tags:  {', '.join(plan['flutter_tags']) if plan['flutter_tags'] else 'none'}")
                print(f"Flutter Files: {len(plan['flutter_files'])} test files")
                print("=" * 72)
            return 0

        report = execute_area_plan(plan, ROOT, is_json=args.json)
        failed = [r["name"] for r in report if r["status"] == "FAILED"]
        skipped = [r["name"] for r in report if r["status"] == "SKIPPED"]
        if args.json:
            dump_json({"passed": not failed, "failed": failed, "skipped": skipped, "gates": report})
        else:
            print("=" * 72)
            if failed:
                print(f"FAILED: {', '.join(failed)}")
            else:
                total_ran = len(report) - len(skipped)
                print(
                    f"All {total_ran} area test gate(s) that ran passed for [{', '.join(selected_areas)}]."
                    + (f" Skipped: {', '.join(skipped)}." if skipped else "")
                )
        return 1 if failed else 0

    # Standard Gate Execution Mode (backward compatible)
    selected = [g.strip() for g in args.only.split(",")] if args.only else ORDER
    unknown = [g for g in selected if g not in GATES]
    if unknown:
        print(f"Unknown gates: {unknown}. Known: {sorted(GATES)}", file=sys.stderr)
        return 2

    report = []
    for name in selected:
        reason = "--skip-db" if args.skip_db and name in DB_GATES else (
            "--skip-gui" if args.skip_gui and name in GUI_GATES else None
        )
        if reason:
            report.append({"name": name, "status": "SKIPPED", "duration_s": 0.0, "diagnostics": [reason]})
            if not args.json:
                print(f"SKIPPED  {name} ({reason})")
            continue
        announce(name, args.json)
        res = run_gate(name, ROOT)
        record(report, name, res, args.json)

    failed = [r["name"] for r in report if r["status"] == "FAILED"]
    skipped = [r["name"] for r in report if r["status"] == "SKIPPED"]
    if args.json:
        dump_json({"passed": not failed, "failed": failed, "skipped": skipped, "gates": report})
    else:
        print("=" * 72)
        if failed:
            print(f"FAILED: {', '.join(failed)}")
        else:
            print(
                f"All {len(report) - len(skipped)} gate(s) that ran passed."
                + (f" Skipped: {', '.join(skipped)}." if skipped else "")
            )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
