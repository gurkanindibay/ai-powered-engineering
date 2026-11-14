#!/usr/bin/env python3
"""Epic → story → Gherkin scenario → execution traceability, with run history.

Sources
* stories:    .specify/requirements/EPIC-xx-*.md           (`### STORY-xx-yy: title`)
* scenarios:  .specify/features/EPIC-xx/STORY-xx-yy-*.feature
              tags: @EPIC-xx @STORY-xx-yy on the Feature, @SC-xx-yy-nn on each Scenario,
              @layer:<name>, and @pending (no automation yet) or @linked (verified by a
              non-Gherkin test that declares the scenario)
* links:      `covers: SC-xx-yy-nn` comments in backend/tests and flutter/test, and
              `@pytest.mark.covers("SC-xx-yy-nn")` in e2e/tests
* executions: e2e/.artifacts/executions.jsonl, written by e2e/support/executions.py:
              one record per scenario per run, with a status per Gherkin step
* history:    every recorded run, committed with the task that produced it:
              .specify/executions/runs/<year>/<run id>.jsonl      one record per scenario
              .specify/executions/reports/<year>/<run id>.md      the run as a readable report
              (--store <dir> or --store git:<branch> keeps it somewhere else)

Commands
  check                 static gate: every story of a migrated epic has a scenario, ids are
                        unique and consistent, links point at real scenarios;
                        --require-run also fails when the current branch has no recorded run
  record                append the last run's executions to the history and write its report
  task-report           the latest run of the current task as markdown (for the PR description)
  report                latest status per epic, story and scenario (--steps for step detail)
  history <ID>          runs over time for an SC-, STORY- or EPIC- id
  runs                  one line per recorded run: what executed, what regressed or was fixed
  html                  dashboard as one self-contained HTML page (e2e/.artifacts/feature-report.html):
                        latest run, run list, scenario x run matrix, and the tree by feature

Scenario status: PASS, FAIL, ERROR (setup failed), DEFECT (strict xfail: a known defect),
SKIPPED, NOT RUN (automated, no execution recorded), PENDING (no automation yet).
A story takes the worst status of its scenarios, or MISSING when it has none.

Examples
  python3 scripts/feature_traceability.py check --json
  python3 scripts/feature_traceability.py record --task issue-123
  python3 scripts/feature_traceability.py task-report
  python3 scripts/feature_traceability.py check --require-run
  python3 scripts/feature_traceability.py report --epic EPIC-10 --steps
  python3 scripts/feature_traceability.py history SC-10-01-01 --limit 20
  python3 scripts/feature_traceability.py history STORY-10-05 --json
  python3 scripts/feature_traceability.py runs --detail --limit 5
  python3 scripts/feature_traceability.py html --out /tmp/report.html

Exit code: `check` 1 on problems; `report` 1 if a story is FAIL, ERROR or MISSING; otherwise 0.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIREMENTS = ROOT / ".specify" / "requirements"
FEATURES = ROOT / ".specify" / "features"
EXECUTIONS = ROOT / "e2e" / ".artifacts" / "executions.jsonl"
HTML_REPORT = ROOT / "e2e" / ".artifacts" / "feature-report.html"
RECENT_RUNS = 30
LINK_SOURCES = (("backend/tests", "*.rs"), ("flutter/test", "*.dart"), ("e2e/tests", "*.py"))
DEFAULT_STORE = str(ROOT / ".specify" / "executions")

EPIC_FILE = re.compile(r"^(EPIC-\d{2})-")
EPIC_TITLE = re.compile(r"^#\s+(?:Epic:\s*)?(.+?)\s*$")
STORY_HEADING = re.compile(r"^###\s+(STORY-\d{2}-\d{2}):\s*(.+?)\s*$")
SCENARIO_ID = re.compile(r"SC-(\d{2})-(\d{2})-\d{2}")
SCENARIO_LINE = re.compile(r"^(Scenario Outline|Scenario Template|Scenario|Example):\s*(.*)$")
STEP_LINE = re.compile(r"^(Given|When|Then|And|But|\*)\s+(.*)$")
TEST_NAME = re.compile(r"""(?:fn|def)\s+(\w+)|(?:test|testWidgets)\(\s*['"](.+?)['"]\s*,""")

SCENARIO_ORDER = ["FAIL", "ERROR", "NOT RUN", "DEFECT", "PENDING", "SKIPPED", "PASS"]
STORY_ORDER = ["FAIL", "ERROR", "MISSING", "NOT RUN", "DEFECT", "PENDING", "SKIPPED", "PASS"]
FAILING = {"FAIL", "ERROR", "MISSING"}


# ---------------------------------------------------------------- catalogue

@dataclass
class Scenario:
    id: str
    name: str
    tags: list[str]
    file: str
    line: int
    steps: list[str] = field(default_factory=list)
    feature_tags: list[str] = field(default_factory=list)

    @property
    def all_tags(self) -> set[str]:
        return set(self.tags) | set(self.feature_tags)

    @property
    def mode(self) -> str:
        return "pending" if "pending" in self.all_tags else "linked" if "linked" in self.all_tags else "gherkin"

    @property
    def layer(self) -> str:
        return next((t.split(":", 1)[1] for t in sorted(self.all_tags) if t.startswith("layer:")), "")


def parents_of(scenario_id: str) -> tuple[str, str]:
    """'SC-10-01-02' -> ('EPIC-10', 'STORY-10-01')."""
    m = SCENARIO_ID.fullmatch(scenario_id)
    if not m:
        raise ValueError(f"not a scenario id: {scenario_id!r}")
    return f"EPIC-{m.group(1)}", f"STORY-{m.group(1)}-{m.group(2)}"


def parse_feature(text: str, file: str) -> tuple[list[str], list[Scenario], list[str]]:
    """Returns (feature tags, scenarios, problems). Reads tags, scenario titles and step lines only."""
    feature_tags: list[str] = []
    scenarios: list[Scenario] = []
    problems: list[str] = []
    pending_tags: list[str] = []
    current: Scenario | None = None
    in_docstring = False
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if line.startswith(('"""', "```")):
            in_docstring = not in_docstring
            continue
        if in_docstring or not line or line.startswith(("#", "|")):
            continue
        if line.startswith("@"):
            pending_tags += [t[1:] for t in line.split() if t.startswith("@")]
            continue
        if line.startswith("Feature:"):
            feature_tags, pending_tags = pending_tags, []
            continue
        m = SCENARIO_LINE.match(line)
        if m:
            ids = [t for t in pending_tags if SCENARIO_ID.fullmatch(t)]
            if len(ids) != 1:
                problems.append(f"{file}:{number}: scenario '{m.group(2)}' needs exactly one @SC-xx-yy-nn tag")
            current = Scenario(ids[0] if ids else "", m.group(2), pending_tags, file, number, feature_tags=feature_tags)
            scenarios.append(current)
            pending_tags = []
            continue
        if line.startswith(("Background:", "Rule:", "Examples:", "Scenarios:")):
            current, pending_tags = None, []
            continue
        m = STEP_LINE.match(line)
        if m and current is not None:
            current.steps.append(f"{m.group(1)} {m.group(2)}")
    return feature_tags, scenarios, problems


def load_stories(requirements: Path = REQUIREMENTS) -> tuple[dict[str, str], dict[str, str]]:
    """Returns ({epic id: title}, {story id: title}) from the epic documents."""
    epics: dict[str, str] = {}
    stories: dict[str, str] = {}
    for path in sorted(requirements.glob("EPIC-*.md")):
        m = EPIC_FILE.match(path.name)
        if not m:
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            title = EPIC_TITLE.match(line)
            if title and m.group(1) not in epics:
                epics[m.group(1)] = title.group(1)
            story = STORY_HEADING.match(line)
            if story:
                stories[story.group(1)] = story.group(2)
        epics.setdefault(m.group(1), path.stem)
    return epics, stories


def load_links(root: Path = ROOT) -> dict[str, list[dict]]:
    """{scenario id: [{file, line, test}]} from `covers` declarations in the test suites."""
    links: dict[str, list[dict]] = defaultdict(list)
    for directory, pattern in LINK_SOURCES:
        for path in sorted((root / directory).rglob(pattern)):
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            for index, line in enumerate(lines):
                if "covers" not in line:
                    continue
                name = next((m.group(1) or m.group(2) for m in map(TEST_NAME.search, lines[index:index + 6]) if m), "")
                for found in SCENARIO_ID.finditer(line):
                    links[found.group(0)].append(
                        {"file": path.relative_to(root).as_posix(), "line": index + 1, "test": name})
    return dict(links)


@dataclass
class Catalogue:
    epics: dict[str, str]
    stories: dict[str, str]
    scenarios: list[Scenario]
    links: dict[str, list[dict]]
    problems: list[str]

    @property
    def migrated_epics(self) -> list[str]:
        return sorted({parents_of(s.id)[0] for s in self.scenarios if s.id})

    def by_story(self) -> dict[str, list[Scenario]]:
        grouped: dict[str, list[Scenario]] = defaultdict(list)
        for scenario in self.scenarios:
            if scenario.id:
                grouped[parents_of(scenario.id)[1]].append(scenario)
        return grouped


def load_catalogue(root: Path = ROOT) -> Catalogue:
    features = root / ".specify" / "features"
    epics, stories = load_stories(root / ".specify" / "requirements")
    scenarios: list[Scenario] = []
    problems: list[str] = []
    for path in sorted(features.rglob("*.feature")):
        rel = path.relative_to(features).as_posix()
        feature_tags, found, parse_problems = parse_feature(path.read_text(encoding="utf-8"), rel)
        problems += parse_problems
        scenarios += found
        story_tags = [t for t in feature_tags if t.startswith("STORY-")]
        epic_tags = [t for t in feature_tags if t.startswith("EPIC-")]
        if len(story_tags) != 1 or len(epic_tags) != 1:
            problems.append(f"{rel}: the Feature needs exactly one @EPIC-xx and one @STORY-xx-yy tag")
            continue
        if story_tags[0] not in stories:
            problems.append(f"{rel}: {story_tags[0]} is not a story in .specify/requirements")
        if not rel.startswith(f"{epic_tags[0]}/{story_tags[0]}-"):
            problems.append(f"{rel}: expected path {epic_tags[0]}/{story_tags[0]}-<slug>.feature")
        for scenario in found:
            if scenario.id and parents_of(scenario.id) != (epic_tags[0], story_tags[0]):
                problems.append(f"{rel}:{scenario.line}: {scenario.id} does not belong to {story_tags[0]}")
    return Catalogue(epics, stories, scenarios, load_links(root), problems)


def check(catalogue: Catalogue) -> list[str]:
    problems = list(catalogue.problems)
    known = Counter(s.id for s in catalogue.scenarios if s.id)
    problems += [f"{sid}: used by {count} scenarios (ids must be unique)" for sid, count in known.items() if count > 1]
    by_story = catalogue.by_story()
    for story in sorted(catalogue.stories):
        epic = "EPIC-" + story.split("-")[1]
        if epic in catalogue.migrated_epics and story not in by_story:
            problems.append(f"{story}: no scenario under .specify/features/{epic}")
    for scenario in catalogue.scenarios:
        where = f"{scenario.file}:{scenario.line}: {scenario.id or scenario.name}"
        if not scenario.steps:
            problems.append(f"{where} has no steps")
        if scenario.mode != "pending" and not scenario.layer:
            problems.append(f"{where} needs a @layer:<name> tag")
        if scenario.mode == "linked" and scenario.id not in catalogue.links:
            problems.append(f"{where} is @linked but no test declares `covers: {scenario.id}`")
    for sid, refs in sorted(catalogue.links.items()):
        if sid not in known:
            problems += [f"{ref['file']}:{ref['line']}: covers unknown scenario {sid}" for ref in refs]
    return problems


# ---------------------------------------------------------------- history store

def _git(args: list[str], cwd: Path, stdin: str | None = None, env: dict | None = None, check_rc: bool = True) -> str:
    proc = subprocess.run(["git", *args], cwd=cwd, input=stdin, capture_output=True, text=True,
                          env={**os.environ, **(env or {})})
    if check_rc and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.strip() if proc.returncode == 0 else ""


class DirStore:
    """Run files in a plain directory."""

    def __init__(self, path: Path):
        self.path = path

    def describe(self) -> str:
        return self.path.relative_to(ROOT).as_posix() if self.path.is_relative_to(ROOT) else str(self.path)

    def write(self, rel: str, text: str, message: str) -> None:
        target = self.path / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def read_runs(self, limit: int) -> list[str]:
        files = sorted((self.path / "runs").rglob("*.jsonl"), key=lambda p: p.name) if self.path.exists() else []
        return [p.read_text(encoding="utf-8") for p in files[-limit:]]


class GitStore:
    """Run files as commits on a git branch, written with plumbing so no checkout is touched."""

    IDENTITY = {"GIT_AUTHOR_NAME": "sitepulse-test-history", "GIT_AUTHOR_EMAIL": "test-history@sitepulse.invalid",
                "GIT_COMMITTER_NAME": "sitepulse-test-history", "GIT_COMMITTER_EMAIL": "test-history@sitepulse.invalid"}

    def __init__(self, repo: Path, branch: str):
        self.repo, self.branch, self.ref = repo, branch, f"refs/heads/{branch}"

    def describe(self) -> str:
        return f"git branch {self.branch}"

    def _head(self) -> str:
        return _git(["rev-parse", "--verify", "--quiet", self.ref], self.repo, check_rc=False)

    def write(self, rel: str, text: str, message: str) -> None:
        parent = self._head()
        with tempfile.TemporaryDirectory() as tmp:
            env = {"GIT_INDEX_FILE": str(Path(tmp) / "index"), **self.IDENTITY}
            if parent:
                _git(["read-tree", parent], self.repo, env=env)
            blob = _git(["hash-object", "-w", "--stdin"], self.repo, stdin=text)
            _git(["update-index", "--add", "--cacheinfo", f"100644,{blob},{rel}"], self.repo, env=env)
            tree = _git(["write-tree"], self.repo, env=env)
            commit = _git(["commit-tree", tree, *(["-p", parent] if parent else []), "-m", message], self.repo, env=env)
        _git(["update-ref", self.ref, commit, *([parent] if parent else [])], self.repo)

    def read_runs(self, limit: int) -> list[str]:
        if not self._head():
            return []
        names = sorted(_git(["ls-tree", "-r", "--full-tree", "--name-only", self.ref, "runs/"], self.repo).splitlines(),
                       key=lambda n: n.rsplit("/", 1)[-1])
        return [_git(["show", f"{self.ref}:{name}"], self.repo) for name in names[-limit:]]

    def push(self, remote: str) -> None:
        _git(["push", remote, f"{self.ref}:{self.ref}"], self.repo)


def open_store(spec: str, repo: Path = ROOT):
    return GitStore(repo, spec[4:]) if spec.startswith("git:") else DirStore(Path(spec))


def run_metadata(repo: Path = ROOT, trigger: str | None = None, now: datetime | None = None,
                 task: str | None = None) -> dict:
    """Identity of a run. `task` names the piece of work it verifies (default: $SITEPULSE_TASK, else the branch)."""
    now = now or datetime.now(timezone.utc)
    commit = _git(["rev-parse", "HEAD"], repo, check_rc=False)
    branch = _git(["rev-parse", "--abbrev-ref", "HEAD"], repo, check_rc=False)
    return {
        "run_id": f"{now.strftime('%Y%m%dT%H%M%SZ')}-{commit[:7] or 'nogit'}",
        "started_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": commit,
        "branch": branch,
        "task": task or os.environ.get("SITEPULSE_TASK") or branch,
        "dirty": bool(_git(["status", "--porcelain", "--untracked-files=no"], repo, check_rc=False)),
        "trigger": trigger or ("ci" if os.environ.get("CI") else "local"),
    }


def record_run(executions: Path, store, meta: dict) -> int:
    """Stamps every execution record with the run metadata and stores the run. Returns the record count."""
    lines = [line for line in executions.read_text(encoding="utf-8").splitlines() if line.strip()] \
        if executions.exists() else []
    if not lines:
        return 0
    records = [{**meta, **json.loads(line)} for line in lines]
    text = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records)
    counts = Counter(r["status"] for r in records)
    summary = ", ".join(f"{n} {status}" for status, n in sorted(counts.items()))
    store.write(f"runs/{meta['run_id'][:4]}/{meta['run_id']}.jsonl", text,
                f"Test run {meta['run_id']}: {len(records)} scenarios ({summary})")
    return len(records)


