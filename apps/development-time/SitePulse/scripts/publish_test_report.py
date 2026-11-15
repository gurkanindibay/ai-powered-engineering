#!/usr/bin/env python3
"""Build a cumulative static site from a CI e2e test report.

The destination is the checked-out GitHub Pages branch. Each workflow run is
kept under reports/<run-id>-<attempt>/, while index.html and latest.html point
to the newest report.
"""
from __future__ import annotations

import argparse
import html
import json
import shutil
from pathlib import Path


def build(report: Path, site: Path, run_id: str, attempt: str) -> dict:
    summary_path = report / "summary.json"
    page_path = report / "feature-report.html"
    if not summary_path.is_file() or not page_path.is_file():
        raise ValueError("report directory must contain summary.json and feature-report.html")
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    key = f"{run_id}-{attempt}"
    destination = site / "reports" / key
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(page_path, destination / "index.html")
    for name in ("test-report.md", "summary.json"):
        source = report / name
        if source.is_file():
            shutil.copyfile(source, destination / name)
    shutil.copyfile(page_path, site / "latest.html")

    reports = []
    report_root = site / "reports"
    for summary_file in report_root.glob("*/summary.json"):
        try:
            item = json.loads(summary_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        reports.append((str(item.get("run_id", "")), summary_file.parent.name, item))
    reports.sort(key=lambda row: (row[0], row[1]), reverse=True)
    rows = []
    for _, folder, item in reports:
        label = html.escape(str(item.get("task") or "CI run"))
        run = html.escape(str(item.get("run_id") or folder))
        status = html.escape(str(item.get("status", "UNKNOWN")))
        junit = item.get("junit", {})
        tests = int(junit.get("tests", 0))
        passed = int(junit.get("passed", 0))
        failed = int(junit.get("failures", 0)) + int(junit.get("errors", 0))
        rows.append(
            f'<tr><td><a href="reports/{html.escape(folder, quote=True)}/">{label}</a></td>'
            f"<td>{run}</td><td>{status}</td><td>{passed}/{tests}</td><td>{failed}</td></tr>"
        )
    table = "\n".join(rows) or '<tr><td colspan="5">No reports yet.</td></tr>'
    latest_key = reports[0][1] if reports else key
    index = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SitePulse test reports</title>
<style>body{{font:16px system-ui,sans-serif;max-width:1000px;margin:3rem auto;padding:0 1rem;color:#172033}}h1{{margin-bottom:.3rem}}a{{color:#1459a6}}table{{border-collapse:collapse;width:100%;margin-top:1.5rem}}th,td{{padding:.7rem;text-align:left;border-bottom:1px solid #d8dee8}}th{{background:#f2f5f9}}.latest{{font-size:1.15rem}}</style></head>
<body><h1>SitePulse test reports</h1><p class="latest"><a href="reports/{html.escape(latest_key, quote=True)}/">Open latest report</a> · <a href="latest.html">Latest dashboard</a></p>
<h2>History</h2><table><thead><tr><th>Run</th><th>Report ID</th><th>Status</th><th>Passed</th><th>Failed / errors</th></tr></thead><tbody>{table}</tbody></table>
</body></html>\n"""
    (site / "index.html").write_text(index, encoding="utf-8")
    return {"reports": len(reports), "latest": latest_key, "site": str(site)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True, help="directory containing ci_test_report.py output")
    parser.add_argument("--site", type=Path, required=True, help="GitHub Pages site directory to update")
    parser.add_argument("--run-id", required=True, help="GitHub workflow run ID")
    parser.add_argument("--attempt", required=True, help="GitHub workflow run attempt")
    parser.add_argument("--json", action="store_true", help="print a JSON summary")
    args = parser.parse_args()
    result = build(args.report, args.site, args.run_id, args.attempt)
    print(json.dumps(result) if args.json else f"Published {result['latest']}; {result['reports']} report(s) in {args.site}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
