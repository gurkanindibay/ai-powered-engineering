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
from collections import Counter, defaultdict
from pathlib import Path

import feature_traceability as ft

CASE_STATUSES = {"passed": "passing", "failed": "failing", "error": "failing",
                 "skipped": "skipped", "cancelled": "skipped", "not-run": "skipped"}
PUBLIC_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._:/()'&+-]{0,119}$")
WORKFLOW_RUN_URL = re.compile(r"^https://[A-Za-z0-9.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/\d+$")
DART_INTERPOLATION = re.compile(r"(?<!\\)\$(?:\{[^{}]*\}|[A-Za-z_]\w*)")
# An interpolated title needs this much literal text to identify its cases.
MIN_TEMPLATE_LITERAL = 12


def safe_public_label(value: object, fallback: str = "") -> str:
    return value if isinstance(value, str) and PUBLIC_LABEL.fullmatch(value) else fallback


def safe_workflow_run(value: object) -> str:
    return value if isinstance(value, str) and WORKFLOW_RUN_URL.fullmatch(value) else ""


def safe_static_case_name(value: object) -> str:
    if not isinstance(value, str):
        return "test case"
    # Pytest and JUnit commonly append parameter IDs in brackets. Do not publish that suffix.
    base = value.split("[", 1)[0].strip()
    return safe_public_label(base, "test case")[:100]


def _normalize(value: object) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def _name_components(native_id: str, producer: str) -> set[str]:
    # A pytest parameter suffix is not part of the declared test name.
    if producer != "flutter":
        native_id = native_id.split("[", 1)[0]
    return {_normalize(part) for part in re.split(r"::|[./]", native_id)}


def _matches_template(native_id: str, title: str) -> bool:
    """Match a Dart title such as 'cannot change for $status' against the names it expands to."""
    literals = DART_INTERPOLATION.split(title)
    if len(literals) < 2 or len(_normalize("".join(literals))) < MIN_TEMPLATE_LITERAL:
        return False
    # Each interpolated value must be a single word, so a longer sibling title cannot stand in.
    pattern = r"\S+".join(map(re.escape, literals))
    return re.search(rf"(?:^| ){pattern}$", native_id.split("::", 1)[-1]) is not None


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
    source = str(ref.get("file", ""))
    stem = _normalize(Path(source).stem)
    producer = str(case.get("producer", ""))
    if producer == "flutter" and DART_INTERPOLATION.search(str(ref.get("test", ""))):
        return stem in native and _matches_template(native_id, str(ref["test"]))
    if not test or test not in native:
        return False
    # Flutter reports carry their source path. Rust and Python reporters expose native test ids,
    # where the declared test name is the stable identifier and source stem disambiguates when
    # present (Rust module paths and Python module/class paths commonly include it).
    if producer == "flutter":
        return stem in native and _has_title(native_id, str(ref.get("test", "")))
    components = _name_components(native_id, producer)
    return stem in native and test in components


def _markdown_cell(value: object) -> str:
    return str(value).replace("|", r"\|").replace("`", r"\`").replace("\n", " ")


def named_links(catalogue: ft.Catalogue) -> dict[str, list[dict]]:
    """Attach each `covers:` link to the test the traceability gate's lexical resolver names.

    A line-by-line read misses a multi-line Dart declaration and can give a marker inside a test body
    to the test after it. A registered API system check also gets its case id.
    """
    resolved, _, _ = ft.scenario_evidence(catalogue)
    links: dict[str, list[dict]] = {}
    for scenario_id, entries in resolved.items():
        links[scenario_id] = []
        for entry in entries:
            ref = dict(entry["ref"])
            test = entry["test"] if entry["kind"] == "test" else None
            if test:
                ref["test"] = test["name"]
                if test.get("case_id"):
                    ref["case_id"] = test["case_id"]
            else:
                ref["evidence_kind"] = safe_public_label(entry.get("kind"), "unknown")
            links[scenario_id].append(ref)
    return links


