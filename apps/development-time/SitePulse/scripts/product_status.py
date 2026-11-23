#!/usr/bin/env python3
"""Product status dashboard: epic/story test coverage and trends for the published test report.

The feature test report (scripts/feature_traceability.py html) is written for engineers: every
scenario, step and run. This tool answers the product questions on one page:
* how much of each epic is specified, automated and passing in CI,
* how the product scope grew (stories, acceptance scenarios, automation) over time,
* what was added recently, and whether the CI runs are stable.

It produces two things:
* a snapshot (product-status.json) of one CI run: totals, one row per epic, the state of every
  scenario, the catalogue growth read from git history, and the recent additions;
* the dashboard (one self-contained HTML page) from the snapshots of every published run.

scripts/ci_test_report.py writes the snapshot of a CI run; scripts/publish_test_report.py keeps
each run's snapshot on the GitHub Pages branch and renders the dashboard as the site's index.html.

Scenario states (from the tests of ONE run, never from older runs):
  passing    automated and every test of the scenario passed in this run
  failing    automated and a test of the scenario failed
  no_result  automated, but this run has no result for it (skipped, or verified by a suite that
             does not write execution records, such as the Rust and Flutter unit tests)
  planned    specified in Gherkin and tagged @pending: not automated yet

Usage:
  python3 scripts/product_status.py snapshot --out /tmp/product-status.json
  python3 scripts/product_status.py snapshot --executions e2e/.artifacts/executions.jsonl --json
  python3 scripts/product_status.py html --snapshot /tmp/product-status.json --out /tmp/status.html
  python3 scripts/product_status.py html --site /tmp/test-report-site --out /tmp/status.html

Exit code: 0; 2 on bad arguments or unreadable input.
"""
from __future__ import annotations

import argparse
import html
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import feature_traceability as ft  # noqa: E402

SCHEMA = 1
STATES = ("passing", "failing", "no_result", "planned")
STATE_LABELS = {"passing": "Passing", "failing": "Failing", "no_result": "Automated, no CI result",
                "planned": "Planned (not automated)"}
SHORT_LABELS = {"passing": "passing", "failing": "failing", "no_result": "no CI result", "planned": "planned"}
HEALTH_LABELS = {"failing": "Failing", "verified": "Verified", "in_progress": "In progress",
                 "not_automated": "Not automated", "not_specified": "No scenarios"}
HEALTH_ICONS = {"failing": "✕", "verified": "✓", "in_progress": "◐", "not_automated": "○",
                "not_specified": "–"}
RUN_ID_TIME = re.compile(r"^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z")
MAX_CHANGE_SAMPLES = 4
MAX_RUNS_SHOWN = 30


# ---------------------------------------------------------------- snapshot

def scenario_state(mode: str, statuses: list[str]) -> str:
    """State of one scenario from the statuses of its tests in one run."""
    if mode == "pending":
        return "planned"
    ran = [s for s in statuses if s not in ("SKIPPED", "NOT RUN")]
    if not ran:
        return "no_result"
    return "passing" if all(s == "PASS" for s in ran) else "failing"


def epic_health(row: dict) -> str:
    if row["failing"]:
        return "failing"
    if not row["scenarios"]:
        return "not_specified"
    if not row["automated"]:
        return "not_automated"
    return "verified" if row["passing"] == row["scenarios"] else "in_progress"


def build_snapshot(catalogue: ft.Catalogue, run_records: list[dict], summary: dict | None = None,
                   history: dict | None = None, now: datetime | None = None,
                   inventory: dict | None = None) -> dict:
    """The product status of one run. `run_records` are the execution records of that run only."""
    summary = summary or {}
    now = now or datetime.now(timezone.utc)
    statuses: dict[str, list[str]] = defaultdict(list)
    for record in run_records:
        if record.get("scenario"):
            statuses[record["scenario"]].append(record.get("status", ""))
    by_story = catalogue.by_story()
    scenarios: dict[str, dict] = {}
    epics = []
    for epic in sorted(catalogue.epics):
        number = epic.split("-")[1]
        story_ids = sorted(s for s in catalogue.stories if s.startswith(f"STORY-{number}-"))
        row = {"id": epic, "title": catalogue.epics[epic], "stories": len(story_ids),
               "stories_with_scenarios": 0, "stories_passing": 0, "scenarios": 0, "automated": 0,
               **{state: 0 for state in STATES}}
        for story in story_ids:
            states = []
            for scenario in by_story.get(story, []):
                state = scenario_state(scenario.mode, statuses.get(scenario.id, []))
                scenarios[scenario.id] = {"state": state, "name": scenario.name, "epic": epic, "story": story}
                states.append(state)
            if states:
                row["stories_with_scenarios"] += 1
                row["stories_passing"] += all(state == "passing" for state in states)
            for state in states:
                row[state] += 1
            row["scenarios"] += len(states)
        row["automated"] = row["scenarios"] - row["planned"]
        row["health"] = epic_health(row)
        epics.append(row)
    keys = ("stories", "stories_with_scenarios", "stories_passing", "scenarios", "automated", *STATES)
    totals = {key: sum(row[key] for row in epics) for key in keys}
    totals["epics"] = len(epics)
    totals["epics_verified"] = sum(row["health"] == "verified" for row in epics)
    totals["epics_failing"] = sum(row["health"] == "failing" for row in epics)
    history = history or {"points": [], "changes": []}

    inventory = inventory or {}
    suites = [
        {
            "suite": s.get("suite", ""),
            "runner": s.get("runner", ""),
            "producer": s.get("producer", ""),
            "status": s.get("status", "collected"),
            "case_count": int(s.get("case_count", 0)),
            "missing_shards": list(s.get("missing_shards", []))
        } for s in inventory.get("suites", [])
    ]
    gates = [
        {
            "gate": g.get("gate", ""),
            "status": g.get("status", "passed"),
            "duration_s": g.get("duration_s"),
            "exit_codes": list(g.get("exit_codes", []))
        } for g in inventory.get("gates", [])
    ]
    unmapped = [
        {
            "runner": c.get("runner", ""),
            "suite": c.get("suite", ""),
            "native_id": c.get("native_id", ""),
            "parameter_id": c.get("parameter_id"),
            "status": c.get("status", "passed"),
            "duration_s": c.get("duration_s")
        } for c in inventory.get("unmapped_cases", [])
    ]
    if not suites and summary.get("junit", {}).get("tests"):
        suites = [{
            "suite": "e2e",
            "runner": "pytest-playwright",
            "producer": "e2e",
            "status": "collected",
            "case_count": int(summary["junit"]["tests"]),
            "missing_shards": []
        }]
    inv_data = {"suites": suites, "gates": gates, "unmapped_cases": unmapped}

    return {"schema": SCHEMA, "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "run_id": summary.get("run_id", ""), "commit": summary.get("commit", ""),
            "task": summary.get("task", ""), "status": summary.get("status", "NO RESULTS"),
            "junit": summary.get("junit", {}), "totals": totals, "epics": epics, "scenarios": scenarios,
            "catalogue_history": history["points"], "recent_changes": history["changes"],
            "inventory": inv_data}


