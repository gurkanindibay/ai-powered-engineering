#!/usr/bin/env python3
"""Build and verify the public-safe SitePulse GitHub Pages artifact.

The `gh-pages` branch is retained as archive storage after Pages switches to
Actions. This tool migrates that state by discarding rendered HTML and raw
Markdown, then rebuilding stable URLs from a strict JSON allowlist. New detailed
case and gate data uses the optional `public-report.json` contract documented in
`docs/testing/test-reporting-pages-analysis.md`; without it, the report page is
an explicit metadata-only placeholder.
"""
from __future__ import annotations

import argparse
import html
import json
import math
import re
import shutil
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))
import product_status as ps  # noqa: E402

RUN_DIRECTORY = re.compile(r"^(\d+)-(\d+)$")
SHA = re.compile(r"^[0-9a-f]{40}$")
DATE_TIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SCENARIO_ID = re.compile(r"^SC-\d{2}-\d{2}-\d{2,}$")
SAFE_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._:/()'&+-]{0,119}$")
STATES = {"PASS", "FAIL", "SKIPPED", "ERROR", "NOT RUN", "INCOMPLETE", "UNKNOWN"}
SNAPSHOT_STATES = {"passing", "failing", "no_result", "planned"}
HEALTH = {"failing", "verified", "in_progress", "not_automated", "not_specified"}
STATUS = {"PASS", "FAIL", "INCOMPLETE", "UNKNOWN", "ERROR"}
JUNIT_NUMBERS = ("tests", "passed", "failures", "errors", "skipped", "seconds", "files")
TOTAL_NUMBERS = ("stories", "stories_with_scenarios", "stories_passing", "scenarios", "automated",
                 "passing", "failing", "no_result", "planned", "epics", "epics_verified", "epics_failing")
EPIC_NUMBERS = ("stories", "stories_with_scenarios", "stories_passing", "scenarios", "automated",
                "passing", "failing", "no_result", "planned")


def _write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _nonnegative_number(value: object) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0 or not math.isfinite(value):
        return None
    return value


def _safe_label(value: object, fallback: str = "") -> str:
    text = str(value) if isinstance(value, str) else ""
    return text if SAFE_LABEL.fullmatch(text) else fallback


def safe_summary(raw: object, run_id: str, attempt: str, run_number: int | None = None,
                 commit: str | None = None) -> dict:
    """Copy only report identity, enum statuses, and numeric rollups."""
    source = raw if isinstance(raw, dict) else {}
    junit = source.get("junit") if isinstance(source.get("junit"), dict) else {}
    clean_junit = {key: value for key in JUNIT_NUMBERS
                   if (value := _nonnegative_number(junit.get(key))) is not None}
    scenario_counts = source.get("scenario_counts") if isinstance(source.get("scenario_counts"), dict) else {}
    clean_counts = {key: value for key, raw_value in scenario_counts.items()
                    if key in STATES and (value := _nonnegative_number(raw_value)) is not None}
    result = {
        "schema": 1,
        "run_id": run_id,
        "attempt": attempt,
        "run_number": run_number,
        "commit": commit if commit and SHA.fullmatch(commit) else "",
        "status": source.get("status") if isinstance(source.get("status"), str) and source.get("status") in STATUS else "UNKNOWN",
        "junit": clean_junit,
        "scenario_counts": clean_counts,
    }
    covered = source.get("scenarios_covered")
    if isinstance(covered, str) and re.fullmatch(r"\d{1,5}/\d{1,5}", covered):
        result["scenarios_covered"] = covered
    return result