def load_history(store, limit: int = 200) -> list[dict]:
    """All execution records of the newest `limit` runs, oldest first."""
    records: list[dict] = []
    for text in store.read_runs(limit):
        records += [json.loads(line) for line in text.splitlines() if line.strip()]
    return sorted(records, key=lambda r: (r.get("started_at", ""), r.get("run_id", "")))


# ---------------------------------------------------------------- report

def worst(statuses: list[str], order: list[str]) -> str:
    return min(statuses, key=order.index) if statuses else "MISSING"


def failing_step(record: dict) -> str:
    step = next((s for s in record.get("steps", []) if s["status"] in ("FAIL", "UNDEFINED")), None)
    return f"{step['keyword']} {step['text']}" if step else ""


def build_report(catalogue: Catalogue, history: list[dict], epic_filter: str | None = None,
                 story_filter: str | None = None) -> dict:
    by_scenario: dict[str, list[dict]] = defaultdict(list)
    for record in history:
        by_scenario[record["scenario"]].append(record)
    by_story = catalogue.by_story()
    epics = []
    for epic in sorted(catalogue.epics):
        if epic_filter and epic != epic_filter:
            continue
        number = epic.split("-")[1]
        story_ids = sorted(s for s in catalogue.stories if s.startswith(f"STORY-{number}-"))
        if epic not in catalogue.migrated_epics:
            epics.append({"id": epic, "title": catalogue.epics[epic], "status": "NOT MIGRATED",
                          "story_count": len(story_ids), "stories": []})
            continue
        stories = []
        for story in story_ids:
            if story_filter and story != story_filter:
                continue
            rows = []
            for scenario in sorted(by_story.get(story, []), key=lambda s: s.id):
                runs = by_scenario.get(scenario.id, [])
                last = runs[-1] if runs else None
                status = "PENDING" if scenario.mode == "pending" else last["status"] if last else "NOT RUN"
                rows.append({
                    "id": scenario.id, "name": scenario.name, "mode": scenario.mode, "layer": scenario.layer,
                    "feature_file": scenario.file, "status": status,
                    "runs": len(runs), "passed_runs": sum(r["status"] == "PASS" for r in runs),
                    "last_run": {k: last.get(k) for k in ("run_id", "started_at", "commit", "branch", "dirty",
                                                           "duration_s", "test", "steps", "error")} if last else None,
                    "failing_step": failing_step(last) if last else "",
                    "recent": [{"status": r["status"], "started_at": r["started_at"], "commit": r["commit"][:7],
                                "failing_step": failing_step(r)} for r in runs[-RECENT_RUNS:]],
                    "linked_tests": catalogue.links.get(scenario.id, []),
                })
            stories.append({"id": story, "title": catalogue.stories[story],
                            "status": worst([r["status"] for r in rows], STORY_ORDER), "scenarios": rows})
        epics.append({"id": epic, "title": catalogue.epics[epic],
                      "status": worst([s["status"] for s in stories], STORY_ORDER),
                      "story_count": len(story_ids), "stories": stories})
    statuses = Counter(s["status"] for e in epics for s in e["stories"])
    return {"epics": epics, "story_status_counts": dict(statuses)}