def snapshot_from_summary(summary: dict) -> dict | None:
    """A run point for reports published before snapshots existed (test counts only, no epics)."""
    m = RUN_ID_TIME.match(str(summary.get("run_id", "")))
    if not m:
        return None
    y, mo, d, h, mi, s = m.groups()
    junit = summary.get("junit", {})
    tests = int(junit.get("tests", 0)) if isinstance(junit, dict) else 0
    suites = [{
        "suite": "e2e",
        "runner": "pytest-playwright",
        "producer": "e2e",
        "status": "collected",
        "case_count": tests,
        "missing_shards": []
    }] if tests else []
    return {"schema": 0, "generated_at": f"{y}-{mo}-{d}T{h}:{mi}:{s}Z", "run_id": summary.get("run_id", ""),
            "commit": summary.get("commit", ""), "task": summary.get("task", ""),
            "status": summary.get("status", "UNKNOWN"), "junit": junit,
            "inventory": {"suites": suites, "gates": [], "unmapped_cases": []}}


# ---------------------------------------------------------------- catalogue history (git)

def _git(args: list[str], cwd: Path) -> bytes | None:
    try:
        done = subprocess.run(["git", *args], cwd=cwd, capture_output=True, check=False)
    except OSError:
        return None
    return done.stdout if done.returncode == 0 else None


def _catalogue_at(tree: Path) -> tuple[dict, dict, dict]:
    """({epic: title}, {story: title}, {scenario: (name, mode)}) of an extracted .specify tree."""
    epics, stories = ft.load_stories(tree / "requirements")
    scenarios: dict[str, tuple[str, str]] = {}
    features = tree / "features"
    for path in sorted(features.rglob("*.feature")) if features.is_dir() else []:
        _, found, _ = ft.parse_feature(path.read_text(encoding="utf-8", errors="replace"),
                                       path.relative_to(features).as_posix())
        scenarios.update({s.id: (s.name, s.mode) for s in found if s.id})
    return epics, stories, scenarios


def _point(day: str, epics: dict, stories: dict, scenarios: dict) -> dict:
    covered = {ft.parents_of(sid)[1] for sid in scenarios}
    return {"date": day, "epics": len(epics), "stories": len(stories),
            "stories_with_scenarios": len(covered & set(stories)), "scenarios": len(scenarios),
            "automated": sum(mode != "pending" for _, mode in scenarios.values())}


def _changes(day: str, before: tuple[dict, dict, dict], after: tuple[dict, dict, dict]) -> list[dict]:
    """What a day added, one entry per epic: new stories, new scenarios, newly automated scenarios."""
    grouped: dict[str, dict] = {}

    def entry(epic: str) -> dict:
        return grouped.setdefault(epic, {"date": day, "epic": epic, "title": after[0].get(epic, epic),
                                         "new_stories": 0, "new_scenarios": 0, "newly_automated": 0, "items": 0,
                                         "samples": []})

    def sample(item: dict, text: str) -> None:
        item["items"] += 1
        if len(item["samples"]) < MAX_CHANGE_SAMPLES:
            item["samples"].append(text)

    for story, title in sorted(after[1].items()):
        if story not in before[1]:
            item = entry("EPIC-" + story.split("-")[1])
            item["new_stories"] += 1
            sample(item, f"{story}: {title}")
    for sid, (name, mode) in sorted(after[2].items()):
        item = None
        if sid not in before[2]:
            item = entry(ft.parents_of(sid)[0])
            item["new_scenarios"] += 1
            item["newly_automated"] += mode != "pending"
        elif before[2][sid][1] == "pending" and mode != "pending":
            item = entry(ft.parents_of(sid)[0])
            item["newly_automated"] += 1
        if item is not None and not item["new_stories"]:
            sample(item, f"{sid}: {name}")
    return [grouped[epic] for epic in sorted(grouped)]


def catalogue_history(root: Path = ft.ROOT, max_days: int = 400) -> dict:
    """Catalogue size per day from the git history of .specify/requirements and .specify/features.

    One point per day that changed either directory (the day's last commit). A shallow clone or a
    directory outside git yields what is reachable, possibly nothing: the dashboard then falls
    back to the snapshots of the published runs.
    """
    top_raw = _git(["rev-parse", "--show-toplevel"], root)
    if top_raw is None:
        return {"points": [], "changes": []}
    top = Path(top_raw.decode().strip())
    prefix = root.resolve().relative_to(top.resolve()).as_posix()
    base = ".specify" if prefix == "." else f"{prefix}/.specify"
    paths = [f"{base}/requirements", f"{base}/features"]
    log = _git(["log", "--format=%H %cs", "--", *paths], top)
    last_commit_of_day: dict[str, str] = {}
    for line in (log or b"").decode().splitlines():  # newest first
        commit, day = line.split()
        last_commit_of_day.setdefault(day, commit)
    days = sorted(last_commit_of_day)[-max_days:]
    points, changes = [], []
    previous: tuple[dict, dict, dict] | None = None
    for day in days:
        commit = last_commit_of_day[day]
        present = [p for p in paths if (_git(["ls-tree", "--name-only", commit, "--", p], top) or b"").strip()]
        state: tuple[dict, dict, dict] = ({}, {}, {})
        if present:
            archive = _git(["archive", "--format=tar", commit, "--", *present], top)
            if archive is None:
                continue
            with tempfile.TemporaryDirectory() as tmp:
                with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
                    tar.extractall(tmp, filter="data")
                state = _catalogue_at(Path(tmp) / base)
        points.append(_point(day, *state))
        if previous is not None:
            changes += _changes(day, previous, state)
        previous = state
    return {"points": points, "changes": changes[::-1][:200]}


