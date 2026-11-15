"""Tests for scripts/e2e_shard.py: duration-balanced sharding of the GUI suite."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _load():
    spec = importlib.util.spec_from_file_location("e2e_shard", PROJECT_ROOT / "scripts" / "e2e_shard.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


shard = _load()


class ParseShardTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(shard.parse_shard("2/4"), (2, 4))
        self.assertEqual(shard.parse_shard(" 1/1 "), (1, 1))

    def test_invalid(self):
        for value in ("0/4", "5/4", "1/0", "2", "a/b", ""):
            with self.assertRaises(ValueError, msg=value):
                shard.parse_shard(value)


class AssignTests(unittest.TestCase):
    def test_every_test_in_exactly_one_shard(self):
        ids = [f"tests/test_{i}.py::t[chromium]" for i in range(37)]
        shards = shard.assign(ids, 4, {t: float(i % 7 + 1) for i, t in enumerate(ids)})
        flat = [t for s in shards for t in s]
        self.assertEqual(sorted(flat), sorted(ids))
        self.assertEqual(len(flat), len(set(flat)))

    def test_deterministic_regardless_of_input_order(self):
        ids = [f"t{i}" for i in range(20)]
        durations = {t: float(i) for i, t in enumerate(ids)}
        self.assertEqual(shard.assign(ids, 3, durations), shard.assign(list(reversed(ids)), 3, durations))

    def test_balances_by_duration(self):
        durations = {"long": 100.0, "a": 30.0, "b": 30.0, "c": 30.0, "d": 10.0}
        shards = shard.assign(durations, 2, durations)
        loads = shard.shard_loads(shards, durations)
        self.assertEqual(sorted(loads), [100.0, 100.0])

    def test_unknown_tests_use_median(self):
        shards = shard.assign(["known1", "known2", "new"], 3, {"known1": 4.0, "known2": 8.0})
        self.assertEqual(sorted(len(s) for s in shards), [1, 1, 1])

    def test_more_shards_than_tests_leaves_empty_shards(self):
        shards = shard.assign(["only"], 3, {})
        self.assertEqual(sorted(len(s) for s in shards), [0, 0, 1])


class LoadDurationsTests(unittest.TestCase):
    def test_latest_duration_per_test_wins_and_skips_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            year = Path(tmp) / "2026"
            year.mkdir()
            rows = [
                {"test": "t::a", "duration_s": 9.0, "started_at": "2026-11-01T00:00:00Z", "status": "PASS"},
                {"test": "t::a", "duration_s": 3.0, "started_at": "2026-11-02T00:00:00Z", "status": "PASS"},
                {"test": "t::b", "duration_s": 0.0, "started_at": "2026-11-02T00:00:00Z", "status": "SKIPPED"},
            ]
            (year / "run.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n", encoding="utf-8")
            self.assertEqual(shard.load_durations(Path(tmp)), {"t::a": 3.0})

    def test_committed_history_is_readable(self):
        self.assertIsInstance(shard.load_durations(), dict)


if __name__ == "__main__":
    unittest.main()