def print_report(report: dict, show_steps: bool) -> None:
    for epic in report["epics"]:
        if epic["status"] == "NOT MIGRATED":
            print(f"{epic['id']}  NOT MIGRATED  {epic['story_count']} stories, no feature files  {epic['title']}")
            continue
        print(f"{epic['id']}  {epic['status']}  {epic['title']}")
        for story in epic["stories"]:
            print(f"  {story['id']}  {story['status']:<8} {story['title']}")
            for row in story["scenarios"]:
                last = row["last_run"]
                when = f"{last['started_at'][:16]} {last['commit'][:7]} {last['duration_s']:.1f}s" if last else "-"
                rate = f"{row['passed_runs']}/{row['runs']} runs passed" if row["runs"] else "no runs"
                extra = f"  +{len(row['linked_tests'])} linked" if row["linked_tests"] else ""
                print(f"    {row['id']}  {row['status']:<8} {row['layer'] or '-':<4} {when}  ({rate}){extra}  {row['name']}")
                if row["failing_step"]:
                    print(f"        failed at: {row['failing_step']}")
                if show_steps and last:
                    for step in last["steps"]:
                        print(f"        {step['status']:<9} {step['duration_s']:>6.2f}s  {step['keyword']} {step['text']}")
                if show_steps:
                    for link in row["linked_tests"]:
                        print(f"        linked: {link['file']}:{link['line']} {link['test']}")
    counts = report["story_status_counts"]
    print("stories: " + (", ".join(f"{counts[s]} {s}" for s in STORY_ORDER if s in counts) or "none"))