# ---------------------------------------------------------------- dashboard data

def _day(snapshot: dict) -> str:
    return snapshot["generated_at"][:10]


def trend_series(snapshots: list[dict]) -> dict:
    """Daily series for the charts: catalogue growth from git, results from the published runs."""
    full = [s for s in snapshots if s.get("totals")]
    points = {p["date"]: dict(p) for p in (full[-1]["catalogue_history"] if full else [])}
    for snap in full:  # oldest first: the last run of a day wins
        t = snap["totals"]
        points.setdefault(_day(snap), {"date": _day(snap), "epics": t["epics"]}).update(
            stories=t["stories"], stories_with_scenarios=t["stories_with_scenarios"], scenarios=t["scenarios"],
            automated=t["automated"], passing=t["passing"], failing=t["failing"])
    days = [points[d] for d in sorted(points)]
    runs = [{"at": s["generated_at"], "status": s.get("status", ""), "href": s.get("href", ""),
             "task": s.get("task", ""), "commit": s.get("commit", "")[:7],
             "passed": int(s.get("junit", {}).get("passed", 0)),
             "failed": int(s.get("junit", {}).get("failures", 0)) + int(s.get("junit", {}).get("errors", 0)),
             "skipped": int(s.get("junit", {}).get("skipped", 0))} for s in snapshots[-MAX_RUNS_SHOWN:]]
    return {"days": days, "runs": runs}


def _baseline(days: list[dict], key: str, window: int = 30) -> tuple[int, str] | None:
    """(change, since) of `key` over the last `window` days, or since the first known day."""
    known = [d for d in days if d.get(key) is not None]
    if len(known) < 2:
        return None
    latest = known[-1]
    cutoff = (date.fromisoformat(latest["date"]) - timedelta(days=window)).isoformat()
    older = [d for d in known[:-1] if d["date"] <= cutoff]
    base = older[-1] if older else known[0]
    since = f"in {window} days" if older else f"since {base['date']}"
    return latest[key] - base[key], since


# ---------------------------------------------------------------- dashboard HTML

def _esc(value) -> str:
    return html.escape(str(value), quote=True)


def _pct(part: int, whole: int) -> int:
    return round(100 * part / whole) if whole else 0


def _delta(change: tuple[int, str] | None, good_when_up: bool = True) -> str:
    if change is None:
        return '<span class="delta flat">no earlier data</span>'
    amount, since = change
    if amount == 0:
        return f'<span class="delta flat">no change {_esc(since)}</span>'
    tone = "up" if (amount > 0) == good_when_up else "down"
    arrow = "▲" if amount > 0 else "▼"
    return f'<span class="delta {tone}">{arrow} {amount:+d} {_esc(since)}</span>'


def _tile(label: str, value: str, note: str, delta: str = "") -> str:
    return (f'<div class="tile"><span class="tile-label">{_esc(label)}</span><b>{value}</b>'
            f'<span class="tile-note">{note}</span>{delta}</div>')


def _bar(row: dict) -> str:
    if not row["scenarios"]:
        return '<div class="bar empty" title="No acceptance scenarios yet"></div>'
    parts = "".join(
        f'<i class="seg {state}" style="flex:{row[state]}" title="{row[state]} {_esc(STATE_LABELS[state].lower())}"></i>'
        for state in STATES if row[state])
    return f'<div class="bar">{parts}</div>'


def _epic_row(row: dict) -> str:
    counts = " · ".join(f"{row[state]} {STATE_LABELS[state].split(' ')[0].lower().rstrip(',')}"
                             for state in STATES if row[state]) or "no scenarios"
    health = row["health"]
    return (
        f'<tr><td class="epic"><span class="epic-id">{_esc(row["id"])}</span> {_esc(row["title"])}</td>'
        f'<td class="num">{row["stories_with_scenarios"]}/{row["stories"]}</td>'
        f'<td class="mix">{_bar(row)}<span class="counts">{_esc(counts)}</span></td>'
        f'<td class="num">{_pct(row["automated"], row["scenarios"])}%</td>'
        f'<td class="num">{_pct(row["passing"], row["scenarios"])}%</td>'
        f'<td><span class="health {health}"><span aria-hidden="true">{HEALTH_ICONS[health]}</span> '
        f'{_esc(HEALTH_LABELS[health])}</span></td></tr>')


def _attention(latest: dict) -> str:
    failing = sorted((sid, s) for sid, s in latest["scenarios"].items() if s["state"] == "failing")
    items = []
    if failing:
        rows = "".join(f'<li><span class="epic-id">{_esc(sid)}</span> {_esc(s["name"])} '
                       f'<span class="muted">({_esc(s["epic"])})</span></li>' for sid, s in failing[:25])
        more = f'<li class="muted">and {len(failing) - 25} more</li>' if len(failing) > 25 else ""
        items.append(f'<div class="note bad"><h3>{HEALTH_ICONS["failing"]} {len(failing)} failing '
                     f'scenario{"s" if len(failing) != 1 else ""}</h3><ul>{rows}{more}</ul></div>')
    else:
        items.append(f'<div class="note good"><h3>{HEALTH_ICONS["verified"]} No failing scenarios</h3>'
                     '<p>Every scenario that ran in the latest CI run passed.</p></div>')
    gaps = sorted((r for r in latest["epics"] if r["planned"]), key=lambda r: -r["planned"])[:3]
    if gaps:
        rows = "".join(f'<li><span class="epic-id">{_esc(r["id"])}</span> {_esc(r["title"])}: '
                       f'<b>{r["planned"]}</b> of {r["scenarios"]} scenarios not automated</li>' for r in gaps)
        items.append(f'<div class="note"><h3>Largest automation gaps</h3><ul>{rows}</ul></div>')
    unspecified = [r for r in latest["epics"] if r["stories"] > r["stories_with_scenarios"]]
    if unspecified:
        total = sum(r["stories"] - r["stories_with_scenarios"] for r in unspecified)
        rows = "".join(f'<li><span class="epic-id">{_esc(r["id"])}</span> '
                       f'{r["stories"] - r["stories_with_scenarios"]} of {r["stories"]} stories</li>'
                       for r in sorted(unspecified, key=lambda r: r["stories_with_scenarios"] - r["stories"])[:5])
        items.append(f'<div class="note"><h3>{total} stor{"ies" if total != 1 else "y"} without acceptance '
                     f'scenarios</h3><ul>{rows}</ul></div>')
    return "".join(items)