def _safe_snapshot(raw: object, summary: dict) -> dict | None:
    if not isinstance(raw, dict):
        return None
    generated_at = raw.get("generated_at")
    if not isinstance(generated_at, str) or not DATE_TIME.fullmatch(generated_at):
        return None
    result = {
        "schema": raw.get("schema") if isinstance(raw.get("schema"), int) else 0,
        "generated_at": generated_at,
        "run_id": (raw["run_id"] if isinstance(raw.get("run_id"), str) and
                   re.fullmatch(r"\d{8}T\d{6}Z-[0-9a-f]{7,40}", raw["run_id"]) else ""),
        "commit": summary["commit"],
        "status": summary["status"],
        "junit": summary["junit"],
        "catalogue_history": [],
        "recent_changes": [],
    }
    totals = raw.get("totals")
    if isinstance(totals, dict):
        result["totals"] = {key: int(value) for key in TOTAL_NUMBERS
                             if (value := _nonnegative_number(totals.get(key))) is not None}
    epics = raw.get("epics")
    if isinstance(epics, list):
        safe_epics = []
        for epic in epics:
            if not isinstance(epic, dict) or not re.fullmatch(r"EPIC-\d{2}", str(epic.get("id", ""))):
                continue
            row = {"id": epic["id"], "title": _safe_label(epic.get("title"), epic["id"]),
                   "health": epic.get("health") if isinstance(epic.get("health"), str) and epic.get("health") in HEALTH
                   else "not_specified"}
            row.update({key: int(value) for key in EPIC_NUMBERS
                        if (value := _nonnegative_number(epic.get(key))) is not None})
            safe_epics.append(row)
        result["epics"] = safe_epics
    scenarios = raw.get("scenarios")
    if isinstance(scenarios, dict):
        safe_scenarios = {}
        for identifier, scenario in scenarios.items():
            if not SCENARIO_ID.fullmatch(str(identifier)) or not isinstance(scenario, dict):
                continue
            state = scenario.get("state")
            if not isinstance(state, str) or state not in SNAPSHOT_STATES:
                continue
            safe_scenarios[identifier] = {
                "state": state, "name": _safe_label(scenario.get("name"), identifier),
                "epic": _safe_label(scenario.get("epic"), ""),
                "story": _safe_label(scenario.get("story"), ""),
            }
        result["scenarios"] = safe_scenarios
    history = raw.get("catalogue_history")
    if isinstance(history, list):
        points = []
        for point in history:
            if not isinstance(point, dict) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(point.get("date", ""))):
                continue
            clean = {"date": point["date"]}
            clean.update({key: int(value) for key in ("epics", "stories", "stories_with_scenarios", "scenarios", "automated")
                          if (value := _nonnegative_number(point.get(key))) is not None})
            points.append(clean)
        result["catalogue_history"] = points
    return result


def _safe_public_report(path: Path) -> dict | None:
    if not path.is_file():
        return None
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("schema") != 1:
        raise ValueError("public-report.json must use schema 1")
    gates = []
    for gate in raw.get("gates", []) if isinstance(raw.get("gates", []), list) else []:
        if not isinstance(gate, dict):
            continue
        name = _safe_label(gate.get("name"))
        state = gate.get("status")
        duration = _nonnegative_number(gate.get("duration_seconds"))
        if name and isinstance(state, str) and state in STATES:
            gates.append({"name": name, "status": state, **({"duration_seconds": duration} if duration is not None else {})})
    cases = []
    for case in raw.get("cases", []) if isinstance(raw.get("cases", []), list) else []:
        if not isinstance(case, dict):
            continue
        name = _safe_label(case.get("name"))
        identifier = _safe_label(case.get("id"))
        state = case.get("status")
        if not (name or identifier) or not isinstance(state, str) or state not in STATES:
            continue
        item = {"id": identifier, "name": name, "status": state}
        duration = _nonnegative_number(case.get("duration_seconds"))
        if duration is not None:
            item["duration_seconds"] = duration
        scenario = case.get("scenario_id")
        if isinstance(scenario, str) and SCENARIO_ID.fullmatch(scenario):
            item["scenario_id"] = scenario
        cases.append(item)
    return {"schema": 1, "gates": gates, "cases": cases}