def build_history(history: list[dict], target: str, limit: int) -> dict:
    """Timeline for a scenario, or per-run status counts for a story or an epic."""
    key = "scenario" if target.startswith("SC-") else "story" if target.startswith("STORY-") else "epic"
    matching = [r for r in history if r.get(key) == target]
    if key == "scenario":
        entries = [{"run_id": r["run_id"], "started_at": r["started_at"], "commit": r["commit"], "branch": r["branch"],
                    "dirty": r.get("dirty", False), "status": r["status"], "duration_s": r["duration_s"],
                    "failing_step": failing_step(r)} for r in matching]
    else:
        runs: dict[str, list[dict]] = defaultdict(list)
        for record in matching:
            runs[record["run_id"]].append(record)
        entries = [{"run_id": run_id, "started_at": rs[0]["started_at"], "commit": rs[0]["commit"],
                    "branch": rs[0]["branch"], "dirty": rs[0].get("dirty", False),
                    "status": worst([r["status"] for r in rs], SCENARIO_ORDER),
                    "counts": dict(Counter(r["status"] for r in rs)),
                    "duration_s": round(sum(r["duration_s"] for r in rs), 3)} for run_id, rs in runs.items()]
    entries = entries[::-1][:limit]  # newest first
    passed = sum(e["status"] == "PASS" for e in entries)
    return {"id": target, "level": key, "runs": len(entries), "passed": passed, "entries": entries}


def print_history(result: dict) -> None:
    print(f"{result['id']}: {result['passed']}/{result['runs']} runs passed (newest first)")
    for entry in result["entries"]:
        detail = entry.get("failing_step") or ", ".join(f"{n} {s}" for s, n in sorted(entry.get("counts", {}).items()))
        dirty = "*" if entry["dirty"] else " "
        print(f"  {entry['started_at'][:16]}  {entry['commit'][:7]}{dirty} {entry['branch'][:28]:<28} "
              f"{entry['status']:<8} {entry['duration_s']:>7.1f}s  {detail}")


