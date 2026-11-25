#!/usr/bin/env python3
"""Duration-balanced sharding for the SitePulse GUI end-to-end suite.

Splits the browser suite into N shards of similar run time, so CI can run them on N
runners at once. Each shard has its own stack (database, backend, web server), so the
tests do not interfere with one another.

Balancing uses the latest recorded `duration_s` per test from committed test history
(.specify/executions/runs/**/*.jsonl) and the cache-fed master CI JUnit history. A test with
no recorded duration counts as the median. The assignment is greedy longest-first, ordered
by test id, so every shard computes the same partition from the same checkout.

As a pytest plugin (loaded by `gui_e2e.py run --shard I/N`, which sets SITEPULSE_E2E_SHARD):
tests outside shard I are deselected after collection, so marker and -k filters still apply
first, and every selected test runs in exactly one shard.

Command line (inspect the balance without running anything):
    python3 scripts/e2e_shard.py plan --shards 4
    python3 scripts/e2e_shard.py --json plan --shards 4
"""
from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parent.parent
RUNS = ROOT / ".specify" / "executions" / "runs"
ENV_VAR = "SITEPULSE_E2E_SHARD"
DEFAULT_SECONDS = 5.0


def parse_shard(value: str) -> Tuple[int, int]:
    """'2/4' -> (2, 4); raises ValueError unless 1 <= index <= count."""
    index_text, sep, count_text = value.strip().partition("/")
    if not sep:
        raise ValueError(f"shard must look like I/N, got {value!r}")
    index, count = int(index_text), int(count_text)
    if count < 1 or not 1 <= index <= count:
        raise ValueError(f"shard index must be between 1 and N, got {value!r}")
    return index, count


def load_durations(runs_dir: Path = RUNS) -> Dict[str, float]:
    """Latest recorded duration per test id (one pytest test may record several scenarios)."""
    latest: Dict[str, Tuple[str, float]] = {}
    for path in sorted(runs_dir.glob("*/*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            test, seconds = record.get("test"), record.get("duration_s")
            if (not test or not isinstance(seconds, (int, float)) or isinstance(seconds, bool)
                    or not math.isfinite(seconds) or record.get("status") == "SKIPPED"):
                continue
            started = str(record.get("started_at", ""))
            if test not in latest or started >= latest[test][0]:
                latest[test] = (started, float(seconds))
    return {test: seconds for test, (_, seconds) in latest.items()}


def junit_test_id(classname: str, name: str) -> str:
    """Convert pytest's JUnit classname/name pair back to the collected node id."""
    module = classname.replace("\\", "/")
    if module.startswith("e2e/"):
        module = module[4:]
    if not module.endswith(".py"):
        module = module.replace(".", "/") + ".py"
    return f"{module}::{name}"


def junit_durations(junit_dir: Path) -> Dict[str, float]:
    """Read non-skipped pytest case durations from all shard JUnit files below a directory."""
    durations: Dict[str, float] = {}
    for path in sorted(junit_dir.rglob("junit.xml")):
        try:
            root = ET.parse(path).getroot()
        except (OSError, ET.ParseError):
            continue
        for case in root.iter("testcase"):
            if case.find("skipped") is not None:
                continue
            try:
                seconds = float(case.get("time", ""))
            except (TypeError, ValueError):
                continue
            if seconds < 0 or not math.isfinite(seconds):
                continue
            classname, name = case.get("classname", ""), case.get("name", "")
            if classname and name:
                durations[junit_test_id(classname, name)] = seconds
    return durations


def update_duration_store(junit_dir: Path, store: Path) -> Dict[str, float]:
    """Merge CI JUnit timings into a compact latest-duration JSONL store."""
    existing = load_durations(store.parent.parent)
    existing.update(junit_durations(junit_dir))
    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    store.parent.mkdir(parents=True, exist_ok=True)
    with store.open("w", encoding="utf-8") as output:
        for test_id, seconds in sorted(existing.items()):
            output.write(json.dumps({"test": test_id, "duration_s": seconds, "started_at": timestamp,
                                     "status": "PASS"}) + "\n")
    return existing


def assign(test_ids: Iterable[str], count: int, durations: Dict[str, float]) -> List[List[str]]:
    """Greedy longest-first bin packing into `count` shards; deterministic for the same inputs."""
    ids = sorted(set(test_ids))
    known = [durations[t] for t in ids if t in durations]
    fallback = statistics.median(known) if known else DEFAULT_SECONDS
    weighted = sorted(((durations.get(t, fallback), t) for t in ids), key=lambda item: (-item[0], item[1]))
    shards: List[List[str]] = [[] for _ in range(count)]
    loads = [0.0] * count
    for seconds, test in weighted:
        target = min(range(count), key=lambda i: (loads[i], i))
        shards[target].append(test)
        loads[target] += seconds
    return shards


def shard_loads(shards: Sequence[Sequence[str]], durations: Dict[str, float]) -> List[float]:
    known = [d for shard in shards for t in shard if (d := durations.get(t)) is not None]
    fallback = statistics.median(known) if known else DEFAULT_SECONDS
    return [round(sum(durations.get(t, fallback) for t in shard), 1) for shard in shards]


# ---------------------------------------------------------------------------
# pytest plugin
# ---------------------------------------------------------------------------

def pytest_collection_modifyitems(config, items) -> None:  # pragma: no cover - exercised through pytest
    value = os.environ.get(ENV_VAR, "").strip()
    if not value:
        return
    index, count = parse_shard(value)
    shards = assign((item.nodeid for item in items), count, load_durations())
    mine = set(shards[index - 1])
    keep = [item for item in items if item.nodeid in mine]
    dropped = [item for item in items if item.nodeid not in mine]
    if dropped:
        config.hook.pytest_deselected(items=dropped)
    items[:] = keep


def pytest_report_header(config) -> Optional[str]:  # pragma: no cover - exercised through pytest
    value = os.environ.get(ENV_VAR, "").strip()
    return f"e2e shard {value} (duration-balanced, scripts/e2e_shard.py)" if value else None


# ---------------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------------

def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="print the plan as JSON")
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan", help="show how the recorded tests split into N shards")
    plan.add_argument("--shards", type=int, default=4, help="number of shards (default 4)")
    ingest = sub.add_parser("ingest-junit", help="merge CI JUnit durations into a shard-history JSONL store")
    ingest.add_argument("--junit-dir", type=Path, required=True, help="directory containing shard junit.xml files")
    ingest.add_argument("--store", type=Path, required=True, help="JSONL duration store to update")
    args = parser.parse_args(argv)
    if args.command == "ingest-junit":
        durations = update_duration_store(args.junit_dir, args.store)
        if args.json:
            print(json.dumps({"tests": len(durations), "store": str(args.store)}, indent=2))
        else:
            print(f"Updated {args.store} with {len(durations)} CI test durations")
        return 0
    if args.shards < 1:
        parser.error("--shards must be at least 1")

    durations = load_durations()
    shards = assign(durations, args.shards, durations)
    loads = shard_loads(shards, durations)
    total = round(sum(durations.values()), 1)
    if args.json:
        print(json.dumps({"tests": len(durations), "total_s": total, "shards": [
            {"shard": f"{i + 1}/{args.shards}", "tests": len(s), "seconds": loads[i]} for i, s in enumerate(shards)
        ]}, indent=2))
    else:
        print(f"{len(durations)} recorded tests, {total}s in sequence; {args.shards} shard(s):")
        for i, shard in enumerate(shards):
            print(f"  shard {i + 1}/{args.shards}: {len(shard):3d} tests, ~{loads[i]}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
