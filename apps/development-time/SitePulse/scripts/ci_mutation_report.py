#!/usr/bin/env python3
"""Validate and aggregate the four mutation-test shard reports."""
from __future__ import annotations

import argparse
import json
import sys
import tomllib
from pathlib import Path
from typing import Any, Dict, Iterable, List


SITEPULSE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOGUE = SITEPULSE_ROOT / "harness" / "mutation" / "scenarios.toml"
SHARD_FILES = {
    "python": "mutation_python.json",
    "flutter": "mutation_flutter.json",
    "rust": "mutation_rust.json",
    "db": "mutation_db.json",
}
EXPECTED_SHARDS = {f"mutation-shard-{layer}" for layer in SHARD_FILES}
OUTCOMES = {"killed", "survived", "unviable", "timeout", "skipped", "unscored"}
SUITE_STATUSES = {"passed", "failed", "unviable", "timeout", "skipped", "unscored", "not-run"}
BASELINE_STATUSES = {"passed", "failed", "unviable", "timeout", "skipped", "unscored"}
LAYERS = ("rust", "flutter", "python", "db")


def load_expected_scenarios(catalogue: Path) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Load the canonical IDs and required suites from the checked-in catalogue."""
    diagnostics: list[str] = []
    try:
        payload = tomllib.loads(catalogue.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as error:
        return {}, [f"could not read expected scenario catalogue {catalogue}: {error}"]

    raw_scenarios = payload.get("scenario")
    if not isinstance(raw_scenarios, list):
        return {}, [f"expected scenario catalogue {catalogue} has no scenario list"]

    expected: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(raw_scenarios):
        if not isinstance(row, dict):
            diagnostics.append(f"catalogue scenario at index {index} is not an object")
            continue
        scenario_id = row.get("id")
        layer = row.get("layer")
        suites = row.get("suites")
        if not isinstance(scenario_id, str) or not scenario_id:
            diagnostics.append(f"catalogue scenario at index {index} has no valid ID")
            continue
        if scenario_id in expected:
            diagnostics.append(f"catalogue contains duplicate scenario ID {scenario_id}")
            continue
        if not isinstance(layer, str) or layer not in SHARD_FILES:
            diagnostics.append(f"catalogue scenario {scenario_id} has unexpected layer {layer!r}")
            continue
        if not isinstance(suites, list) or not suites or any(not isinstance(item, str) or not item for item in suites):
            diagnostics.append(f"catalogue scenario {scenario_id} has no valid required-suite list")
            continue
        if len(set(suites)) != len(suites):
            diagnostics.append(f"catalogue scenario {scenario_id} has duplicate required suites")
            continue
        expected[scenario_id] = {
            "layer": layer,
            "risk": row.get("risk", "unknown"),
            "suites": list(suites),
        }
    return expected, diagnostics


def _safe_text(value: object) -> str:
    """Keep runner diagnostics in one Markdown table cell."""
    return str(value or "").replace("|", "\\|").replace("\r", "").replace("\n", "<br>")


def _validate_suite_evidence(
    result: dict[str, Any], expected_suites: list[str], diagnostics: list[str]
) -> bool:
    """Return whether every catalogue-required suite has a well-formed evidence row."""
    scenario_id = str(result["id"])
    rows = result.get("suites")
    if not isinstance(rows, list):
        diagnostics.append(f"{scenario_id}: missing required suite evidence list")
        return False

    suite_rows: dict[str, dict[str, Any]] = {}
    valid = True
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("suite"), str) or not row["suite"]:
            diagnostics.append(f"{scenario_id}: malformed required-suite evidence row")
            valid = False
            continue
        suite_name = row["suite"]
        if suite_name in suite_rows:
            diagnostics.append(f"{scenario_id}: duplicate suite evidence for {suite_name}")
            valid = False
            continue
        suite_rows[suite_name] = row
        if not isinstance(row.get("status"), str) or row["status"] not in SUITE_STATUSES:
            diagnostics.append(f"{scenario_id}: {suite_name} has invalid suite status {row.get('status')!r}")
            valid = False
        baseline_status = row.get("baseline_status")
        if not isinstance(baseline_status, str) or baseline_status not in BASELINE_STATUSES:
            diagnostics.append(f"{scenario_id}: {suite_name} is missing valid clean-baseline evidence")
            valid = False

    expected_set = set(expected_suites)
    present_set = set(suite_rows)
    for suite_name in sorted(expected_set - present_set):
        diagnostics.append(f"{scenario_id}: missing required-suite evidence for {suite_name}")
        valid = False
    for suite_name in sorted(present_set - expected_set):
        diagnostics.append(f"{scenario_id}: unexpected suite evidence for {suite_name}")
        valid = False

    if result.get("outcome") == "killed":
        killed_by = result.get("killed_by")
        if killed_by not in expected_set:
            diagnostics.append(f"{scenario_id}: killed result has no valid detecting-suite identity")
            valid = False
        elif suite_rows.get(killed_by, {}).get("status") != "failed":
            diagnostics.append(f"{scenario_id}: detecting suite {killed_by} has no failing test evidence")
            valid = False

    return valid


def _suite_summary(results: Iterable[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    summary: dict[str, dict[str, Any]] = {}
    for result in results:
        for suite_row in result.get("suites", []):
            if not isinstance(suite_row, dict):
                continue
            name = suite_row.get("suite")
            status = suite_row.get("status")
            if not isinstance(name, str) or not isinstance(status, str) or status not in SUITE_STATUSES:
                continue
            entry = summary.setdefault(name, {
                "passed": 0, "failed": 0, "skipped": 0, "unviable": 0, "timeout": 0,
                "unscored": 0, "not_run": 0, "kills": 0, "fastest_detection_seconds": None,
            })
            key = "not_run" if status == "not-run" else status
            entry[key] += 1
            if result.get("outcome") == "killed" and result.get("killed_by") == name:
                entry["kills"] += 1
                try:
                    duration = float(suite_row.get("seconds"))
                except (TypeError, ValueError, OverflowError):
                    duration = None
                if duration is not None and duration >= 0:
                    fastest = entry["fastest_detection_seconds"]
                    entry["fastest_detection_seconds"] = duration if fastest is None else min(fastest, duration)
    return summary


def aggregate_reports(
    json_files: List[Path],
    *,
    expected_scenarios: dict[str, dict[str, Any]] | None = None,
    expected_shards: set[str] | None = None,
    present_shards: set[str] | None = None,
    input_diagnostics: list[str] | None = None,
) -> Dict[str, Any]:
    """Combine reports and preserve every evidence gap as a failing diagnostic."""
    diagnostics = list(input_diagnostics or [])
    all_results: list[dict[str, Any]] = []
    result_by_id: dict[str, dict[str, Any]] = {}
    duplicate_ids: set[str] = set()
    unexpected_ids: set[str] = set()
    expected = expected_scenarios or {}
    has_expected_catalogue = expected_scenarios is not None

    if expected_shards is not None:
        present = present_shards or set()
        for shard in sorted(expected_shards - present):
            diagnostics.append(f"missing required shard {shard}")
        for shard in sorted(present - expected_shards):
            diagnostics.append(f"unexpected mutation shard {shard}")

    for path in sorted(json_files):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            diagnostics.append(f"malformed or unreadable report {path}: {error}")
            continue
        if not isinstance(payload, dict):
            diagnostics.append(f"malformed report {path}: top-level JSON value must be an object")
            continue
        rows = payload.get("results")
        if not isinstance(rows, list):
            diagnostics.append(f"malformed report {path}: results must be a list")
            continue

        parent = path.parent.name
        shard_layer = parent.removeprefix("mutation-shard-") if parent.startswith("mutation-shard-") else None
        for index, raw_result in enumerate(rows):
            if not isinstance(raw_result, dict):
                diagnostics.append(f"malformed result in {path} at index {index}: result must be an object")
                continue
            scenario_id = raw_result.get("id")
            if not isinstance(scenario_id, str) or not scenario_id:
                diagnostics.append(f"malformed result in {path} at index {index}: missing scenario ID")
                continue
            result = dict(raw_result)
            outcome = result.get("outcome")
            if not isinstance(outcome, str) or outcome not in OUTCOMES:
                diagnostics.append(f"{scenario_id}: invalid outcome {outcome!r}")
                result["outcome"] = "unscored"

            if scenario_id in result_by_id:
                duplicate_ids.add(scenario_id)
                diagnostics.append(f"duplicate scenario ID {scenario_id} across mutation reports")
                result_by_id[scenario_id]["outcome"] = "unscored"
                continue
            result_by_id[scenario_id] = result

            expected_row = expected.get(scenario_id)
            if has_expected_catalogue and expected_row is None:
                unexpected_ids.add(scenario_id)
                diagnostics.append(f"unexpected scenario ID {scenario_id} in {path}")
                result["outcome"] = "unscored"
            elif expected_row is not None:
                expected_layer = expected_row["layer"]
                if result.get("layer") != expected_layer:
                    diagnostics.append(
                        f"{scenario_id}: report layer {result.get('layer')!r} does not match catalogue layer {expected_layer}"
                    )
                    result["layer"] = expected_layer
                    result["outcome"] = "unscored"
                if shard_layer is not None and shard_layer != expected_layer:
                    diagnostics.append(
                        f"{scenario_id}: report is in {shard_layer} shard but catalogue layer is {expected_layer}"
                    )
                    result["outcome"] = "unscored"
                if not _validate_suite_evidence(result, expected_row["suites"], diagnostics):
                    result["outcome"] = "unscored"
            all_results.append(result)

    expected_ids = set(expected)
    reported_ids = set(result_by_id)
    missing_ids = sorted(expected_ids - reported_ids)
    if has_expected_catalogue:
        for scenario_id in missing_ids:
            diagnostics.append(f"missing expected scenario ID {scenario_id}")

    # A duplicate invalidates the associated ID's score even though its first payload is retained.
    for scenario_id in duplicate_ids:
        result_by_id[scenario_id]["outcome"] = "unscored"

    if not json_files:
        diagnostics.append("no mutation shard JSON reports were collected")

    scored_results = [
        result for result in all_results
        if result.get("outcome") in ("killed", "survived")
        and (not has_expected_catalogue or result["id"] in expected_ids)
        and result["id"] not in duplicate_ids
    ]
    killed = sum(1 for result in scored_results if result["outcome"] == "killed")
    survived = sum(1 for result in scored_results if result["outcome"] == "survived")
    unviable = sum(1 for result in all_results if result.get("outcome") == "unviable")
    timeout = sum(1 for result in all_results if result.get("outcome") == "timeout")
    skipped = sum(1 for result in all_results if result.get("outcome") == "skipped")
    unscored = sum(1 for result in all_results if result.get("outcome") == "unscored")
    score = killed / (killed + survived) if killed + survived else None
    survivors = sorted(result["id"] for result in scored_results if result["outcome"] == "survived")
    unscored_ids = sorted(result["id"] for result in all_results if result.get("outcome") == "unscored")
    scored_ids = sorted(result["id"] for result in scored_results)

    by_layer: Dict[str, Dict[str, Any]] = {}
    if has_expected_catalogue:
        for spec in expected.values():
            layer = spec["layer"]
            layer_summary = by_layer.setdefault(layer, {
                "expected": 0, "reported": 0, "scored": 0, "killed": 0, "survived": 0,
                "unviable": 0, "timeout": 0, "skipped": 0, "unscored": 0,
                "high_risk_survivors": [],
            })
            layer_summary["expected"] += 1
        for result in all_results:
            scenario_id = result["id"]
            spec = expected.get(scenario_id)
            if spec is None:
                continue
            layer_summary = by_layer[spec["layer"]]
            layer_summary["reported"] += 1
            outcome = result.get("outcome")
            if outcome in OUTCOMES:
                layer_summary[outcome] += 1
            if outcome in ("killed", "survived") and scenario_id not in duplicate_ids:
                layer_summary["scored"] += 1
            if outcome == "survived" and spec.get("risk") == "high":
                layer_summary["high_risk_survivors"].append(scenario_id)
    else:
        for result in all_results:
            layer = str(result.get("layer", "unknown"))
            layer_summary = by_layer.setdefault(layer, {
                "expected": 0, "reported": 0, "scored": 0, "killed": 0, "survived": 0,
                "unviable": 0, "timeout": 0, "skipped": 0, "unscored": 0,
                "high_risk_survivors": [],
            })
            layer_summary["reported"] += 1
            outcome = result.get("outcome")
            if outcome in OUTCOMES:
                layer_summary[outcome] += 1
            if result in scored_results:
                layer_summary["scored"] += 1
            if outcome == "survived" and result.get("risk") == "high":
                layer_summary["high_risk_survivors"].append(result["id"])

    baseline_failures: dict[tuple[str, str, str], set[str]] = {}
    for result in all_results:
        for suite in result.get("suites", []):
            if not isinstance(suite, dict):
                continue
            baseline_status = suite.get("baseline_status")
            if baseline_status and baseline_status not in ("passed", "skipped"):
                key = (str(suite.get("suite", "unknown")), str(baseline_status),
                       str(suite.get("baseline_tail") or suite.get("tail") or ""))
                baseline_failures.setdefault(key, set()).add(str(result["id"]))

    suite_summary = _suite_summary(all_results)
    expected_ids_by_layer = {
        layer: sorted(scenario_id for scenario_id, spec in expected.items() if spec["layer"] == layer)
        for layer in LAYERS
    }
    scored_ids_by_layer = {
        layer: sorted(result["id"] for result in scored_results if result.get("layer") == layer)
        for layer in LAYERS
    }
    return {
        "summary": {
            "total_scenarios": len(expected_ids) if has_expected_catalogue else len(all_results),
            "reported_scenarios": len(reported_ids),
            "expected_ids": sorted(expected_ids),
            "expected_ids_by_layer": expected_ids_by_layer,
            "reported_ids": sorted(reported_ids),
            "scored_ids": scored_ids,
            "scored_ids_by_layer": scored_ids_by_layer,
            "missing_ids": missing_ids,
            "unexpected_ids": sorted(unexpected_ids),
            "duplicate_ids": sorted(duplicate_ids),
            "missing_shards": sorted((expected_shards or set()) - (present_shards or set())),
            "unexpected_shards": sorted((present_shards or set()) - (expected_shards or set())) if expected_shards is not None else [],
            "incomplete": bool(diagnostics),
            "incompleteness": diagnostics,
            "killed": killed,
            "survived": survived,
            "unviable": unviable,
            "timeout": timeout,
            "skipped": skipped,
            "unscored": unscored,
            "score": score,
            "survivors": survivors,
            "unscored_ids": unscored_ids,
            "high_risk_survivors_by_layer": {
                layer: counts["high_risk_survivors"] for layer, counts in by_layer.items()
                if counts["high_risk_survivors"]
            },
            "baseline_failures": [
                {"suite": suite, "status": status, "diagnostics": message, "affected_ids": sorted(ids)}
                for (suite, status, message), ids in sorted(baseline_failures.items())
            ],
            "by_layer": by_layer,
            "by_suite": suite_summary,
        },
        "results": all_results,
    }


def format_markdown(aggregated: Dict[str, Any]) -> str:
    """Formats aggregated results into a GitHub-friendly Markdown summary."""
    summary = aggregated["summary"]
    score_str = f"{summary['score']:.0%}" if summary["score"] is not None else "n/a"
    lines = [
        "## SitePulse Mutation Testing Summary",
        "",
        f"**Mutation Score**: **{score_str}** ({summary['killed']} killed / {summary['killed'] + summary['survived']} scored)",
        f"**Scored IDs**: {len(summary['scored_ids'])} / {summary['total_scenarios']} expected",
        "",
        "| Layer | Scored / Expected | Reported | Killed | Survived | Unscored | Unviable | Timeout | Skipped | Score |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for layer in LAYERS:
        counts = summary["by_layer"].get(layer, {})
        killed = counts.get("killed", 0)
        survived = counts.get("survived", 0)
        denominator = killed + survived
        layer_score = f"{killed / denominator:.0%}" if denominator else "n/a"
        lines.append(
            f"| {layer.capitalize()} | {counts.get('scored', 0)} / {counts.get('expected', 0)} | "
            f"{counts.get('reported', 0)} | {killed} | {survived} | {counts.get('unscored', 0)} | "
            f"{counts.get('unviable', 0)} | {counts.get('timeout', 0)} | {counts.get('skipped', 0)} | **{layer_score}** |"
        )

    lines.extend([
        "",
        f"**Totals**: {summary['killed']} killed · {summary['survived']} survived · "
        f"{summary['unscored']} unscored · {summary['unviable']} unviable · "
        f"{summary['timeout']} timeout · {summary['skipped']} skipped",
        "",
    ])

    lines.extend([
        "### Expected and scored IDs by layer",
        "",
        "| Layer | Expected IDs | Scored IDs |",
        "| :--- | :--- | :--- |",
    ])
    for layer in LAYERS:
        expected_ids = summary.get("expected_ids_by_layer", {}).get(layer, [])
        scored_ids = summary.get("scored_ids_by_layer", {}).get(layer, [])
        lines.append(
            f"| {layer.capitalize()} | {', '.join(f'`{_safe_text(item)}`' for item in expected_ids) or '—'} | "
            f"{', '.join(f'`{_safe_text(item)}`' for item in scored_ids) or '—'} |"
        )
    lines.append("")

    if summary["high_risk_survivors_by_layer"]:
        lines.extend(["### High-risk survivors by layer", ""])
        for layer, ids in sorted(summary["high_risk_survivors_by_layer"].items()):
            lines.append(f"- **{layer}**: {', '.join(f'`{scenario_id}`' for scenario_id in ids)}")
        lines.append("")

    if summary["by_suite"]:
        lines.extend([
            "### Suite outcomes",
            "",
            "| Suite | Kills | Passed | Failed | Not run | Skipped | Unviable | Timeouts | Unscored | Fastest detection (seconds) |",
            "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ])
        for suite, counts in sorted(summary["by_suite"].items()):
            fastest = counts["fastest_detection_seconds"]
            fastest_text = f"{fastest:.1f}" if fastest is not None else "—"
            lines.append(
                f"| {suite} | {counts['kills']} | {counts['passed']} | {counts['failed']} | {counts['not_run']} | "
                f"{counts['skipped']} | {counts['unviable']} | {counts['timeout']} | "
                f"{counts['unscored']} | {fastest_text} |"
            )
        lines.append("")

    killed_records = [r for r in aggregated["results"] if r.get("outcome") == "killed" and r.get("killed_test")]
    if killed_records:
        lines.extend(["### Detected test cases", "", "| ID | Suite | Failing test or assertion |", "| :--- | :--- | :--- |"])
        for result in killed_records:
            lines.append(
                f"| `{_safe_text(result.get('id', '-'))}` | {_safe_text(result.get('killed_by', '-'))} | "
                f"{_safe_text(result.get('killed_test', '-'))} |"
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
        for result in survivor_records:
            lines.append(
                f"| `{_safe_text(result.get('id', '-'))}` | {_safe_text(result.get('layer', '-'))} | "
                f"{_safe_text(result.get('area', '-'))} | {_safe_text(result.get('operator', '-'))} | "
                f"{_safe_text(result.get('risk', '-'))} |"
            )
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
            ids = ", ".join(f"`{_safe_text(scenario_id)}`" for scenario_id in failure["affected_ids"])
            lines.append(
                f"| {_safe_text(failure['suite'])} ({_safe_text(failure['status'])}) | {ids} | "
                f"{_safe_text(failure['diagnostics'] or 'No output was captured.')} |"
            )
        lines.append("")

    if summary["incomplete"]:
        lines.extend([
            "### ⚠️ Incomplete mutation evidence",
            "",
            "This report is incomplete and strict verification fails:",
            "",
            "| Diagnostic |",
            "| :--- |",
        ])
        for diagnostic in summary["incompleteness"]:
            lines.append(f"| {_safe_text(diagnostic)} |")
        lines.append("")

    return "\n".join(lines)


def collect_reports(reports_dir: Path) -> tuple[list[Path], set[str], list[str]]:
    """Find shard files and report absent artifacts or payloads without aborting."""
    diagnostics: list[str] = []
    if not reports_dir.is_dir():
        diagnostics.append(f"reports directory is missing: {reports_dir}")
        return [], set(), diagnostics

    shard_dirs = {
        path.name for path in reports_dir.iterdir()
        if path.is_dir() and path.name.startswith("mutation-shard-")
    }
    files: list[Path] = []
    expected_payloads = {f"mutation-shard-{layer}/{filename}" for layer, filename in SHARD_FILES.items()}
    for layer, filename in SHARD_FILES.items():
        shard_name = f"mutation-shard-{layer}"
        payload_path = reports_dir / shard_name / filename
        if not (reports_dir / shard_name).is_dir():
            continue
        if not payload_path.is_file():
            diagnostics.append(f"shard {shard_name} is missing required payload {filename}")

    for path in sorted(reports_dir.rglob("*.json")):
        if path.name == "mutation_summary.json":
            continue
        relative = path.relative_to(reports_dir).as_posix()
        if relative not in expected_payloads:
            diagnostics.append(f"unexpected JSON report file {relative}")
        files.append(path)
    return files, shard_dirs, diagnostics


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports-dir", type=Path, required=True, help="Directory containing mutation shard artifacts")
    parser.add_argument("--catalogue", type=Path, default=DEFAULT_CATALOGUE,
                        help="Expected mutation scenario catalogue")
    parser.add_argument("--out", type=Path, help="Directory to write aggregated report files")
    parser.add_argument("--markdown", type=Path, help="Write Markdown summary here")
    parser.add_argument("--json", action="store_true", help="Print aggregated JSON to stdout")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with 1 if any mutant survived, was unscored, timed out, failed to compile, or evidence is incomplete",
    )
    args = parser.parse_args(argv)

    expected_scenarios, catalogue_diagnostics = load_expected_scenarios(args.catalogue)
    json_files, present_shards, input_diagnostics = collect_reports(args.reports_dir)
    aggregated = aggregate_reports(
        json_files,
        expected_scenarios=expected_scenarios,
        expected_shards=EXPECTED_SHARDS,
        present_shards=present_shards,
        input_diagnostics=catalogue_diagnostics + input_diagnostics,
    )
    markdown = format_markdown(aggregated)

    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown, encoding="utf-8")

    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "mutation_summary.json").write_text(json.dumps(aggregated, indent=2) + "\n", encoding="utf-8")
        (args.out / "mutation_summary.md").write_text(markdown, encoding="utf-8")

    if args.json:
        print(json.dumps(aggregated, indent=2))
    else:
        print(markdown)

    if args.strict:
        summary = aggregated["summary"]
        if (summary["survivors"] or summary["unviable"] or summary["timeout"]
                or summary["unscored"] or summary["incomplete"] or summary["baseline_failures"]):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