def _changes_html(changes: list[dict], limit_days: int = 8) -> str:
    by_day: dict[str, list[dict]] = defaultdict(list)
    for change in changes:
        by_day[change["date"]].append(change)
    blocks = []
    for day in sorted(by_day, reverse=True)[:limit_days]:
        rows = []
        for change in by_day[day]:
            parts = []
            if change["new_stories"]:
                parts.append(f'{change["new_stories"]} new stor{"y" if change["new_stories"] == 1 else "ies"}')
            if change["new_scenarios"]:
                parts.append(f'{change["new_scenarios"]} new scenario{"" if change["new_scenarios"] == 1 else "s"}')
            if change["newly_automated"]:
                parts.append(f'{change["newly_automated"]} automated')
            samples = "".join(f"<li>{_esc(s)}</li>" for s in change["samples"])
            hidden = change.get("items", 0) - len(change["samples"])
            more = f'<li class="muted">and {hidden} more</li>' if hidden > 0 else ""
            rows.append(f'<details class="change"><summary><span class="epic-id">{_esc(change["epic"])}</span> '
                        f'{_esc(change["title"])} <span class="chips">'
                        + "".join(f'<span class="chip">{_esc(p)}</span>' for p in parts)
                        + f'</span></summary><ul>{samples}{more}</ul></details>')
        blocks.append(f'<div class="day"><h3>{_esc(day)}</h3>{"".join(rows)}</div>')
    return "".join(blocks) or '<p class="muted">No additions recorded yet.</p>'


def _trend_table(days: list[dict]) -> str:
    rows = "".join(
        f'<tr><td>{_esc(d["date"])}</td><td class="num">{d.get("stories", "")}</td>'
        f'<td class="num">{d.get("stories_with_scenarios", "")}</td><td class="num">{d.get("scenarios", "")}</td>'
        f'<td class="num">{d.get("automated", "")}</td>'
        f'<td class="num">{"" if d.get("passing") is None else d["passing"]}</td></tr>' for d in days[::-1])
    return ('<details class="table-view"><summary>Show trend data as a table</summary><div class="scroll"><table>'
            '<thead><tr><th>Date</th><th class="num">Stories</th><th class="num">Stories with scenarios</th>'
            '<th class="num">Scenarios</th><th class="num">Automated</th><th class="num">Passing in CI</th></tr>'
            f'</thead><tbody>{rows}</tbody></table></div></details>')


def _inventory_html(latest: dict) -> str:
    inventory = latest.get("inventory", {})
    if not inventory:
        return ""
    suites = inventory.get("suites", [])
    gates = inventory.get("gates", [])
    unmapped = inventory.get("unmapped_cases", [])
    blocks = []
    if suites:
        rows = "".join(
            f'<tr><td><b>{_esc(s["suite"])}</b></td><td>{_esc(s.get("runner", "-"))}</td>'
            f'<td>{_esc(s.get("producer", "-"))}</td>'
            f'<td><span class="health {_esc(s.get("status", "collected").lower())}">{_esc(s.get("status", "collected"))}</span></td>'
            f'<td class="num">{s.get("case_count", 0)}</td>'
            f'<td>{_esc(", ".join(s.get("missing_shards", [])) or "—")}</td></tr>' for s in suites)
        blocks.append(
            f'<h3>Suites</h3><div class="scroll"><table><thead><tr><th>Suite</th><th>Runner</th>'
            f'<th>Producer</th><th>Status</th><th class="num">Cases</th><th>Missing shards</th></tr></thead>'
            f'<tbody>{rows}</tbody></table></div>'
        )
    if gates:
        rows = "".join(
            (f'<tr><td><code>{_esc(g["gate"])}</code></td>'
             f'<td><span class="health {_esc(g.get("status", "passed").lower())}">{_esc(g.get("status", "passed"))}</span></td>'
             f'<td class="num">{round(float(g["duration_s"]), 1)}s</td>' if g.get("duration_s") is not None else
             f'<tr><td><code>{_esc(g["gate"])}</code></td>'
             f'<td><span class="health {_esc(g.get("status", "passed").lower())}">{_esc(g.get("status", "passed"))}</span></td>'
             f'<td class="num">—</td>')
            + f'<td>{_esc(", ".join(str(x) for x in g.get("exit_codes", [])) or "0")}</td></tr>' for g in gates)
        blocks.append(
            f'<h3>Gates</h3><div class="scroll"><table><thead><tr><th>Gate</th><th>Status</th>'
            f'<th class="num">Duration</th><th>Exit codes</th></tr></thead>'
            f'<tbody>{rows}</tbody></table></div>'
        )
    if unmapped:
        rows = "".join(
            (f'<tr><td>{_esc(c.get("suite", "-"))}</td><td>{_esc(c.get("runner", "-"))}</td>'
             f'<td><code>{_esc(c.get("native_id", "-"))}</code></td>'
             f'<td>{_esc(c.get("parameter_id") or "—")}</td>'
             f'<td><span class="health {_esc(c.get("status", "passed").lower())}">{_esc(c.get("status", "passed"))}</span></td>'
             f'<td class="num">{round(float(c["duration_s"]), 2)}s</td></tr>') if c.get("duration_s") is not None else
            (f'<tr><td>{_esc(c.get("suite", "-"))}</td><td>{_esc(c.get("runner", "-"))}</td>'
             f'<td><code>{_esc(c.get("native_id", "-"))}</code></td>'
             f'<td>{_esc(c.get("parameter_id") or "—")}</td>'
             f'<td><span class="health {_esc(c.get("status", "passed").lower())}">{_esc(c.get("status", "passed"))}</span></td>'
             f'<td class="num">—</td></tr>')
            for c in unmapped)
        blocks.append(
            f'<h3>Unmapped test cases ({len(unmapped)})</h3><div class="scroll"><table><thead><tr>'
            f'<th>Suite</th><th>Runner</th><th>Test ID</th><th>Parameter / example</th><th>Status</th>'
            f'<th class="num">Duration</th></tr></thead><tbody>{rows}</tbody></table></div>'
        )
    elif suites or gates:
        blocks.append('<p class="muted">All executed tests are mapped to acceptance scenarios.</p>')
    if not blocks:
        return ""
    return f'<section id="inventory"><h2>Test inventory</h2><p class="lede">Suites, gates, and unmapped test cases for this run.</p>{"".join(blocks)}</section>'