def build_runs(history: list[dict], catalogue: Catalogue, limit: int = 30) -> list[dict]:
    """One entry per recorded run, newest first: what executed, and what changed since each scenario's previous run."""
    names = {s.id: s.name for s in catalogue.scenarios}
    automated = sorted(s.id for s in catalogue.scenarios if s.id and s.mode != "pending")
    grouped: dict[str, list[dict]] = {}
    for record in history:  # oldest first
        grouped.setdefault(record["run_id"], []).append(record)
    previous: dict[str, str] = {}
    runs = []
    for run_id, records in grouped.items():
        rows = []
        for record in sorted(records, key=lambda r: r["scenario"]):
            before, status = previous.get(record["scenario"]), record["status"]
            change = ("new" if before is None else "regressed" if before == "PASS" and status != "PASS"
                      else "fixed" if before != "PASS" and status == "PASS" else "")
            rows.append({"id": record["scenario"], "story": record["story"], "status": status, "change": change,
                         "name": names.get(record["scenario"], record.get("name", "")),
                         "duration_s": record["duration_s"], "failing_step": failing_step(record)})
        previous.update({row["id"]: row["status"] for row in rows})
        first, executed = records[0], {row["id"] for row in rows}
        runs.append({
            "run_id": run_id, "started_at": first["started_at"], "commit": first["commit"], "branch": first["branch"],
            "dirty": first.get("dirty", False), "trigger": first.get("trigger", ""),
            "task": first.get("task") or first["branch"],
            "status": worst([row["status"] for row in rows], SCENARIO_ORDER),
            "counts": dict(Counter(row["status"] for row in rows)),
            "changes": dict(Counter(row["change"] for row in rows if row["change"])),
            "executed": len(rows), "automated": len(automated),
            "not_executed": [sid for sid in automated if sid not in executed],
            "duration_s": round(sum(row["duration_s"] for row in rows), 1), "scenarios": rows})
    return runs[::-1][:limit]


def run_markdown(run: dict) -> str:
    """One run as a markdown report: stored next to the run and pasted into the task's PR."""
    counts = ", ".join(f"{run['counts'][s]} {s}" for s in SCENARIO_ORDER if s in run["counts"])
    lines = [f"# Test run {run['run_id']}", "",
             f"- **Task:** {run['task']}",
             f"- **Result:** {run['status']} ({counts})",
             f"- **Executed:** {run['executed']} of {run['automated']} automated scenarios in {run['duration_s']:.0f}s",
             f"- **Commit:** `{run['commit'][:10]}`{' plus uncommitted changes' if run['dirty'] else ''} on `{run['branch']}`",
             f"- **Started:** {run['started_at']} ({run['trigger'] or 'local'})"]
    changed = [row for row in run["scenarios"] if row["change"] in ("regressed", "fixed")]
    if changed:
        lines += ["", "## Changed since the previous execution", ""]
        lines += [f"- **{row['change']}**: `{row['id']}` {row['name']}" for row in changed]
    lines += ["", "## Scenarios", "", "| Scenario | Status | Change | Time | Name |", "|---|---|---|---|---|"]
    for row in run["scenarios"]:
        at = f" (failed at: {row['failing_step']})" if row["failing_step"] else ""
        lines.append(f"| `{row['id']}` | {row['status']} | {row['change']} | {row['duration_s']:.1f}s | "
                     f"{(row['name'] + at).replace('|', '/')} |")
    lines += ["", "## Not executed in this run", "",
              ", ".join(f"`{sid}`" for sid in run["not_executed"]) or "None: every automated scenario was executed."]
    return "\n".join(lines) + "\n"


def runs_of_task(runs: list[dict], task: str | None, branch: str) -> list[dict]:
    """Runs (newest first) labelled with `task`, or made on `branch` when no task is given."""
    return [r for r in runs if (r["task"] == task if task else r["branch"] == branch)]


def print_runs(runs: list[dict], detail: bool) -> None:
    for run in runs:
        counts = ", ".join(f"{run['counts'][s]} {s}" for s in SCENARIO_ORDER if s in run["counts"])
        changes = ", ".join(f"{n} {kind}" for kind, n in sorted(run["changes"].items()) if kind != "new")
        print(f"{run['started_at'][:16]}  {run['commit'][:7]}{'*' if run['dirty'] else ' '} {run['status']:<8} "
              f"{run['executed']}/{run['automated']} executed  {counts}{'  (' + changes + ')' if changes else ''}  "
              f"{run['duration_s']:.0f}s  {run['task']}")
        if detail:
            for row in run["scenarios"]:
                note = f"  {row['change']}" if row["change"] in ("regressed", "fixed") else ""
                at = f"  at: {row['failing_step']}" if row["failing_step"] else ""
                print(f"    {row['id']}  {row['status']:<8}{note}  {row['name']}{at}")
            if run["not_executed"]:
                print(f"    not executed: {', '.join(run['not_executed'])}")
    if not runs:
        print("no runs recorded")


# ---------------------------------------------------------------- html

