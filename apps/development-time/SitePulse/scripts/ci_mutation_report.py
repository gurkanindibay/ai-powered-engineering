#!/usr/bin/env python3
"""Aggregates layer mutation reports into a consolidated mutation test report for CI."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List


def aggregate_reports(json_files: List[Path]) -> Dict[str, Any]:
    """Combines individual layer mutation payloads into a single report."""
    all_results: List[Dict[str, Any]] = []
    seen_ids: set[str] = set()

    for path in sorted(json_files):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            results = data.get("results", [])
            for r in results:
                if r["id"] not in seen_ids:
                    seen_ids.add(r["id"])
                    all_results.append(r)
        except Exception as e:
            print(f"Warning: could not read {path}: {e}", file=sys.stderr)

    total_killed = sum(1 for r in all_results if r["outcome"] == "killed")
    total_survived = sum(1 for r in all_results if r["outcome"] == "survived")
    total_unviable = sum(1 for r in all_results if r["outcome"] == "unviable")
    total_timeout = sum(1 for r in all_results if r["outcome"] == "timeout")
    total_skipped = sum(1 for r in all_results if r["outcome"] == "skipped")
    total_unscored = sum(1 for r in all_results if r["outcome"] == "unscored")

    scored = total_killed + total_survived
    score = (total_killed / scored) if scored > 0 else None

    # Group by layer
    by_layer: Dict[str, Dict[str, int]] = {}
    for r in all_results:
        layer_dict = by_layer.setdefault(r["layer"], {})
        layer_dict[r["outcome"]] = layer_dict.get(r["outcome"], 0) + 1

    survivors = [r["id"] for r in all_results if r["outcome"] == "survived"]
    unscored = [r["id"] for r in all_results if r["outcome"] == "unscored"]
    baseline_failures: Dict[tuple[str, str, str], set[str]] = {}
    for result in all_results:
        for suite in result.get("suites", []):
            baseline_status = suite.get("baseline_status")
            if baseline_status and baseline_status not in ("passed", "skipped"):
                key = (str(suite.get("suite", "unknown")), str(baseline_status),
                       str(suite.get("baseline_tail") or suite.get("tail") or ""))
                baseline_failures.setdefault(key, set()).add(str(result["id"]))

    return {
        "summary": {
            "total_scenarios": len(all_results),
            "killed": total_killed,
            "survived": total_survived,
            "unviable": total_unviable,
            "timeout": total_timeout,
            "skipped": total_skipped,
            "unscored": total_unscored,
            "score": score,
            "survivors": survivors,
            "unscored_ids": unscored,
            "baseline_failures": [
                {"suite": suite, "status": status, "diagnostics": diagnostics, "affected_ids": sorted(ids)}
                for (suite, status, diagnostics), ids in sorted(baseline_failures.items())
            ],
            "by_layer": by_layer,
        },
        "results": all_results,
    }


def format_markdown(aggregated: Dict[str, Any]) -> str:
    """Formats aggregated results into a GitHub-friendly markdown summary."""
    summary = aggregated["summary"]
    score_str = f"{summary['score']:.0%}" if summary["score"] is not None else "n/a"

    lines = [
        "## SitePulse Mutation Testing Summary",
        "",
        f"**Mutation Score**: **{score_str}** ({summary['killed']} killed / {summary['killed'] + summary['survived']} scored)",
        "",
        "| Layer | Total | Killed | Survived | Unscored | Unviable | Timeout | Skipped | Score |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for layer in ("rust", "flutter", "python", "db"):
        counts = summary["by_layer"].get(layer, {})
        k = counts.get("killed", 0)
        s = counts.get("survived", 0)
        u = counts.get("unviable", 0)
        t = counts.get("timeout", 0)
        sk = counts.get("skipped", 0)
        us = counts.get("unscored", 0)
        tot = k + s + us + u + t + sk
        denom = k + s
        l_score = f"{k / denom:.0%}" if denom > 0 else "n/a"
        lines.append(f"| {layer.capitalize()} | {tot} | {k} | {s} | {us} | {u} | {t} | {sk} | **{l_score}** |")

    lines.extend([
        "",
        f"**Totals**: {summary['total_scenarios']} scenarios · {summary['killed']} killed · {summary['survived']} survived · {summary['unscored']} unscored · {summary['unviable']} unviable · {summary['timeout']} timeout · {summary['skipped']} skipped",
        "",
    ])

    killed_records = [r for r in aggregated["results"] if r.get("outcome") == "killed" and r.get("killed_test")]
    if killed_records:
        lines.extend(["### Detected test cases", "", "| ID | Suite | Failing test or assertion |", "| :--- | :--- | :--- |"])
        for result in killed_records:
            lines.append(
                f"| `{result.get('id', '-')}` | {result.get('killed_by', '-')} | "
                f"{str(result.get('killed_test', '-')).replace('|', '\\|')} |"
            )
        lines.append("")

    if summary["survivors"]:
        lines.extend([
            "### ⚠️ Surviving Mutants",
            "",
            "The following deliberate bugs survived without failing tests:",
            "",
            "| ID | Layer | Area | Operator | Risk |",
            "| :--- | :--- | :--- | :--- | :--- |",
        ])
        survivor_records = [r for r in aggregated["results"] if r.get("outcome") == "survived"]
        for r in survivor_records:
            layer = r.get("layer", "-")
            area = r.get("area", "-")
            op = r.get("operator", "-")
            risk = r.get("risk", "-")
            lines.append(f"| `{r.get('id', '-')}` | {layer} | {area} | {op} | {risk} |")
        lines.append("")

    if summary["baseline_failures"]:
        lines.extend([
            "### ⚠️ Failed clean baselines",
            "",
            "Clean baseline failures are excluded from scoring; this run fails strict verification even if another suite detected the mutant:",
            "",
            "| Failed baseline suite | Affected mutants | Diagnostics |",
            "| :--- | :--- | :--- |",
        ])
        for failure in summary["baseline_failures"]:
            diagnostic = str(failure["diagnostics"] or "No output was captured.").replace("|", "\\|").replace("\n", "<br>")
            ids = ", ".join(f"`{scenario_id}`" for scenario_id in failure["affected_ids"])
            lines.append(f"| {failure['suite']} ({failure['status']}) | {ids} | {diagnostic} |")
        lines.append("")

    return "\n".join(lines)


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports-dir", type=Path, required=True, help="Directory containing layer JSON files")
    parser.add_argument("--out", type=Path, help="Directory to write aggregated report files")
    parser.add_argument("--markdown", type=Path, help="Write markdown summary here")
    parser.add_argument("--json", action="store_true", help="Print aggregated JSON to stdout")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with 1 if any mutant survived, was unscored, timed out, or failed to compile",
    )
    args = parser.parse_args(argv)

    json_files = [p for p in args.reports_dir.rglob("*.json") if p.name != "mutation_summary.json"]
    if not json_files:
        print(f"No JSON reports found in {args.reports_dir}", file=sys.stderr)
        return 1

    aggregated = aggregate_reports(json_files)
    md_content = format_markdown(aggregated)

    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(md_content, encoding="utf-8")

    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "mutation_summary.json").write_text(json.dumps(aggregated, indent=2) + "\n", encoding="utf-8")
        (args.out / "mutation_summary.md").write_text(md_content, encoding="utf-8")

    if args.json:
        print(json.dumps(aggregated, indent=2))
    else:
        print(md_content)

    if args.strict:
        has_survivors = bool(aggregated["summary"]["survivors"])
        has_unviable = aggregated["summary"]["unviable"] > 0
        has_timeout = aggregated["summary"]["timeout"] > 0
        has_unscored = aggregated["summary"]["unscored"] > 0
        has_baseline_failures = bool(aggregated["summary"]["baseline_failures"])
        if has_survivors or has_unviable or has_timeout or has_unscored or has_baseline_failures:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
