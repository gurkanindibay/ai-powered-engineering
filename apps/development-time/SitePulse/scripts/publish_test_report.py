#!/usr/bin/env python3
"""Build a cumulative static site from a CI e2e test report.

The destination is the checked-out GitHub Pages branch. Each workflow run is
kept under reports/<run-id>-<attempt>/. The root page is the product status
dashboard (scripts/product_status.py: coverage per epic and trends over every
archived run); latest.html is the newest detailed feature report and
history.html links to every archived report.
"""
from __future__ import annotations

import argparse
import html
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import product_status as ps  # noqa: E402


def build(report: Path, site: Path, run_id: str, attempt: str) -> dict:
    summary_path = report / "summary.json"
    page_path = report / "feature-report.html"
    if not summary_path.is_file() or not page_path.is_file():
        raise ValueError("report directory must contain summary.json and feature-report.html")
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    key = f"{run_id}-{attempt}"
    destination = site / "reports" / key
    destination.mkdir(parents=True, exist_ok=True)
    page = page_path.read_text(encoding="utf-8")
    archived_page = add_history_link(page, "../../history.html")
    (destination / "index.html").write_text(archived_page, encoding="utf-8")
    for name in ("test-report.md", "summary.json", "product-status.json"):
        source = report / name
        if source.is_file():
            shutil.copyfile(source, destination / name)
    latest_page = add_history_link(page, "history.html")
    (site / "latest.html").write_text(latest_page, encoding="utf-8")

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
    latest_key = reports[0][1] if reports else key
    table = "\n".join(rows) or '<tr><td colspan="5">No reports yet.</td></tr>'
    history = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SitePulse execution history</title>
<style>body{{font:16px system-ui,sans-serif;max-width:1000px;margin:3rem auto;padding:0 1rem;color:#172033}}h1{{margin-bottom:.3rem}}a{{color:#1459a6}}table{{border-collapse:collapse;width:100%;margin-top:1.5rem}}th,td{{padding:.7rem;text-align:left;border-bottom:1px solid #d8dee8}}th{{background:#f2f5f9}}.latest{{font-size:1.15rem}}</style></head>
<body><h1>SitePulse execution history</h1><p class="latest"><a href="index.html">Product status</a> · <a href="latest.html">Latest report</a></p>
<table><thead><tr><th>Run</th><th>Report ID</th><th>Status</th><th>Passed</th><th>Failed / errors</th></tr></thead><tbody>{table}</tbody></table>
</body></html>\n"""
    (site / "history.html").write_text(history, encoding="utf-8")
    snapshots = ps.load_site_snapshots(site)
    dashboard = any(snapshot.get("totals") for snapshot in snapshots)
    if dashboard:
        (site / "index.html").write_text(ps.render_html(snapshots), encoding="utf-8")
        latest_status = next(s for s in reversed(snapshots) if s.get("totals"))
        (site / "product-status.json").write_text(json.dumps(latest_status, indent=1) + "\n", encoding="utf-8")
    else:
        # Reports made before product_status.py existed carry no snapshot: keep the feature report as the root.
        (site / "index.html").write_text(latest_page, encoding="utf-8")
    return {"reports": len(reports), "latest": latest_key, "site": str(site), "product_status": dashboard}


def add_history_link(page: str, href: str) -> str:
    """Add archive navigation to a self-contained feature dashboard."""
    home = href.replace("history.html", "index.html")
    link = (f'<p class="report-navigation"><a href="{html.escape(home, quote=True)}">Product status</a> \u00b7 '
            f'<a href="{html.escape(href, quote=True)}">View previous executions</a></p>')
    heading = "<h1>Feature test report</h1>"
    return page.replace(heading, heading + link, 1) if heading in page else page


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