HTML_STYLE = """
:root{--bg:#f6f7f9;--card:#fff;--text:#1c2330;--muted:#667085;--line:#e3e6eb;
--pass:#1a7f4b;--pass-bg:#e3f4ea;--fail:#b42318;--fail-bg:#fde7e4;--warn:#9a6700;--warn-bg:#fbf0d0;
--idle:#5b6472;--idle-bg:#e9ecf0;--defect:#6941c6;--defect-bg:#ece6fb}
@media (prefers-color-scheme:dark){:root{--bg:#12161c;--card:#1a2029;--text:#e6e9ee;--muted:#98a2b3;--line:#2a323e;
--pass:#5fd38d;--pass-bg:#16382a;--fail:#ff8a7a;--fail-bg:#4a1c17;--warn:#f0c04a;--warn-bg:#40330d;
--idle:#aab3c0;--idle-bg:#2a323e;--defect:#b9a3f5;--defect-bg:#2f2550}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);
font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:1080px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:22px;margin:0 0 4px}.meta{color:var(--muted);font-size:13px;margin-bottom:20px}
.tiles{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:24px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 16px;min-width:104px}
.tile b{display:block;font-size:24px;font-variant-numeric:tabular-nums}.tile span{font-size:12px;color:var(--muted)}
details{background:var(--card);border:1px solid var(--line);border-radius:10px;margin:10px 0}
details details{border-radius:8px;margin:8px 12px;background:transparent}
summary{cursor:pointer;padding:10px 14px;display:flex;flex-wrap:wrap;align-items:center;gap:8px;list-style:none}
summary::-webkit-details-marker{display:none}
summary::before{content:"\\25B8";color:var(--muted);width:10px}details[open]>summary::before{content:"\\25BE"}
.id{font:600 13px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap}
.title{flex:1 1 240px;min-width:0}.epic>summary .title{font-weight:600;font-size:16px}
.small{color:var(--muted);font-size:12px;white-space:nowrap}
.badge{font-size:11px;font-weight:700;letter-spacing:.02em;padding:2px 8px;border-radius:999px;white-space:nowrap}
.PASS{color:var(--pass);background:var(--pass-bg)}.FAIL,.ERROR,.MISSING,.UNDEFINED{color:var(--fail);background:var(--fail-bg)}
.NOT-RUN{color:var(--warn);background:var(--warn-bg)}.DEFECT{color:var(--defect);background:var(--defect-bg)}
.PENDING,.SKIPPED,.NOT-MIGRATED{color:var(--idle);background:var(--idle-bg)}
.strip{display:inline-flex;gap:2px}.strip i{width:8px;height:16px;border-radius:2px;display:inline-block}
.strip i.PASS{background:var(--pass)}.strip i.FAIL,.strip i.ERROR{background:var(--fail)}
.strip i.DEFECT{background:var(--defect)}.strip i.SKIPPED{background:var(--idle)}
.body{padding:0 14px 12px 32px;overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px}td{padding:4px 8px 4px 0;vertical-align:top;border-top:1px solid var(--line)}
td.num{text-align:right;white-space:nowrap;color:var(--muted);font-variant-numeric:tabular-nums}
.kw{color:var(--muted);font-weight:600}.note{color:var(--muted);font-size:13px;margin:8px 0 0}
pre{background:var(--fail-bg);color:var(--fail);padding:10px;border-radius:8px;font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere}
h2{font-size:16px;margin:28px 0 6px}.hint{color:var(--muted);font-size:13px;margin:0 0 8px}
.chg{font-size:11px;font-weight:700;padding:1px 6px;border-radius:4px;white-space:nowrap}
.chg.regressed{color:var(--fail);border:1px solid var(--fail)}.chg.fixed{color:var(--pass);border:1px solid var(--pass)}
.chg.new{color:var(--muted);border:1px solid var(--line)}
.matrix{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px;overflow-x:auto}
.matrix table{width:auto}.matrix td,.matrix th{border:0;padding:2px}
.matrix th.run{font:11px ui-monospace,Menlo,monospace;color:var(--muted);writing-mode:vertical-rl;transform:rotate(180deg);
text-align:left;padding-bottom:6px;white-space:nowrap;font-weight:400}
.matrix td.name{padding-right:14px;white-space:nowrap;max-width:420px;overflow:hidden;text-overflow:ellipsis}
.cell{width:18px;height:18px;border-radius:4px;display:block;background:var(--idle-bg);opacity:.45}
.cell.PASS{background:var(--pass);opacity:1}.cell.FAIL,.cell.ERROR{background:var(--fail);opacity:1}
.cell.DEFECT{background:var(--defect);opacity:1}.cell.SKIPPED{background:var(--idle);opacity:1}
.legend{display:flex;flex-wrap:wrap;gap:12px;font-size:12px;color:var(--muted);margin-top:10px;align-items:center}
.legend span{display:inline-flex;gap:5px;align-items:center}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
.plain{padding:10px 14px;background:var(--card);border:1px solid var(--line);border-radius:10px;margin:10px 0;
display:flex;flex-wrap:wrap;gap:8px;align-items:center}
"""


def _badge(status: str) -> str:
    return f'<span class="badge {status.replace(" ", "-")}">{html.escape(status)}</span>'


def _scenario_html(row: dict) -> str:
    esc = html.escape
    last = row["last_run"]
    strip = "".join(f'<i class="{r["status"].replace(" ", "-")}" title="{esc(r["started_at"][:16])} {esc(r["commit"])} '
                    f'{esc(r["status"])}{" at: " + esc(r["failing_step"]) if r["failing_step"] else ""}"></i>'
                    for r in row["recent"])
    when = (f'{esc(last["started_at"][:16].replace("T", " "))} · <code>{esc(last["commit"][:7])}</code>'
            f'{"*" if last.get("dirty") else ""} · {last["duration_s"]:.1f}s') if last else "never run"
    rate = f'{row["passed_runs"]}/{row["runs"]} passed' if row["runs"] else ""
    parts = []
    if last and last["steps"]:
        rows = "".join(f'<tr><td>{_badge(s["status"])}</td><td><span class="kw">{esc(s["keyword"])}</span> {esc(s["text"])}'
                       f'{"<pre>" + esc(s["error"]) + "</pre>" if s.get("error") else ""}</td>'
                       f'<td class="num">{s["duration_s"]:.2f}s</td></tr>' for s in last["steps"])
        parts.append(f"<table>{rows}</table>")
    elif last:
        parts.append(f'<p class="note">Verified by a linked test, so there is no step detail: <code>{esc(last["test"])}</code></p>')
    else:
        parts.append(f'<p class="note">{"Specified, not automated yet." if row["status"] == "PENDING" else "No execution recorded."}'
                     f' Source: <code>{esc(row["feature_file"])}</code></p>')
    if last and last.get("error") and not any(s.get("error") for s in last["steps"]):
        parts.append(f'<pre>{esc(last["error"])}</pre>')
    if row["linked_tests"]:
        links = "".join(f'<tr><td>linked test</td><td><code>{esc(l["file"])}:{l["line"]}</code> {esc(l["test"])}</td></tr>'
                        for l in row["linked_tests"])
        parts.append(f"<table>{links}</table>")
    return (f'<details class="scenario"{" open" if row["status"] in ("FAIL", "ERROR") else ""}><summary>'
            f'<span class="id">{esc(row["id"])}</span>{_badge(row["status"])}<span class="title">{esc(row["name"])}</span>'
            f'<span class="strip">{strip}</span><span class="small">{rate}</span><span class="small">{when}</span>'
            f'</summary><div class="body">{"".join(parts)}</div></details>')


