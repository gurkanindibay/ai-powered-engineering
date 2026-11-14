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
* history:    every recorded run, kept on the local git branch `test-history`
              (runs/<year>/<run id>.jsonl), or in a directory with --store <dir>

Commands
  check                 static gate: every story of a migrated epic has a scenario, ids are
                        unique and consistent, links point at real scenarios
  record                append the last run's executions to the history (--push to share it)
  report                latest status per epic, story and scenario (--steps for step detail)
  history <ID>          runs over time for an SC-, STORY- or EPIC- id

Scenario status: PASS, FAIL, ERROR (setup failed), DEFECT (strict xfail: a known defect),
SKIPPED, NOT RUN (automated, no execution recorded), PENDING (no automation yet).
A story takes the worst status of its scenarios, or MISSING when it has none.

Examples
  python3 scripts/feature_traceability.py check --json
  python3 scripts/feature_traceability.py record
  python3 scripts/feature_traceability.py report --epic EPIC-10 --steps
  python3 scripts/feature_traceability.py history SC-10-01-01 --limit 20
  python3 scripts/feature_traceability.py history STORY-10-05 --json

Exit code: `check` 1 on problems; `report` 1 if a story is FAIL, ERROR or MISSING; otherwise 0.
"""
from __future__ import annotations

import argparse
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
LINK_SOURCES = (("backend/tests", "*.rs"), ("flutter/test", "*.dart"), ("e2e/tests", "*.py"))
DEFAULT_STORE = "git:test-history"

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
        return str(self.path)

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


def run_metadata(repo: Path = ROOT, trigger: str | None = None, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    commit = _git(["rev-parse", "HEAD"], repo, check_rc=False)
    return {
        "run_id": f"{now.strftime('%Y%m%dT%H%M%SZ')}-{commit[:7] or 'nogit'}",
        "started_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": commit,
        "branch": _git(["rev-parse", "--abbrev-ref", "HEAD"], repo, check_rc=False),
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


# ---------------------------------------------------------------- cli

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--store", default=os.environ.get("SITEPULSE_TEST_HISTORY", DEFAULT_STORE),
                        help=f"history store: git:<branch> or a directory (default {DEFAULT_STORE})")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="static consistency gate")
    rec = sub.add_parser("record", help="append the last run to the history")
    rec.add_argument("--executions", type=Path, default=EXECUTIONS)
    rec.add_argument("--trigger", help="who started the run (default: ci when $CI is set, else local)")
    rec.add_argument("--push", metavar="REMOTE", help="also push the history branch to this remote")
    rep = sub.add_parser("report", help="latest status per epic, story and scenario")
    rep.add_argument("--epic")
    rep.add_argument("--story")
    rep.add_argument("--steps", action="store_true", help="show the steps of each scenario's last run")
    hist = sub.add_parser("history", help="runs over time for an SC-, STORY- or EPIC- id")
    hist.add_argument("id")
    hist.add_argument("--limit", type=int, default=20)
    for command in (rep, hist):
        command.add_argument("--runs", type=int, default=200, help="how many of the newest runs to read")
    args = parser.parse_args(argv)

    if args.command == "check":
        catalogue = load_catalogue()
        problems = check(catalogue)
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
        meta = run_metadata(trigger=args.trigger)
        count = record_run(args.executions, store, meta)
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
    report = build_report(load_catalogue(), history, args.epic, args.story)
    print(json.dumps(report, indent=2, ensure_ascii=False)) if args.json else print_report(report, args.steps)
    return 1 if FAILING & set(report["story_status_counts"]) else 0


if __name__ == "__main__":
    sys.exit(main())
