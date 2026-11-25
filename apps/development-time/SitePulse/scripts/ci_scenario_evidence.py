#!/usr/bin/env python3
"""Join named SitePulse CI cases to stable scenario IDs and report unresolved links.

Usage:
  python3 scripts/ci_scenario_evidence.py --artifact-dir e2e-test-report
  python3 scripts/ci_scenario_evidence.py --artifact-dir e2e-test-report --json
"""
from __future__ import annotations

import argparse
import html
import json
import re
import sys
from collections import Counter
from pathlib import Path

import feature_traceability as ft

CASE_STATUSES = {"passed": "passing", "failed": "failing", "error": "failing",
                 "skipped": "skipped", "cancelled": "skipped", "not-run": "skipped"}


def _normalize(value: object) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def _has_title(native_id: str, title: str) -> bool:
    words = re.findall(r"[a-z0-9]+", title.lower())
    if not words:
        return False
    phrase = r"[^a-z0-9]+".join(map(re.escape, words))
    return re.search(rf"(?<![a-z0-9]){phrase}(?![a-z0-9])", native_id.lower()) is not None


def _load_json(path: Path) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read {path.name}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{path.name} must contain a JSON object")
    return payload


def _load_cases(path: Path) -> list[dict]:
    cases = []
    try:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"invalid JSON in {path.name}:{line_number}: {exc}") from exc
            if isinstance(row, dict):
                cases.append(row)
    except OSError as exc:
        raise ValueError(f"cannot read {path.name}: {exc}") from exc
    return cases


def _case_matches(ref: dict, case: dict) -> bool:
    native_id = str(case.get("native_id", ""))
    native = _normalize(native_id)
    test = _normalize(ref.get("test", ""))
    if not test or test not in native:
        return False
    source = str(ref.get("file", ""))
    stem = _normalize(Path(source).stem)
    producer = str(case.get("producer", ""))
    # Flutter reports carry their source path. Rust and Python reporters expose native test ids,
    # where the declared test name is the stable identifier and source stem disambiguates when
    # present (Rust module paths and Python module/class paths commonly include it).
    if producer == "flutter":
        return stem in native and _has_title(native_id, str(ref.get("test", "")))
    components = [_normalize(part) for part in re.split(r"::|[./]", native_id)]
    return stem in native and test in components


def build_evidence(scenarios: dict, cases: list[dict], links: dict[str, list[dict]],
                   run_id: object = None, commit: object = None) -> dict:
    by_scenario: dict[str, dict] = {}
    for scenario_id in sorted(scenarios):
        refs = links.get(scenario_id, [])
        matched = []
        for case in cases:
            # Browser records already carry an explicit scenario id; all other lanes use their
            # declared test link because the CI adapters preserve stable native test names.
            if scenario_id in case.get("scenario_ids", []) or any(_case_matches(ref, case) for ref in refs):
                matched.append({"producer": case.get("producer", "unknown"),
                                "suite": case.get("suite", "unknown"),
                                "native_id": case.get("native_id", ""),
                                "status": CASE_STATUSES.get(str(case.get("status", "")).lower(), "unresolved")})
        state = scenarios[scenario_id].get("state", "unresolved")
        if matched:
            statuses = {item["status"] for item in matched}
            evidence_status = ("failing" if "failing" in statuses else
                               "passing" if "passing" in statuses else
                               "skipped" if statuses == {"skipped"} else "unresolved")
        elif any("nightly" in str(ref.get("file", "")).lower() for ref in refs):
            evidence_status = "scheduled"
        elif state == "planned":
            evidence_status = "planned"
        else:
            evidence_status = "unresolved"
        by_scenario[scenario_id] = {"state": state, "evidence": evidence_status,
                                    "links": refs, "cases": matched}
    counts = Counter(row["evidence"] for row in by_scenario.values())
    return {"schema": 1, "run_id": run_id, "commit": commit,
            "scenario_count": len(by_scenario), "evidence_counts": dict(sorted(counts.items())),
            "scenarios": by_scenario,
            "unresolved_links": [{"scenario_id": sid, "links": row["links"]}
                                 for sid, row in by_scenario.items() if row["evidence"] == "unresolved"]}


def compare(artifact_dir: Path, repository_root: Path) -> dict:
    status = _load_json(artifact_dir / "product-status.json")
    scenarios = status.get("scenarios")
    if not isinstance(scenarios, dict):
        raise ValueError("product-status.json has no scenario catalogue")
    return build_evidence(scenarios, _load_cases(artifact_dir / "case-results.jsonl"),
                          ft.load_links(repository_root), status.get("run_id"), status.get("commit"))