def build_evidence(scenarios: dict, cases: list[dict], links: dict[str, list[dict]],
                   run_id: object = None, commit: object = None, attempt: object = None,
                   workflow_run: object = None) -> dict:
    """Match on the cases' full names; every case field in the result is sanitized for publication."""
    by_test: dict[str, list[tuple[str, int]]] = defaultdict(list)
    by_flutter_stem: dict[str, list[int]] = defaultdict(list)
    by_explicit_scenario: dict[str, list[int]] = defaultdict(list)
    by_api_check: dict[str, list[int]] = defaultdict(list)
    for index, case in enumerate(cases):
        native_id = str(case.get("native_id", ""))
        producer = str(case.get("producer", ""))
        for component in _name_components(native_id, producer):
            by_test[component].append((producer, index))
        if case.get("suite") == "api-system":
            by_api_check[native_id].append(index)
        if producer == "flutter":
            by_flutter_stem[_normalize(Path(native_id.split("::", 1)[0]).stem)].append(index)
        scenario_ids = case.get("scenario_ids", [])
        if isinstance(scenario_ids, list):
            for scenario_id in scenario_ids:
                by_explicit_scenario[str(scenario_id)].append(index)

    by_scenario: dict[str, dict] = {}
    for scenario_id in sorted(scenarios):
        refs = links.get(scenario_id, [])
        matched_indexes = set(by_explicit_scenario.get(scenario_id, []))
        for ref in refs:
            # An API system check runs under its registry key, not its function name.
            matched_indexes.update(by_api_check.get(str(ref.get("case_id", "")), []))
            test = _normalize(ref.get("test", ""))
            stem = _normalize(Path(str(ref.get("file", ""))).stem)
            if not test:
                continue
            for producer, index in by_test.get(test, []):
                if producer != "flutter" and _case_matches(ref, cases[index]):
                    matched_indexes.add(index)
            # Flutter native IDs include the full source path plus group and test title; a title
            # may be part of a longer native ID, so filter the much smaller same-file index.
            for index in by_flutter_stem.get(stem, []):
                if _case_matches(ref, cases[index]):
                    matched_indexes.add(index)
        matched = []
        for index in sorted(matched_indexes):
            case = cases[index]
            native_id = str(case.get("native_id", ""))
            native_name = native_id.rsplit("::", 1)[-1]
            test_status = CASE_STATUSES.get(str(case.get("status", "")).lower(), "unresolved")
            tested_commit = case.get("tested_commit", commit)
            historical = (isinstance(commit, str) and bool(commit) and isinstance(tested_commit, str)
                          and bool(tested_commit) and tested_commit != commit)
            matched.append({
                "producer": safe_public_label(case.get("producer"), "unknown"),
                "suite": safe_public_label(case.get("suite"), "unknown"),
                "native_id": safe_static_case_name(native_id),
                "test_name": safe_public_label(native_name, "test case"),
                "status": "historical" if historical else test_status,
                "test_status": test_status,
                "workflow_run": safe_workflow_run(workflow_run),
                "attempt": safe_public_label(attempt),
                "tested_commit": tested_commit if isinstance(tested_commit, str)
                and re.fullmatch(r"[0-9a-f]{7,40}", tested_commit) else "",
            })
        state = scenarios[scenario_id].get("state", "unresolved")
        statuses = {item["status"] for item in matched if item["status"] != "historical"}
        # A @pending scenario is not automated, so a linked partial test cannot make it pass.
        if matched and not statuses and all(item["status"] == "historical" for item in matched):
            evidence_status = "historical"
        elif matched and (state != "planned" or "failing" in statuses):
            has_incomplete_source = any(
                str(cases[index].get("suite_status", "collected")) not in ("collected", "collected-with-failures")
                for index in matched_indexes)
            evidence_status = ("failing" if "failing" in statuses else
                               "incomplete" if has_incomplete_source else
                               "passing" if "passing" in statuses else
                               "skipped" if statuses == {"skipped"} else "unresolved")
        elif any("nightly" in str(ref.get("file", "")).lower() for ref in refs):
            evidence_status = "scheduled"
        elif state == "planned":
            evidence_status = "planned"
        elif any(ref.get("evidence_kind") in {"wrapper", "file-level", "script"} for ref in refs):
            evidence_status = "coarse"
        else:
            evidence_status = "unresolved"
        by_scenario[scenario_id] = {"state": state, "evidence": evidence_status,
                                    "links": refs, "cases": matched}
    counts = Counter(row["evidence"] for row in by_scenario.values())
    return {"schema": 1, "run_id": run_id, "attempt": attempt, "commit": commit,
            "workflow_run": safe_workflow_run(workflow_run),
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
                          named_links(ft.load_catalogue(repository_root)), status.get("run_id"), status.get("commit"),
                          status.get("attempt"), status.get("workflow_run"))


def render_markdown(report: dict) -> str:
    counts = report["evidence_counts"]
    lines = ["## Scenario evidence across CI lanes", "",
             f"**Workflow run:** {report.get('workflow_run') or 'unavailable'} · attempt "
             f"{report.get('attempt') or 'unknown'} · tested commit `{report.get('commit') or 'unknown'}`.", "",
             f"**Evidence:** {counts.get('passing', 0)} passing · {counts.get('failing', 0)} failing · "
             f"{counts.get('skipped', 0)} skipped · {counts.get('historical', 0)} historical · "
             f"{counts.get('scheduled', 0)} scheduled · "
             f"{counts.get('planned', 0)} planned · "
             f"{counts.get('coarse', 0)} coarse · {counts.get('incomplete', 0)} incomplete · "
             f"{counts.get('unresolved', 0)} unresolved.", "",
             "Unresolved scenario links are listed below with their declared source tests.", ""]
    unresolved = report["unresolved_links"]
    if unresolved:
        lines.extend(["| Scenario | Declared test links |", "| --- | --- |"])
        for item in unresolved:
            refs = "; ".join(f"`{_markdown_cell(ref['file'])}:{ref['line']}` {_markdown_cell(ref['test'])}"
                              for ref in item["links"])
            lines.append(f"| `{_markdown_cell(item['scenario_id'])}` | {refs or 'No declared test link'} |")
    else:
        lines.append("No unresolved scenario links.")
    return "\n".join(lines) + "\n"


def add_html_section(page: str, report: dict) -> str:
    """Add an escaped, self-contained scenario evidence table to the published dashboard."""
    counts = report["evidence_counts"]
    tiles = " ".join(
        f'<span class="scenario-evidence-count {html.escape(state)}">{counts.get(state, 0)} '
        f'{html.escape(state)}</span>'
        for state in ("passing", "failing", "skipped", "historical", "scheduled", "planned", "coarse", "unresolved", "incomplete")
    )
    rows = []
    for scenario_id, row in report["scenarios"].items():
        case_labels = []
        for case in row["cases"]:
            status = case["status"]
            if status == "historical":
                status = f"historical, result {case['test_status']}"
            case_labels.append(
                f"{case['suite']}: {case['test_name']} ({status}) · run {case['workflow_run'] or 'unavailable'}"
                f" attempt {case['attempt'] or 'unknown'} · commit {case['tested_commit'] or 'unknown'}")
        cases = "; ".join(case_labels)
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
        '.scenario-evidence-count.incomplete{background:#f4c7c3}'
        '.scenario-evidence-count.coarse{background:#f0e1bf}'
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
