#!/usr/bin/env python3
"""Collect per-layer line/branch coverage and diff-cover changed-lines coverage.

Reads coverage artifacts produced by CI jobs:
- Backend (Rust): `rust-summary.json` (cargo llvm-cov --json --summary-only) and `rust.lcov`
- Frontend (Flutter): `flutter.lcov` or `lcov.info` (flutter test --coverage)
- Harness & Scripts (Python): `python.json` (coverage json) and `python.lcov` / `python.xml`

Optionally runs `diff-cover` against a base git ref to compute changed-lines coverage per layer
and overall. Writes `coverage-summary.json` and `coverage-report.md` (and appends to
`$GITHUB_STEP_SUMMARY` when run standalone without `--no-summary`).

Report-only in phase 2 (exit gate G1); exits 0 even if coverage is below 80%.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

LAYER_SPECS = (
    ("backend", "Backend (Rust)", "cargo-llvm-cov", "apps/development-time/SitePulse/backend"),
    ("flutter", "Frontend (Flutter)", "flutter test", "apps/development-time/SitePulse/flutter"),
    ("python", "Harness & Scripts (Python)", "coverage.py", "apps/development-time/SitePulse"),
)

VALID_LAYERS = {row[0] for row in LAYER_SPECS}


def _pct(covered: int | None, total: int | None) -> float | None:
    if covered is None or total is None or total <= 0:
        return None
    value = 100.0 * covered / total
    return round(value, 1) if math.isfinite(value) else None


def parse_lcov_totals(path: Path) -> dict:
    """Parse line and branch totals from an LCOV tracefile."""
    lines_total = 0
    lines_covered = 0
    branches_total = 0
    branches_covered = 0

    record_lf: int | None = None
    record_lh: int | None = None
    record_da_total = 0
    record_da_hit = 0
    record_brf: int | None = None
    record_brh: int | None = None
    record_brda_total = 0
    record_brda_hit = 0

    def flush_record() -> None:
        nonlocal lines_total, lines_covered, branches_total, branches_covered
        nonlocal record_lf, record_lh, record_da_total, record_da_hit
        nonlocal record_brf, record_brh, record_brda_total, record_brda_hit
        if record_lf is not None and record_lh is not None:
            lines_total += record_lf
            lines_covered += record_lh
        elif record_da_total > 0:
            lines_total += record_da_total
            lines_covered += record_da_hit

        if record_brf is not None and record_brh is not None:
            branches_total += record_brf
            branches_covered += record_brh
        elif record_brda_total > 0:
            branches_total += record_brda_total
            branches_covered += record_brda_hit

        record_lf = record_lh = None
        record_da_total = record_da_hit = 0
        record_brf = record_brh = None
        record_brda_total = record_brda_hit = 0

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line == "end_of_record":
            flush_record()
        elif line.startswith("LF:"):
            record_lf = int(line[3:])
        elif line.startswith("LH:"):
            record_lh = int(line[3:])
        elif line.startswith("DA:"):
            parts = line[3:].split(",")
            if len(parts) >= 2:
                record_da_total += 1
                if int(parts[1]) > 0:
                    record_da_hit += 1
        elif line.startswith("BRF:"):
            record_brf = int(line[4:])
        elif line.startswith("BRH:"):
            record_brh = int(line[4:])
        elif line.startswith("BRDA:"):
            parts = line[5:].split(",")
            if len(parts) >= 4:
                record_brda_total += 1
                if parts[3] not in ("-", "0"):
                    record_brda_hit += 1

    flush_record()
    return {
        "lines_covered": lines_covered if lines_total > 0 else None,
        "lines_total": lines_total,
        "line_pct": _pct(lines_covered, lines_total),
        "branches_covered": branches_covered if branches_total > 0 else None,
        "branches_total": branches_total,
        "branch_pct": _pct(branches_covered, branches_total),
    }


def parse_rust_summary(path: Path) -> dict:
    """Parse `cargo llvm-cov report --json --summary-only` output."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    data = payload.get("data") or []
    totals = data[0].get("totals", {}) if data and isinstance(data[0], dict) else {}
    lines = totals.get("lines") or {}
    branches = totals.get("branches") or {}
    lines_total = int(lines.get("count") or 0)
    lines_covered = int(lines.get("covered") or 0)
    branches_total = int(branches.get("count") or 0)
    branches_covered = int(branches.get("covered") or 0)
    return {
        "lines_covered": lines_covered if lines_total > 0 else None,
        "lines_total": lines_total,
        "line_pct": _pct(lines_covered, lines_total),
        "branches_covered": branches_covered if branches_total > 0 else None,
        "branches_total": branches_total,
        "branch_pct": _pct(branches_covered, branches_total),
    }