def _run_html(run: dict, is_open: bool) -> str:
    esc = html.escape
    badges = "".join(f'<span class="badge {s.replace(" ", "-")}">{run["counts"][s]} {s}</span>'
                     for s in SCENARIO_ORDER if s in run["counts"])
    changes = "".join(f'<span class="chg {kind}">{n} {kind}</span>' for kind, n in sorted(run["changes"].items())
                      if kind != "new")
    rows = "".join(
        f'<tr><td><span class="id">{esc(row["id"])}</span></td><td>{_badge(row["status"])}</td>'
        f'<td>{esc(row["name"])}{" <span class=small>failed at: " + esc(row["failing_step"]) + "</span>" if row["failing_step"] else ""}</td>'
        f'<td>{"<span class=\"chg " + row["change"] + "\">" + row["change"] + "</span>" if row["change"] else ""}</td>'
        f'<td class="num">{row["duration_s"]:.1f}s</td></tr>' for row in run["scenarios"])
    missing = (f'<p class="note">Not executed in this run ({len(run["not_executed"])}): '
               f'{", ".join("<code>" + esc(s) + "</code>" for s in run["not_executed"])}</p>') if run["not_executed"] else \
        '<p class="note">Every automated scenario was executed in this run.</p>'
    return (f'<details class="run"{" open" if is_open else ""}><summary>'
            f'<span class="id">{esc(run["started_at"][:16].replace("T", " "))}</span>{_badge(run["status"])}'
            f'<span class="title">{esc(run["task"])}</span>{badges}{changes}'
            f'<span class="small">{run["executed"]}/{run["automated"]} executed</span>'
            f'<span class="small"><code>{esc(run["commit"][:7])}</code>{"*" if run["dirty"] else ""} · {run["duration_s"]:.0f}s</span>'
            f'</summary><div class="body"><table>{rows}</table>{missing}</div></details>')


def _matrix_html(report: dict, runs: list[dict], columns: int = 20) -> str:
    """Scenarios (rows) against the newest runs (columns, oldest to newest)."""
    esc = html.escape
    shown = runs[:columns][::-1]
    by_run = [{row["id"]: row for row in run["scenarios"]} for run in shown]
    head = "".join(f'<th class="run" title="{esc(run["task"])} {esc(run["commit"][:7])}">'
                   f'{esc(run["started_at"][5:16].replace("T", " "))}</th>' for run in shown)
    body = []
    for epic in report["epics"]:
        for story in epic["stories"]:
            body.append(f'<tr><td class="name small" colspan="{len(shown) + 2}">{esc(story["id"])} {esc(story["title"])}</td></tr>')
            for scenario in story["scenarios"]:
                cells = "".join(
                    f'<td><i class="cell {(cell or {}).get("status", "")}" title="{esc(run["started_at"][:16])} '
                    f'{esc((cell or {}).get("status", "not executed"))}"></i></td>'
                    for run, cell in ((run, lookup.get(scenario["id"])) for run, lookup in zip(shown, by_run)))
                body.append(f'<tr><td class="id">{esc(scenario["id"])}</td><td class="name">{esc(scenario["name"])}</td>{cells}</tr>')
    legend = "".join(f'<span><i class="cell {s}"></i>{label}</span>' for s, label in
                     (("PASS", "passed"), ("FAIL", "failed"), ("DEFECT", "known defect"), ("", "not executed")))
    return (f'<div class="matrix"><table><tr><th></th><th></th>{head}</tr>{"".join(body)}</table>'
            f'<div class="legend">{legend}</div></div>')


def render_html(report: dict, generated_at: str, store: str, runs: list[dict] | None = None) -> str:
    """The dashboard as one self-contained page: no scripts, no external resources."""
    runs = runs or []
    esc = html.escape
    scenarios = [row for epic in report["epics"] for story in epic["stories"] for row in story["scenarios"]]
    counts = Counter(row["status"] for row in scenarios)
    tiles = f'<div class="tile"><b>{len(scenarios)}</b><span>scenarios specified</span></div>' + "".join(
        f'<div class="tile"><b>{counts[s]}</b>{_badge(s)}</div>' for s in SCENARIO_ORDER if counts.get(s))
    dashboard = ""
    if runs:
        latest = runs[0]
        tiles = (f'<div class="tile"><b>{latest["executed"]}/{latest["automated"]}</b><span>executed in the latest run</span></div>'
                 + "".join(f'<div class="tile"><b>{latest["counts"][s]}</b>{_badge(s)}</div>'
                           for s in SCENARIO_ORDER if s in latest["counts"])
                 + "".join(f'<div class="tile"><b>{latest["changes"].get(kind, 0)}</b><span class="chg {kind}">{kind}</span></div>'
                           for kind in ("regressed", "fixed"))
                 + f'<div class="tile"><b>{counts.get("PENDING", 0)}</b>{_badge("PENDING")}</div>'
                 + f'<div class="tile"><b>{len(runs)}</b><span>runs recorded</span></div>')
        dashboard = (
            '<h2>Runs</h2><p class="hint">One row per recorded run, newest first, labelled with the task it verified. '
            '"regressed" and "fixed" compare each scenario with its previous execution.</p>'
            + "".join(_run_html(run, index == 0) for index, run in enumerate(runs))
            + '<h2>Scenarios by run</h2><p class="hint">Each column is a run, oldest to newest; hover a cell for details.</p>'
            + _matrix_html(report, runs) + '<h2>By feature</h2>'
            '<p class="hint">Latest status of every story and scenario, with the steps of its last execution.</p>')
    blocks = []
    for epic in sorted(report["epics"], key=lambda e: e["status"] == "NOT MIGRATED"):  # epics with results first
        if epic["status"] == "NOT MIGRATED":
            blocks.append(f'<div class="plain"><span class="id">{esc(epic["id"])}</span>{_badge("NOT MIGRATED")}'
                          f'<span class="title">{esc(epic["title"])}</span>'
                          f'<span class="small">{epic["story_count"]} stories, no feature files</span></div>')
            continue
        stories = "".join(
            f'<details class="story" open><summary><span class="id">{esc(s["id"])}</span>{_badge(s["status"])}'
            f'<span class="title">{esc(s["title"])}</span><span class="small">{len(s["scenarios"])} scenarios</span></summary>'
            f'{"".join(_scenario_html(row) for row in s["scenarios"])}</details>' for s in epic["stories"])
        blocks.append(f'<details class="epic" open><summary><span class="id">{esc(epic["id"])}</span>{_badge(epic["status"])}'
                      f'<span class="title">{esc(epic["title"])}</span></summary>{stories}</details>')
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1"><title>Feature test report</title>'
            f'<style>{HTML_STYLE}</style></head><body><main><h1>Feature test report</h1>'
            f'<div class="meta">Generated {esc(generated_at)} from {esc(store)}. Each bar is one recorded run, oldest to '
            f'newest; hover for its date and commit. A * after a commit means the tree had uncommitted changes.</div>'
            f'<div class="tiles">{tiles}</div>{dashboard}{"".join(blocks)}</main></body></html>')