def render_markdown(report: dict) -> str:
    counts = report["evidence_counts"]
    lines = ["## Scenario evidence across CI lanes", "",
             f"**Evidence:** {counts.get('passing', 0)} passing · {counts.get('failing', 0)} failing · "
             f"{counts.get('skipped', 0)} skipped · {counts.get('scheduled', 0)} scheduled · "
             f"{counts.get('planned', 0)} planned · "
             f"{counts.get('unresolved', 0)} unresolved.", "",
             "Unresolved scenario links are listed below with their declared source tests.", ""]
    unresolved = report["unresolved_links"]
    if unresolved:
        lines.extend(["| Scenario | Declared test links |", "| --- | --- |"])
        for item in unresolved:
            refs = "; ".join(f"`{ref['file']}:{ref['line']}` {ref['test']}" for ref in item["links"])
            lines.append(f"| `{item['scenario_id']}` | {refs or 'No declared test link'} |")
    else:
        lines.append("No unresolved scenario links.")
    return "\n".join(lines) + "\n"


def add_html_section(page: str, report: dict) -> str:
    """Add an escaped, self-contained scenario evidence table to the published dashboard."""
    counts = report["evidence_counts"]
    tiles = " ".join(
        f'<span class="scenario-evidence-count {html.escape(state)}">{counts.get(state, 0)} '
        f'{html.escape(state)}</span>'
        for state in ("passing", "failing", "skipped", "scheduled", "planned", "unresolved")
    )
    rows = []
    for scenario_id, row in report["scenarios"].items():
        cases = "; ".join(f"{case['suite']}: {case['native_id']} ({case['status']})" for case in row["cases"])
        refs = "; ".join(f"{ref['file']}:{ref['line']} {ref['test']}" for ref in row["links"])
        detail = cases or ("Scheduled in nightly lane" if row["evidence"] == "scheduled" else refs)
        rows.append(
            f"<tr><td><code>{html.escape(scenario_id)}</code></td>"
            f"<td><span class=\"scenario-evidence-count {html.escape(row['evidence'])}\">"
            f"{html.escape(row['evidence'])}</span></td><td>{html.escape(detail)}</td></tr>"
        )
    unresolved = len(report["unresolved_links"])
    section = (
        '<section class="ci-scenario-evidence"><h2>CI scenario evidence</h2>'
        f"<p>{tiles}</p><p>{unresolved} unresolved scenario links are listed in the table.</p>"
        '<table><thead><tr><th>Scenario</th><th>Evidence</th><th>Matched case or declared link</th></tr></thead>'
        f"<tbody>{''.join(rows)}</tbody></table></section>"
        '<style>.scenario-evidence-count{display:inline-block;padding:.2rem .45rem;border-radius:.3rem;'
        'font-weight:600;text-transform:capitalize;background:#e6edf5}.scenario-evidence-count.passing{background:#d9f2e2}'
        '.scenario-evidence-count.failing{background:#ffe0e0}.scenario-evidence-count.skipped{background:#fff0c2}'
        '.scenario-evidence-count.scheduled{background:#dce9ff}.scenario-evidence-count.unresolved{background:#f5d9ff}'
        '.ci-scenario-evidence table{border-collapse:collapse;width:100%}.ci-scenario-evidence th,'
        '.ci-scenario-evidence td{border:1px solid #d8dee8;padding:.45rem;text-align:left;vertical-align:top}'
        '.ci-scenario-evidence td:last-child{overflow-wrap:anywhere}</style>'
    )
    return page.replace("</body>", section + "</body>")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", type=Path, required=True,
                        help="CI report directory containing product-status.json and case-results.jsonl")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="SitePulse repository root (defaults to the current checkout)")
    parser.add_argument("--out", type=Path, help="Write scenario-evidence.json and .md to this directory")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    args = parser.parse_args(argv)
    try:
        report = compare(args.artifact_dir, args.root)
        if args.out:
            args.out.mkdir(parents=True, exist_ok=True)
            (args.out / "scenario-evidence.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            (args.out / "scenario-evidence.md").write_text(render_markdown(report), encoding="utf-8")
    except ValueError as exc:
        print(f"ci_scenario_evidence: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(render_markdown(report), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