def render_html(snapshots: list[dict], links: dict | None = None) -> str:
    """The dashboard. `snapshots` are oldest first; the newest one with epics drives the page."""
    links = {"detail": "latest.html", "history": "history.html", **(links or {})}
    full = [s for s in snapshots if s.get("totals")]
    if not full:
        raise ValueError("no product status snapshot to render")
    latest, previous = full[-1], full[-2] if len(full) > 1 else None
    t = latest["totals"]
    trends = trend_series(snapshots)
    days = trends["days"]

    def run_delta(key: str, good_when_up: bool = True) -> str:
        if previous is None:
            return _delta(None)
        return _delta((t[key] - previous["totals"][key], "vs previous run"), good_when_up)

    junit = latest.get("junit", {})
    failed_tests = int(junit.get("failures", 0)) + int(junit.get("errors", 0))
    ok = latest["status"] == "PASS"
    verdict = "All tests passed" if ok else ("No test results" if not junit.get("tests") else
                                             f"{failed_tests} test{'s' if failed_tests != 1 else ''} failed")
    tiles = "".join([
        _tile("Latest CI run", f'<span class="health {"verified" if ok else "failing"}">'
              f'{HEALTH_ICONS["verified" if ok else "failing"]} {_esc(latest["status"])}</span>',
              f'{_esc(verdict)}: {int(junit.get("passed", 0))} of {int(junit.get("tests", 0))} tests'),
        _tile("Epics verified", f'{t["epics_verified"]}<small>/{t["epics"]}</small>',
              "every scenario passing in CI", run_delta("epics_verified")),
        _tile("Stories specified", f'{t["stories_with_scenarios"]}<small>/{t["stories"]}</small>',
              f'{_pct(t["stories_with_scenarios"], t["stories"])}% have acceptance scenarios',
              _delta(_baseline(days, "stories_with_scenarios"))),
        _tile("Acceptance scenarios", str(t["scenarios"]), "specified in Gherkin",
              _delta(_baseline(days, "scenarios"))),
        _tile("Automated", f'{_pct(t["automated"], t["scenarios"])}%',
              f'{t["automated"]} of {t["scenarios"]} scenarios', _delta(_baseline(days, "automated"))),
        _tile("Passing in CI", f'{_pct(t["passing"], t["scenarios"])}%',
              f'{t["passing"]} of {t["scenarios"]} scenarios', run_delta("passing")),
        _tile("Failing", str(t["failing"]), "scenarios in the latest run", run_delta("failing", False)),
    ])
    legend = "".join(f'<span class="key"><i class="seg {state}"></i>{_esc(STATE_LABELS[state])}</span>'
                     for state in STATES)
    total_row = {**t, "id": "", "title": ""}
    data = json.dumps(trends, separators=(",", ":")).replace("</", "<\\/")
    commit = latest.get("commit", "")[:7]
    meta = " · ".join(filter(None, [
        f'Updated {_esc(latest["generated_at"].replace("T", " ").replace("Z", " UTC"))}',
        f"commit {_esc(commit)}" if commit else "", f'{len(snapshots)} published run{"s" if len(snapshots) != 1 else ""}']))
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SitePulse product status</title>
<style>{CSS}</style></head>
<body><main>
<header><div><h1>SitePulse product status</h1><p class="meta">{meta}</p></div>
<nav><a href="{_esc(links["detail"])}">Detailed feature test report</a><a href="{_esc(links["history"])}">All test runs</a></nav></header>

<section class="tiles">{tiles}</section>

<section><h2>Coverage by epic</h2>
<p class="lede">Each bar is the epic's acceptance scenarios, split by their state in the latest CI run.</p>
<div class="legend">{legend}</div>
<div class="scroll"><table class="epics"><thead><tr><th>Epic</th><th class="num">Stories with scenarios</th>
<th>Scenarios</th><th class="num">Automated</th><th class="num">Passing</th><th>Health</th></tr></thead>
<tbody>{"".join(_epic_row(row) for row in latest["epics"])}</tbody>
<tfoot><tr><td class="epic"><b>All epics</b></td><td class="num">{t["stories_with_scenarios"]}/{t["stories"]}</td>
<td class="mix">{_bar(total_row)}<span class="counts">{t["scenarios"]} scenarios</span></td>
<td class="num">{_pct(t["automated"], t["scenarios"])}%</td><td class="num">{_pct(t["passing"], t["scenarios"])}%</td>
<td></td></tr></tfoot></table></div>
<p class="foot">"Automated, no CI result" scenarios are covered by a test that the browser (e2e) run does not
report on, such as Rust or Flutter unit tests, or were skipped. They count as automated, not as passing.</p>
</section>

{_inventory_html(latest)}

<section><h2>Needs attention</h2><div class="notes">{_attention(latest)}</div></section>