def parse_python_json(path: Path) -> dict:
    """Parse `coverage json` output."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    totals = payload.get("totals") or {}
    lines_total = int(totals.get("num_statements") or 0)
    lines_covered = int(totals.get("covered_lines") or 0)
    branches_total = int(totals.get("num_branches") or 0)
    branches_covered = int(totals.get("covered_branches") or 0)
    return {
        "lines_covered": lines_covered if lines_total > 0 else None,
        "lines_total": lines_total,
        "line_pct": _pct(lines_covered, lines_total),
        "branches_covered": branches_covered if branches_total > 0 else None,
        "branches_total": branches_total,
        "branch_pct": _pct(branches_covered, branches_total),
    }


def _normalize_repo_path(raw_path: str, layer_prefix: str) -> str:
    cleaned = raw_path.replace("\\", "/").strip()
    marker = "apps/development-time/SitePulse/"
    if marker in cleaned:
        return cleaned[cleaned.index(marker):]
    if cleaned.startswith("./"):
        cleaned = cleaned[2:]
    layer_rel = layer_prefix.removeprefix(marker)
    if layer_rel and cleaned.startswith(layer_rel + "/"):
        return marker + cleaned
    return f"{layer_prefix}/{cleaned.lstrip('/')}"


def normalize_lcov_file(src: Path, dst: Path, layer_prefix: str) -> None:
    """Rewrite `SF:` entries in an LCOV file to repo-relative paths."""
    out_lines = []
    for line in src.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("SF:"):
            norm = _normalize_repo_path(line[3:], layer_prefix)
            out_lines.append(f"SF:{norm}")
        else:
            out_lines.append(line)
    dst.write_text("\n".join(out_lines) + "\n", encoding="utf-8")


def normalize_cobertura_xml(src: Path, dst: Path, layer_prefix: str) -> None:
    """Rewrite `filename=` attributes in Cobertura XML to repo-relative paths."""
    tree = ET.parse(src)
    root = tree.getroot()
    for cls in root.iter("class"):
        filename = cls.get("filename")
        if filename:
            cls.set("filename", _normalize_repo_path(filename, layer_prefix))
    tree.write(dst, encoding="utf-8", xml_declaration=True)


def run_diff_cover(cov_file: Path, layer_prefix: str, base_ref: str, repo_root: Path,
                   require_tool: bool = False) -> dict:
    """Run `diff-cover` for one layer against `base_ref` and return diff line counts."""
    diff_cover_bin = shutil.which("diff-cover")
    if not diff_cover_bin:
        if require_tool:
            raise RuntimeError("diff-cover is not installed")
        return {"diff_status": "unavailable", "diff_lines_covered": None, "diff_lines_total": 0, "diff_line_pct": None}

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        if cov_file.suffix == ".xml":
            norm_cov = tmp_dir / "coverage.xml"
            normalize_cobertura_xml(cov_file, norm_cov, layer_prefix)
        else:
            norm_cov = tmp_dir / "lcov.info"
            normalize_lcov_file(cov_file, norm_cov, layer_prefix)
        json_out = tmp_dir / "diff-cover.json"
        cmd = [
            diff_cover_bin,
            str(norm_cov),
            f"--compare-branch={base_ref}",
            f"--json-report={json_out}",
        ]
        proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"diff-cover failed ({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}")
        report = json.loads(json_out.read_text(encoding="utf-8"))
        total = int(report.get("total_num_lines") or 0)
        violations = int(report.get("total_num_violations") or 0)
        covered = max(0, total - violations)
        return {
            "diff_status": "collected" if total > 0 else "no-changed-lines",
            "diff_lines_covered": covered if total > 0 else None,
            "diff_lines_total": total,
            "diff_line_pct": _pct(covered, total),
        }


def _find_first(root: Path, names: tuple[str, ...]) -> Path | None:
    if not root.is_dir():
        return None
    for name in names:
        matches = sorted(root.rglob(name))
        if matches:
            return matches[0]
    return None


def collect_coverage(artifacts: Path, base_ref: str | None = None, repo_root: Path | None = None,
                     require_diff_cover: bool = False) -> dict:
    """Collect per-layer coverage and optional diff-cover stats from `artifacts`."""
    layers = []
    total_diff_covered = 0
    total_diff_lines = 0
    any_diff_unavailable = False

    for layer_id, label, tool, prefix in LAYER_SPECS:
        entry: dict = {
            "layer": layer_id,
            "label": label,
            "tool": tool,
            "status": "missing",
            "lines_covered": None,
            "lines_total": 0,
            "line_pct": None,
            "branches_covered": None,
            "branches_total": 0,
            "branch_pct": None,
            "diff_status": "not-run",
            "diff_lines_covered": None,
            "diff_lines_total": 0,
            "diff_line_pct": None,
        }

        diff_input: Path | None = None
        if layer_id == "backend":
            summary_json = _find_first(artifacts, ("rust-summary.json",))
            lcov_file = _find_first(artifacts, ("rust.lcov",))
            if summary_json:
                entry.update(parse_rust_summary(summary_json))
                entry["status"] = "collected"
            elif lcov_file:
                entry.update(parse_lcov_totals(lcov_file))
                entry["status"] = "collected"
            diff_input = lcov_file
        elif layer_id == "flutter":
            lcov_file = _find_first(artifacts, ("flutter.lcov", "lcov.info"))
            if lcov_file:
                entry.update(parse_lcov_totals(lcov_file))
                entry["status"] = "collected"
            diff_input = lcov_file
        elif layer_id == "python":
            py_json = _find_first(artifacts, ("python.json",))
            py_lcov = _find_first(artifacts, ("python.lcov",))
            py_xml = _find_first(artifacts, ("python.xml",))
            if py_json:
                entry.update(parse_python_json(py_json))
                entry["status"] = "collected"
            elif py_lcov:
                entry.update(parse_lcov_totals(py_lcov))
                entry["status"] = "collected"
            diff_input = py_xml or py_lcov

        if base_ref and repo_root and diff_input:
            diff_stats = run_diff_cover(diff_input, prefix, base_ref, repo_root, require_tool=require_diff_cover)
            entry.update(diff_stats)
            if diff_stats["diff_status"] == "unavailable":
                any_diff_unavailable = True
            if diff_stats["diff_lines_total"] > 0 and diff_stats["diff_lines_covered"] is not None:
                total_diff_lines += diff_stats["diff_lines_total"]
                total_diff_covered += diff_stats["diff_lines_covered"]

        layers.append(entry)

    changed_lines = {
        "lines_covered": total_diff_covered if total_diff_lines > 0 else None,
        "lines_total": total_diff_lines,
        "line_pct": _pct(total_diff_covered, total_diff_lines),
        "threshold_pct": 80.0,
        "mode": "report-only",
        "status": ("unavailable" if any_diff_unavailable
                   else ("collected" if total_diff_lines > 0 else ("no-changed-lines" if base_ref else "not-run"))),
    }

    return {
        "schema": 1,
        "base_ref": base_ref or "",
        "layers": layers,
        "changed_lines": changed_lines,
    }


def _fmt_cov(pct: float | None, covered: int | None, total: int | None) -> str:
    if pct is None or covered is None or not total:
        return "n/a"
    return f"{pct:.1f}% ({covered}/{total})"


def render_markdown(coverage: dict) -> str:
    """Render coverage summary as a GitHub-flavored Markdown section."""
    base_ref = coverage.get("base_ref") or "base"
    lines = [
        "## Code coverage (report-only)",
        "",
        f"| Layer | Tool | Line coverage | Branch coverage | Changed lines (vs `{base_ref}`) |",
        "|---|---|---|---|---|",
    ]
    for row in coverage.get("layers", []):
        line_str = _fmt_cov(row.get("line_pct"), row.get("lines_covered"), row.get("lines_total"))
        branch_str = _fmt_cov(row.get("branch_pct"), row.get("branches_covered"), row.get("branches_total"))
        diff_str = _fmt_cov(row.get("diff_line_pct"), row.get("diff_lines_covered"), row.get("diff_lines_total"))
        if row.get("status") == "missing":
            line_str = "missing"
            branch_str = "missing"
        lines.append(f"| {row['label']} | {row['tool']} | {line_str} | {branch_str} | {diff_str} |")

    changed = coverage.get("changed_lines") or {}
    total_diff = _fmt_cov(changed.get("line_pct"), changed.get("lines_covered"), changed.get("lines_total"))
    lines.append(f"| **Changed lines total** | diff-cover | — | — | **{total_diff}** |")
    lines.append("")
    lines.append(
        "_Report-only in phase 2 (exit gate G1); 80% changed-lines gate on "
        "`backend/src/{domain,services}` and `flutter/lib` follows in phase 4._"
    )
    return "\n".join(lines) + "\n"


def build_coverage(artifacts: Path, out: Path, base_ref: str | None = None,
                   repo_root: Path | None = None, require_diff_cover: bool = False) -> dict:
    """Collect coverage, write JSON and Markdown into `out`, and return the summary dict."""
    out.mkdir(parents=True, exist_ok=True)
    summary = collect_coverage(artifacts, base_ref=base_ref, repo_root=repo_root,
                               require_diff_cover=require_diff_cover)
    (out / "coverage-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    (out / "coverage-report.md").write_text(render_markdown(summary), encoding="utf-8")
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--artifacts", type=Path, required=True, help="directory containing per-layer coverage artifacts")
    parser.add_argument("--out", type=Path, required=True, help="directory to write coverage-summary.json and coverage-report.md")
    parser.add_argument("--base-ref", help="git ref to compare against with diff-cover (e.g. origin/master)")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[4],
                        help="repository root for git diff / diff-cover")
    parser.add_argument("--require-diff-cover", action="store_true", help="fail if diff-cover is not installed")
    parser.add_argument("--no-summary", action="store_true", help="do not append to $GITHUB_STEP_SUMMARY")
    parser.add_argument("--json", action="store_true", help="print coverage summary as JSON")
    args = parser.parse_args(argv)

    summary = build_coverage(args.artifacts, args.out, base_ref=args.base_ref,
                             repo_root=args.repo_root, require_diff_cover=args.require_diff_cover)
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target and not args.no_summary:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write("\n" + (args.out / "coverage-report.md").read_text(encoding="utf-8"))
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"Coverage report written to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