def _detail_page(summary: dict, public_report: dict | None, archive_href: str) -> str:
    run = html.escape(summary["run_id"])
    action_url = f"https://github.com/gurkanindibay/ai-powered-engineering/actions/runs/{run}"
    junit = summary["junit"]
    numbers = " · ".join(f"{label}: {int(junit.get(key, 0))}" for label, key in
                         (("Tests", "tests"), ("Passed", "passed"), ("Failed", "failures"), ("Errors", "errors"), ("Skipped", "skipped")))
    rows = []
    if public_report:
        for gate in public_report["gates"]:
            rows.append(f"<tr><td>{html.escape(gate['name'])}</td><td>{html.escape(gate['status'])}</td>"
                        f"<td>{gate.get('duration_seconds', '')}</td></tr>")
    gate_table = ("<h2>CI gates</h2><table><thead><tr><th>Gate</th><th>Status</th><th>Seconds</th></tr></thead><tbody>"
                  + "".join(rows) + "</tbody></table>") if rows else (
                      "<p>Reviewed gate inventory is not available for this archived run. "
                      "The original rendered page was removed during the privacy migration.</p>")
    cases_html = ""
    if public_report and public_report["cases"]:
        case_rows = "".join(f"<tr><td>{html.escape(c.get('id', ''))}</td><td>{html.escape(c.get('name', ''))}</td>"
                             f"<td>{html.escape(c['status'])}</td><td>{html.escape(c.get('scenario_id', ''))}</td></tr>"
                             for c in public_report["cases"])
        cases_html = ("<h2>Test inventory</h2><table><thead><tr><th>ID</th><th>Test</th><th>Status</th>"
                      "<th>Scenario</th></tr></thead><tbody>" + case_rows + "</tbody></table>")
    commit = html.escape(summary.get("commit", "")[:12])
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SitePulse report {run}</title><style>body{{font:16px system-ui,sans-serif;max-width:1000px;margin:3rem auto;padding:0 1rem;color:#172033}}a{{color:#1459a6}}table{{border-collapse:collapse;width:100%;margin:1rem 0}}th,td{{padding:.65rem;text-align:left;border-bottom:1px solid #d8dee8}}</style></head>
<body><p><a href="{html.escape(archive_href, quote=True)}">Product status</a> · <a href="{html.escape(archive_href.replace('index.html','history.html'), quote=True)}">All runs</a></p>
<h1>SitePulse CI report</h1><p>Run <a href="{action_url}">{run}</a> · commit {commit} · {html.escape(summary['status'])}</p>
<p>{numbers}</p>{gate_table}{cases_html}</body></html>\n"""


def _write_archive(site: Path, folder: str, raw_summary: object, product_snapshot: object,
                   public_report: dict | None = None, identity: dict | None = None) -> dict:
    match = RUN_DIRECTORY.fullmatch(folder)
    if not match:
        raise ValueError(f"invalid report archive directory: {folder}")
    run_id, attempt = match.groups()
    source_summary = raw_summary if isinstance(raw_summary, dict) else {}
    identity = identity or {"run_number": source_summary.get("run_number"), "commit": source_summary.get("commit")}
    summary = safe_summary(raw_summary, run_id, attempt,
                           identity.get("run_number") if isinstance(identity.get("run_number"), int) else None,
                           identity.get("commit"))
    destination = site / "reports" / folder
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    clean_snapshot = _safe_snapshot(product_snapshot, summary)
    if clean_snapshot:
        summary["generated_at"] = clean_snapshot["generated_at"]
        _write_json(destination / "product-status.json", clean_snapshot)
    _write_json(destination / "summary.json", summary)
    _write_json(destination / "public-report.json", public_report or {"schema": 1, "gates": [], "cases": []})
    (destination / "index.html").write_text(_detail_page(summary, public_report, "../../index.html"), encoding="utf-8")
    return summary


def build(site: Path, report: Path, run_id: str, attempt: str, run_number: int,
          commit: str, action_run_id: str | None = None, require_public_report: bool = False) -> dict:
    """Sanitize legacy state, add this report, and render a static Pages tree."""
    if not re.fullmatch(r"\d+", run_id) or not re.fullmatch(r"\d+", attempt):
        raise ValueError("run ID and attempt must be numeric")
    if run_number < 1 or int(attempt) < 1:
        raise ValueError("run number and attempt must be positive")
    if not SHA.fullmatch(commit):
        raise ValueError("commit must be a full lowercase SHA-1")
    action_run_id = action_run_id or run_id
    if not re.fullmatch(r"\d+", action_run_id):
        raise ValueError("Actions run ID must be numeric")
    if site.is_symlink():
        raise ValueError("site path must not be a symbolic link")
    site.mkdir(parents=True, exist_ok=True)
    marker = site / "sitepulse-pages.json"
    previous = json.loads(marker.read_text(encoding="utf-8")) if marker.is_file() and not marker.is_symlink() else None
    if not isinstance(previous, dict) or not all((
            isinstance(previous.get("run_id"), str) and re.fullmatch(r"\d+", previous["run_id"]),
            isinstance(previous.get("run_number"), int) and previous["run_number"] > 0,
            isinstance(previous.get("run_attempt"), int) and previous["run_attempt"] > 0,
            isinstance(previous.get("commit"), str) and SHA.fullmatch(previous["commit"]),
            isinstance(previous.get("action_run_id"), str) and re.fullmatch(r"\d+", previous["action_run_id"]),
    )):
        previous = None
    old_archives = []
    report_root = site / "reports"
    if report_root.exists():
        for folder in sorted(p for p in report_root.iterdir() if p.is_dir() and not p.is_symlink()):
            if folder.name == f"{run_id}-{attempt}":
                continue
            summary_path = folder / "summary.json"
            snapshot_path = folder / "product-status.json"
            if not summary_path.is_file() or summary_path.is_symlink():
                continue
            try:
                raw_summary = json.loads(summary_path.read_text(encoding="utf-8"))
                raw_snapshot = json.loads(snapshot_path.read_text(encoding="utf-8")) if snapshot_path.is_file() and not snapshot_path.is_symlink() else None
                public_path = folder / "public-report.json"
                public = _safe_public_report(public_path) if public_path.is_file() and not public_path.is_symlink() else None
                old_archives.append((folder.name, raw_summary, raw_snapshot, public))
            except (OSError, json.JSONDecodeError):
                continue
    # Remove every prior generated or unknown root file. Only archive JSON is read above.
    for child in list(site.iterdir()):
        if child.name == "reports" and child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()
    report_summary_path = report / "summary.json"
    if not report_summary_path.is_file():
        raise ValueError("report directory must contain summary.json")
    raw_current = json.loads(report_summary_path.read_text(encoding="utf-8"))
    snapshot_path = report / "product-status.json"
    raw_current_snapshot = json.loads(snapshot_path.read_text(encoding="utf-8")) if snapshot_path.is_file() else None
    public_path = report / "public-report.json"
    if require_public_report and not public_path.is_file():
        raise ValueError("public-report.json is required before Pages publishing is enabled")
    public_report = _safe_public_report(public_path)
    for folder, summary, snapshot, public in old_archives:
        _write_archive(site, folder, summary, snapshot, public)
    current_key = f"{run_id}-{attempt}"
    current = _write_archive(site, current_key, raw_current, raw_current_snapshot, public_report,
                             {"run_number": run_number, "commit": commit})
    current_identity = {"run_id": run_id, "run_number": run_number, "run_attempt": int(attempt),
                        "commit": commit, "action_run_id": action_run_id}
    candidate_order = (run_number, int(attempt))
    previous_order = ((int(previous.get("run_number", -1)), int(previous.get("run_attempt", -1)))
                      if isinstance(previous, dict) else (-1, -1))
    is_latest = candidate_order >= previous_order
    if is_latest:
        _write_json(marker, current_identity)
        (site / "latest.html").write_text(_detail_page(current, public_report, "index.html"), encoding="utf-8")
    else:
        _write_json(marker, previous)
        latest_folder = f"{previous.get('run_id')}-{previous.get('run_attempt')}"
        latest_dir = site / "reports" / latest_folder
        if not (latest_dir / "summary.json").is_file():
            raise ValueError("refusing stale run: persisted latest archive is missing")
        latest_summary = json.loads((latest_dir / "summary.json").read_text(encoding="utf-8"))
        latest_public = _safe_public_report(latest_dir / "public-report.json")
        (site / "latest.html").write_text(_detail_page(latest_summary, latest_public, "index.html"), encoding="utf-8")
    _render_history(site)
    _render_dashboard(site, current if is_latest else None)
    return {"archive": current_key, "archives": len(list(report_root.glob("*/summary.json"))),
            "latest": json.loads(marker.read_text(encoding="utf-8")), "is_latest": is_latest,
            "site": str(site)}


def _render_history(site: Path) -> None:
    items = []
    for summary_path in (site / "reports").glob("*/summary.json"):
        folder = summary_path.parent.name
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        items.append((int(summary.get("run_number") or int(folder.split("-")[0])), folder, summary))
    items.sort(key=lambda row: (row[0], int(row[1].split("-")[1])), reverse=True)
    rows = "".join(f'<tr><td><a href="reports/{html.escape(folder, quote=True)}/">Run {html.escape(folder)}</a></td>'
                   f'<td>{html.escape(str(summary.get("status", "UNKNOWN")))}</td>'
                   f'<td>{int(summary.get("junit", {}).get("passed", 0))}/{int(summary.get("junit", {}).get("tests", 0))}</td></tr>'
                   for _, folder, summary in items)
    (site / "history.html").write_text(f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>SitePulse execution history</title>
<style>body{{font:16px system-ui,sans-serif;max-width:1000px;margin:3rem auto;padding:0 1rem;color:#172033}}a{{color:#1459a6}}table{{border-collapse:collapse;width:100%}}td,th{{padding:.7rem;text-align:left;border-bottom:1px solid #d8dee8}}</style></head>
<body><h1>SitePulse execution history</h1><p><a href="index.html">Product status</a> · <a href="latest.html">Latest report</a></p>
<table><thead><tr><th>Archive</th><th>Status</th><th>Passed</th></tr></thead><tbody>{rows}</tbody></table></body></html>\n""", encoding="utf-8")


def _render_dashboard(site: Path, current: dict | None) -> None:
    marker = json.loads((site / "sitepulse-pages.json").read_text(encoding="utf-8"))
    latest_snapshot = site / "reports" / f"{marker['run_id']}-{marker['run_attempt']}" / "product-status.json"
    if latest_snapshot.is_file():
        shutil.copyfile(latest_snapshot, site / "product-status.json")
    else:
        latest_summary = json.loads((site / "reports" / f"{marker['run_id']}-{marker['run_attempt']}" /
                                     "summary.json").read_text(encoding="utf-8"))
        _write_json(site / "product-status.json", {"schema": 1, "run_id": latest_summary["run_id"],
                                                   "status": latest_summary["status"],
                                                   "junit": latest_summary["junit"]})
    snapshots = ps.load_site_snapshots(site)
    full = [snapshot for snapshot in snapshots if snapshot.get("totals") and snapshot.get("epics")
            and snapshot.get("scenarios") is not None]
    if full:
        (site / "index.html").write_text(ps.render_html(snapshots), encoding="utf-8")
    else:
        run = html.escape(str(marker["run_id"]))
        (site / "index.html").write_text(f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SitePulse product status</title><style>body{{font:16px system-ui,sans-serif;max-width:900px;margin:3rem auto;padding:0 1rem;color:#172033}}a{{color:#1459a6}}.card{{padding:1rem;border:1px solid #d8dee8;border-radius:10px}}</style></head>
<body><h1>SitePulse product status</h1><p>The safe historical coverage dashboard is being rebuilt from reviewed report data.</p>
<section class="card"><h2>Latest CI run</h2><p>Run <a href="https://github.com/gurkanindibay/ai-powered-engineering/actions/runs/{run}">{run}</a></p>
<p><a href="latest.html">Latest report</a> · <a href="history.html">All runs</a></p></section></body></html>\n""", encoding="utf-8")


def verify_local(site: Path, expected: dict) -> None:
    marker_path = site / "sitepulse-pages.json"
    if not marker_path.is_file():
        raise ValueError("sitepulse-pages.json is missing")
    marker = json.loads(marker_path.read_text(encoding="utf-8"))
    for key in ("run_id", "run_number", "run_attempt", "commit", "action_run_id"):
        if str(marker.get(key)) != str(expected.get(key)):
            raise ValueError(f"published identity mismatch for {key}")
    report_folder = f"reports/{marker['run_id']}-{marker['run_attempt']}/"
    report_key = report_folder + "index.html"
    for relative in ("index.html", "latest.html", "history.html", report_key):
        if not (site / relative).is_file():
            raise ValueError(f"required Pages route is missing: {relative}")
    for relative, link in (("index.html", "latest.html"), ("index.html", "history.html"),
                           ("history.html", report_folder), ("latest.html", "history.html")):
        if link not in (site / relative).read_text(encoding="utf-8"):
            raise ValueError(f"required Pages link {link} is missing from {relative}")


def verify_remote(base_url: str, expected: dict, attempts: int = 12, delay: float = 10) -> dict:
    base = base_url.rstrip("/") + "/"
    paths = ("sitepulse-pages.json", "index.html", "latest.html", "history.html",
             f"reports/{expected['run_id']}-{expected['run_attempt']}/index.html")
    last_error = ""
    for attempt in range(attempts):
        try:
            documents = {}
            for path in paths:
                request = Request(base + path, headers={"Cache-Control": "no-cache", "User-Agent": "SitePulse Pages verifier"})
                with urlopen(request, timeout=20) as response:
                    if response.status != 200:
                        raise ValueError(f"{path} returned HTTP {response.status}")
                    documents[path] = response.read().decode("utf-8")
            marker = json.loads(documents["sitepulse-pages.json"])
            for key in ("run_id", "run_number", "run_attempt", "commit", "action_run_id"):
                if str(marker.get(key)) != str(expected.get(key)):
                    raise ValueError(f"served revision does not match Actions run: {key} differs")
            required_links = {"index.html": ("latest.html", "history.html"),
                              "history.html": (f"reports/{expected['run_id']}-{expected['run_attempt']}/",),
                              "latest.html": ("history.html",)}
            for source, links in required_links.items():
                if any(link not in documents[source] for link in links):
                    raise ValueError(f"{source} is missing an expected report link")
            return {"url": base, "identity": marker, "routes": list(paths)}
        except (OSError, ValueError, json.JSONDecodeError, HTTPError, URLError) as error:
            last_error = str(error)
            if attempt + 1 < attempts:
                time.sleep(delay)
    raise ValueError(f"Pages verification failed after {attempts} attempts: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build", help="sanitize archive state and build Pages tree")
    build_parser.add_argument("--site", type=Path, required=True)
    build_parser.add_argument("--report", type=Path, required=True)
    build_parser.add_argument("--run-id", required=True)
    build_parser.add_argument("--attempt", required=True)
    build_parser.add_argument("--run-number", type=int, required=True)
    build_parser.add_argument("--commit", required=True)
    build_parser.add_argument("--action-run-id")
    build_parser.add_argument("--require-public-report", action="store_true",
                              help="fail closed when the reviewed inventory artifact is absent")
    verify_parser = subparsers.add_parser("verify-local", help="check expected routes and identity in artifact tree")
    verify_parser.add_argument("--site", type=Path, required=True)
    remote_parser = subparsers.add_parser("verify-remote", help="check served revision and routes")
    remote_parser.add_argument("--url", required=True)
    remote_parser.add_argument("--run-id", required=True)
    remote_parser.add_argument("--attempt", type=int, required=True)
    remote_parser.add_argument("--run-number", type=int, required=True)
    remote_parser.add_argument("--commit", required=True)
    remote_parser.add_argument("--action-run-id", required=True)
    remote_parser.add_argument("--attempts", type=int, default=12)
    args = parser.parse_args()
    try:
        if args.command == "build":
            result = build(args.site, args.report, args.run_id, args.attempt, args.run_number,
                           args.commit, args.action_run_id, args.require_public_report)
        elif args.command == "verify-local":
            marker = json.loads((args.site / "sitepulse-pages.json").read_text(encoding="utf-8"))
            verify_local(args.site, marker)
            result = {"verified": True, "site": str(args.site)}
        else:
            result = verify_remote(args.url, {"run_id": args.run_id, "run_attempt": args.attempt,
                                              "run_number": args.run_number, "commit": args.commit,
                                              "action_run_id": args.action_run_id}, args.attempts)
        print(json.dumps(result))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.exit(1, f"pages_site.py: error: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