<section><h2>Trends</h2>
<div class="charts">
<figure><figcaption><b>Acceptance scenarios</b><span>Specified, automated and passing in CI, per day</span></figcaption>
<div class="legend" id="legend-scenarios"></div><div class="chart" id="chart-scenarios"></div></figure>
<figure><figcaption><b>User stories</b><span>Defined in the requirements and covered by scenarios, per day</span></figcaption>
<div class="legend" id="legend-stories"></div><div class="chart" id="chart-stories"></div></figure>
<figure class="wide"><figcaption><b>CI test runs</b><span>Tests per published run on master, newest on the right; select a bar to open its report</span></figcaption>
<div class="legend" id="legend-runs"></div><div class="chart" id="chart-runs"></div></figure>
</div>
{_trend_table(days)}
</section>

<section><h2>Recently added</h2>
<p class="lede">New stories, new acceptance scenarios and scenarios that became automated, by day and epic.</p>
{_changes_html(latest.get("recent_changes", []))}
</section>
<div id="tip" role="status" hidden></div>
</main>
<script>const DATA={data};
{JS}</script>
</body></html>
"""


CSS = """
:root{--page:#f9f9f7;--surface:#fcfcfb;--text:#0b0b0b;--text-2:#52514e;--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;
--good:#0ca30c;--good-text:#006300;--bad:#d03b3b;--warn:#fab219;--neutral:#c3c2b7;
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--link:#1c5cab}
@media (prefers-color-scheme:dark){:root{--page:#0d0d0d;--surface:#1a1a19;--text:#f0efec;--text-2:#c3c2b7;--grid:#2c2c2a;
--axis:#383835;--good-text:#0ca30c;--neutral:#52514e;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--link:#86b6ef}}
*{box-sizing:border-box}body{margin:0;background:var(--page);color:var(--text);
font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:1120px;margin:0 auto;padding:28px 16px 72px}
header{display:flex;flex-wrap:wrap;gap:12px 24px;justify-content:space-between;align-items:flex-end;margin-bottom:22px}
h1{font-size:24px;margin:0;letter-spacing:-.01em}h2{font-size:18px;margin:0 0 4px}h3{font-size:14px;margin:0 0 6px}
.meta,.lede,.foot,.muted{color:var(--text-2);font-size:13px;margin:2px 0 12px}.foot{margin-top:10px;max-width:76ch}
a{color:var(--link)}nav{display:flex;flex-wrap:wrap;gap:8px}
nav a{border:1px solid var(--axis);border-radius:8px;padding:6px 12px;text-decoration:none;font-size:14px;background:var(--surface)}
section{margin-top:34px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(148px,1fr));gap:10px;margin-top:0}
.tile{background:var(--surface);border:1px solid var(--grid);border-radius:12px;padding:12px 14px;display:flex;flex-direction:column;gap:2px}
.tile-label{font-size:12px;color:var(--text-2)}.tile b{font-size:28px;line-height:1.2;font-variant-numeric:tabular-nums}
.tile b small{font-size:16px;font-weight:500;color:var(--text-2)}.tile b .health{font-size:20px}
.tile-note{font-size:12px;color:var(--text-2)}
.delta{font-size:12px;margin-top:4px}.delta.up{color:var(--good-text)}.delta.down{color:var(--bad)}.delta.flat{color:var(--muted)}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;background:var(--surface);border:1px solid var(--grid);border-radius:12px}
th,td{padding:9px 12px;text-align:left;border-bottom:1px solid var(--grid);vertical-align:middle}
th{font-size:12px;font-weight:600;color:var(--text-2);white-space:nowrap}
tbody tr:last-child td,tfoot td{border-bottom:0}tfoot td{border-top:1px solid var(--axis)}
.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.epic{min-width:190px}.epic-id{font:600 12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text-2);margin-right:4px;white-space:nowrap}
.mix{min-width:170px;width:32%}.counts{display:block;font-size:12px;color:var(--text-2);margin-top:3px}
.bar{display:flex;gap:2px;height:12px}.bar.empty{background:repeating-linear-gradient(135deg,var(--grid) 0 4px,transparent 4px 8px);border-radius:4px}
.seg{display:block;min-width:3px;border-radius:3px}.seg.passing{background:var(--good)}.seg.failing{background:var(--bad)}
.seg.no_result{background:var(--warn)}.seg.planned{background:var(--neutral)}
.legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:12px;color:var(--text-2);margin:0 0 10px}
.key{display:inline-flex;align-items:center;gap:6px}.key i{width:12px;height:12px}.key i.line{height:3px;border-radius:2px}
.health{display:inline-flex;align-items:center;gap:5px;font-size:13px;font-weight:600;white-space:nowrap}
.health.verified{color:var(--good-text)}.health.failing{color:var(--bad)}.health.in_progress{color:var(--text)}
.health.not_automated,.health.not_specified{color:var(--text-2)}
.notes{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px}
.note{background:var(--surface);border:1px solid var(--grid);border-left:4px solid var(--axis);border-radius:10px;padding:12px 14px}
.note.good{border-left-color:var(--good)}.note.bad{border-left-color:var(--bad)}
.note ul,.change ul{margin:0;padding-left:18px;font-size:13px}.note p{margin:0;font-size:13px;color:var(--text-2)}
.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:10px}
figure{margin:0;background:var(--surface);border:1px solid var(--grid);border-radius:12px;padding:14px 14px 8px;min-width:0}
figure.wide{grid-column:1/-1}figcaption{margin-bottom:8px}figcaption b{display:block;font-size:14px}
figcaption span{font-size:12px;color:var(--text-2)}
.chart svg{display:block;width:100%;height:auto;overflow:visible}.chart text{font:11px system-ui,sans-serif;fill:var(--muted)}
.chart .val{fill:var(--text);font-weight:600}.chart .hit{cursor:pointer}
.table-view{margin-top:10px;font-size:13px}.table-view summary,.change summary{cursor:pointer}
.table-view table{margin-top:8px}
.day{margin-top:14px}.day h3{color:var(--text-2);font-weight:600}
.change{background:var(--surface);border:1px solid var(--grid);border-radius:10px;padding:8px 12px;margin:6px 0}
.change ul{margin-top:6px;color:var(--text-2)}
.chips{display:inline-flex;flex-wrap:wrap;gap:6px;margin-left:6px}
.chip{font-size:12px;border:1px solid var(--axis);border-radius:999px;padding:0 8px;color:var(--text-2)}
#tip{position:fixed;z-index:5;pointer-events:none;background:var(--text);color:var(--page);font-size:12px;line-height:1.45;
padding:6px 9px;border-radius:6px;max-width:260px;white-space:pre-line}
"""

JS = r"""
const NS='http://www.w3.org/2000/svg',tip=document.getElementById('tip');
const css=n=>getComputedStyle(document.documentElement).getPropertyValue(n).trim();
function el(tag,attrs,parent,text){const e=document.createElementNS(NS,tag);for(const k in attrs)e.setAttribute(k,attrs[k]);
  if(text!=null)e.textContent=text;if(parent)parent.appendChild(e);return e}