# ---------------------------------------------------------------- cli

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--store", default=os.environ.get("SITEPULSE_TEST_HISTORY", DEFAULT_STORE),
                        help=f"history store: git:<branch> or a directory (default {DEFAULT_STORE})")
    sub = parser.add_subparsers(dest="command", required=True)
    chk = sub.add_parser("check", help="static consistency gate")
    chk.add_argument("--require-run", action="store_true",
                     help="also fail when the current branch has no recorded run in the history")
    task_report = sub.add_parser("task-report", help="the latest run of the current task as markdown")
    task_report.add_argument("--task", help="task label (default: runs made on the current branch)")
    rec = sub.add_parser("record", help="append the last run to the history")
    rec.add_argument("--executions", type=Path, default=EXECUTIONS)
    rec.add_argument("--trigger", help="who started the run (default: ci when $CI is set, else local)")
    rec.add_argument("--task", help="label of the work this run verifies (default: $SITEPULSE_TASK, else the branch)")
    rec.add_argument("--push", metavar="REMOTE", help="git:<branch> store only: also push the branch to this remote")
    rep = sub.add_parser("report", help="latest status per epic, story and scenario")
    rep.add_argument("--epic")
    rep.add_argument("--story")
    rep.add_argument("--steps", action="store_true", help="show the steps of each scenario's last run")
    hist = sub.add_parser("history", help="runs over time for an SC-, STORY- or EPIC- id")
    hist.add_argument("id")
    hist.add_argument("--limit", type=int, default=20)
    runs_cmd = sub.add_parser("runs", help="one line per recorded run")
    runs_cmd.add_argument("--limit", type=int, default=20)
    runs_cmd.add_argument("--detail", action="store_true", help="list the scenarios of each run")
    page = sub.add_parser("html", help="the report as one self-contained HTML page")
    page.add_argument("--epic")
    page.add_argument("--story")
    page.add_argument("--out", type=Path, default=HTML_REPORT)
    for command in (rep, hist, page, runs_cmd, task_report):
        command.add_argument("--runs", type=int, default=200, help="how many of the newest runs to read")
    args = parser.parse_args(argv)

    if args.command == "check":
        catalogue = load_catalogue()
        problems = check(catalogue)
        if args.require_run:
            branch = run_metadata()["branch"]
            if not runs_of_task(build_runs(load_history(open_store(args.store)), catalogue, limit=10_000), None, branch):
                problems.append(f"no test run is recorded for branch {branch}: run the suite with "
                                f"`scripts/gui_e2e.py run --record --task <task>` and commit .specify/executions")
        summary = {"migrated_epics": catalogue.migrated_epics, "scenarios": len(catalogue.scenarios),
                   "by_mode": dict(Counter(s.mode for s in catalogue.scenarios)),
                   "linked_tests": sum(len(v) for v in catalogue.links.values())}
        if args.json:
            print(json.dumps({"status": "FAILED" if problems else "PASSED", "problems": problems, **summary}, indent=2))
        else:
            print("\n".join(problems) if problems else
                  f"OK: {summary['scenarios']} scenarios in {', '.join(summary['migrated_epics']) or 'no epic'} "
                  f"({summary['by_mode']}), {summary['linked_tests']} linked tests")
        return 1 if problems else 0

    store = open_store(args.store)
    if args.command == "record":
        meta = run_metadata(trigger=args.trigger, task=args.task)
        count = record_run(args.executions, store, meta)
        if count:
            run = next(r for r in build_runs(load_history(store, 10_000), load_catalogue(), limit=10_000)
                       if r["run_id"] == meta["run_id"])
            store.write(f"reports/{meta['run_id'][:4]}/{meta['run_id']}.md", run_markdown(run),
                        f"Test report {meta['run_id']}")
        if count and args.push:
            if not isinstance(store, GitStore):
                parser.error("--push needs a git:<branch> store")
            store.push(args.push)
        result = {"run_id": meta["run_id"], "records": count, "store": store.describe(), "pushed": bool(count and args.push)}
        print(json.dumps(result) if args.json else
              (f"recorded {count} scenario executions as {meta['run_id']} in {store.describe()}" if count
               else f"nothing to record: {args.executions} has no executions"))
        return 0

    history = load_history(store, args.runs)
    if args.command == "history":
        result = build_history(history, args.id, args.limit)
        print(json.dumps(result, indent=2, ensure_ascii=False)) if args.json else print_history(result)
        return 0
    catalogue = load_catalogue()
    if args.command == "task-report":
        mine = runs_of_task(build_runs(history, catalogue, limit=10_000), args.task, run_metadata()["branch"])
        if not mine:
            print("no run recorded for this task", file=sys.stderr)
            return 1
        print(json.dumps(mine[0], indent=2, ensure_ascii=False) if args.json else run_markdown(mine[0]), end="")
        return 0
    if args.command == "runs":
        runs = build_runs(history, catalogue, args.limit)
        print(json.dumps(runs, indent=2, ensure_ascii=False)) if args.json else print_runs(runs, args.detail)
        return 0
    report = build_report(catalogue, history, args.epic, args.story)
    if args.command == "html":
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(render_html(report, datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
                                        store.describe(), build_runs(history, catalogue)), encoding="utf-8")
        print(json.dumps({"report": str(args.out)}) if args.json else f"wrote {args.out}")
        return 0
    print(json.dumps(report, indent=2, ensure_ascii=False)) if args.json else print_report(report, args.steps)
    return 1 if FAILING & set(report["story_status_counts"]) else 0


if __name__ == "__main__":
    sys.exit(main())