function showTip(evt,text){tip.textContent=text;tip.hidden=false;const w=tip.offsetWidth,h=tip.offsetHeight;
  let x=evt.clientX+14,y=evt.clientY+14;if(x+w>innerWidth-8)x=evt.clientX-w-14;if(y+h>innerHeight-8)y=evt.clientY-h-14;
  tip.style.left=Math.max(8,x)+'px';tip.style.top=Math.max(8,y)+'px'}
function hideTip(){tip.hidden=true}
function niceMax(v){if(v<=5)return 5;const p=Math.pow(10,Math.floor(Math.log10(v)));for(const m of[1,2,2.5,5,10])if(m*p>=v)return m*p;return 10*p}
function legend(id,series,line){document.getElementById(id).innerHTML=series.map(s=>
  `<span class="key"><i class="seg${line?' line':''}" style="background:var(${s.color})"></i>${s.label}</span>`).join('')}
function frame(id,W,H,max,M){const host=document.getElementById(id);host.textContent='';
  const svg=el('svg',{viewBox:`0 0 ${W} ${H}`,role:'img'},host);
  for(let i=0;i<=4;i++){const v=max*i/4,y=H-M.b-(H-M.t-M.b)*i/4;
    el('line',{x1:M.l,x2:W-M.r,y1:y,y2:y,stroke:css(i?'--grid':'--axis'),'stroke-width':1},svg);
    el('text',{x:M.l-6,y:y+4,'text-anchor':'end'},svg,String(Math.round(v)))}
  return svg}
function lineChart(id,legendId,days,series){
  legend(legendId,series,true);
  const W=560,H=250,M={l:36,r:44,t:12,b:26};
  let pts=days.filter(d=>series.some(s=>d[s.key]!=null));
  const first=pts.findIndex(d=>d[series[0].key]>0);pts=pts.slice(Math.max(first,0));  // start where the first series starts
  const host=document.getElementById(id);
  if(!pts.length){host.innerHTML='<p class="muted">No data yet.</p>';return}
  const max=niceMax(Math.max(...pts.flatMap(d=>series.map(s=>d[s.key]||0))));
  const svg=frame(id,W,H,max,M);
  const time=d=>Date.parse(d.date+'T00:00:00Z'),t0=time(pts[0]),t1=time(pts[pts.length-1]);
  const X=d=>t1===t0?(M.l+W-M.r)/2:M.l+(W-M.l-M.r)*(time(d)-t0)/(t1-t0);
  const Y=v=>H-M.b-(H-M.t-M.b)*v/max;
  const ticks=pts.length<=4?pts:[pts[0],pts[Math.floor((pts.length-1)/2)],pts[pts.length-1]];
  ticks.forEach((d,i)=>el('text',{x:X(d),y:H-8,'text-anchor':ticks.length===1?'middle':i===0?'start':i===ticks.length-1?'end':'middle'},svg,d.date));
  const ends=[];
  series.forEach(s=>{const own=pts.filter(d=>d[s.key]!=null);if(!own.length)return;
    el('path',{d:own.map((d,i)=>(i?'L':'M')+X(d).toFixed(1)+' '+Y(d[s.key]).toFixed(1)).join(''),fill:'none',
      stroke:css(s.color),'stroke-width':2,'stroke-linejoin':'round','stroke-linecap':'round'},svg);
    if(own.length<=24)own.forEach(d=>el('circle',{cx:X(d),cy:Y(d[s.key]),r:4,fill:css(s.color),stroke:css('--surface'),'stroke-width':2},svg));
    const last=own[own.length-1];ends.push({y:Y(last[s.key])+4,x:X(last)+8,v:last[s.key]})});
  ends.sort((a,b)=>a.y-b.y);for(let i=1;i<ends.length;i++)if(ends[i].y-ends[i-1].y<12)ends[i].y=ends[i-1].y+12;
  ends.forEach(e=>el('text',{x:Math.min(e.x,W-M.r+8),y:e.y,class:'val'},svg,String(e.v)));
  const cross=el('line',{y1:M.t,y2:H-M.b,stroke:css('--axis'),'stroke-width':1,visibility:'hidden'},svg);
  const hit=el('rect',{x:M.l,y:M.t,width:W-M.l-M.r,height:H-M.t-M.b,fill:'transparent'},svg);
  hit.addEventListener('mousemove',evt=>{const r=svg.getBoundingClientRect(),x=(evt.clientX-r.left)*W/r.width;
    let best=pts[0];for(const d of pts)if(Math.abs(X(d)-x)<Math.abs(X(best)-x))best=d;
    cross.setAttribute('x1',X(best));cross.setAttribute('x2',X(best));cross.setAttribute('visibility','visible');
    showTip(evt,best.date+'\n'+series.filter(s=>best[s.key]!=null).map(s=>s.label+': '+best[s.key]).join('\n'))});
  hit.addEventListener('mouseleave',()=>{cross.setAttribute('visibility','hidden');hideTip()});
}
function runChart(id,legendId,runs){
  const series=[{key:'passed',label:'Passed',color:'--good'},{key:'failed',label:'Failed',color:'--bad'},{key:'skipped',label:'Skipped',color:'--neutral'}];
  legend(legendId,series,false);
  const host=document.getElementById(id);
  if(!runs.length){host.innerHTML='<p class="muted">No runs published yet.</p>';return}
  const W=1080,H=220,M={l:36,r:12,t:12,b:26};
  const max=niceMax(Math.max(...runs.map(r=>r.passed+r.failed+r.skipped)));
  const svg=frame(id,W,H,max,M);
  const slot=(W-M.l-M.r)/Math.max(runs.length,12),bw=Math.min(28,slot-6),x0=W-M.r-slot*runs.length;
  const Yh=v=>(H-M.t-M.b)*v/max;
  runs.forEach((r,i)=>{const x=x0+slot*i+(slot-bw)/2;let y=H-M.b;
    series.forEach(s=>{const h=Yh(r[s.key]);if(h<=0)return;const hh=Math.max(h-2,1);y-=h;
      el('rect',{x,y:y+2,width:bw,height:hh,rx:Math.min(3,hh/2),fill:css(s.color)},svg)});
    if(i===0||i===runs.length-1)el('text',{x:x+bw/2,y:H-8,'text-anchor':i===0&&runs.length>1?'start':'end'},svg,r.at.slice(0,10));
    const g=el('rect',{x:x0+slot*i,y:M.t,width:slot,height:H-M.t-M.b,fill:'transparent',class:'hit',tabindex:0,
      'aria-label':`${r.at.slice(0,16).replace('T',' ')} ${r.status}: ${r.passed} passed, ${r.failed} failed, ${r.skipped} skipped`},svg);
    const text=`${r.at.slice(0,16).replace('T',' ')} UTC\n${r.status}${r.commit?' · '+r.commit:''}\nPassed: ${r.passed}\nFailed: ${r.failed}\nSkipped: ${r.skipped}`;
    g.addEventListener('mousemove',evt=>showTip(evt,text));g.addEventListener('mouseleave',hideTip);
    const open=()=>{if(r.href)location.href=r.href};g.addEventListener('click',open);
    g.addEventListener('keydown',evt=>{if(evt.key==='Enter')open()})});
}
function draw(){
  lineChart('chart-scenarios','legend-scenarios',DATA.days,[{key:'scenarios',label:'Specified',color:'--s1'},
    {key:'automated',label:'Automated',color:'--s2'},{key:'passing',label:'Passing in CI',color:'--s3'}]);
  lineChart('chart-stories','legend-stories',DATA.days,[{key:'stories',label:'Stories defined',color:'--s1'},
    {key:'stories_with_scenarios',label:'With acceptance scenarios',color:'--s2'}]);
  runChart('chart-runs','legend-runs',DATA.runs)}
draw();matchMedia('(prefers-color-scheme:dark)').addEventListener('change',draw);
"""


# ---------------------------------------------------------------- site and CLI

def load_site_snapshots(site: Path) -> list[dict]:
    """Snapshots of every report archived under <site>/reports, oldest first, each with its href."""
    snapshots = []
    for folder in sorted(p for p in (site / "reports").glob("*") if p.is_dir()):
        snap = None
        try:
            if (folder / "product-status.json").is_file():
                snap = json.loads((folder / "product-status.json").read_text(encoding="utf-8"))
            elif (folder / "summary.json").is_file():
                snap = snapshot_from_summary(json.loads((folder / "summary.json").read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            snap = None
        if isinstance(snap, dict) and snap.get("generated_at"):
            if "inventory" not in snap:
                junit = snap.get("junit", {})
                tests = int(junit.get("tests", 0)) if isinstance(junit, dict) else 0
                suites = [{
                    "suite": "e2e",
                    "runner": "pytest-playwright",
                    "producer": "e2e",
                    "status": "collected",
                    "case_count": tests,
                    "missing_shards": []
                }] if tests else []
                snap["inventory"] = {"suites": suites, "gates": [], "unmapped_cases": []}
            snapshots.append({**snap, "href": f"reports/{folder.name}/"})
    return sorted(snapshots, key=lambda s: (s["generated_at"], s["href"]))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot", help="product status of the working tree (and one run's records)")
    snap.add_argument("--executions", type=Path, help="executions.jsonl of the run to report (default: no results)")
    snap.add_argument("--summary", type=Path, help="summary.json of that run (ci_test_report.py)")
    snap.add_argument("--no-history", action="store_true", help="skip the catalogue history read from git")
    snap.add_argument("--out", type=Path, help="write the snapshot here")
    snap.add_argument("--json", action="store_true", help="print the snapshot as JSON")
    page = sub.add_parser("html", help="render the dashboard")
    source = page.add_mutually_exclusive_group(required=True)
    source.add_argument("--snapshot", type=Path, nargs="+", help="snapshot file(s), oldest first")
    source.add_argument("--site", type=Path, help="published site directory (reads reports/*/)")
    page.add_argument("--out", type=Path, required=True, help="HTML file to write")
    page.add_argument("--json", action="store_true", help="print a JSON summary")
    args = parser.parse_args(argv)
    try:
        if args.command == "snapshot":
            records = ([json.loads(line) for line in args.executions.read_text(encoding="utf-8").splitlines()
                        if line.strip()] if args.executions else [])
            summary = json.loads(args.summary.read_text(encoding="utf-8")) if args.summary else {}
            history = None if args.no_history else catalogue_history()
            result = build_snapshot(ft.load_catalogue(), records, summary, history)
            if args.out:
                args.out.write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
            t = result["totals"]
            print(json.dumps(result) if args.json else
                  f"{t['epics']} epics, {t['stories_with_scenarios']}/{t['stories']} stories with scenarios, "
                  f"{t['scenarios']} scenarios: {t['automated']} automated, {t['passing']} passing, "
                  f"{t['failing']} failing")
            return 0
        snapshots = (load_site_snapshots(args.site) if args.site else
                     [json.loads(p.read_text(encoding="utf-8")) for p in args.snapshot])
        args.out.write_text(render_html(snapshots), encoding="utf-8")
        print(json.dumps({"out": str(args.out), "snapshots": len(snapshots)}) if args.json else
              f"Wrote {args.out} from {len(snapshots)} snapshot(s)")
        return 0
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
