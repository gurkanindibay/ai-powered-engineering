import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import cargo_target_pool as pool_tool  # noqa: E402

DAY = 86400.0


class Clock:
    def __init__(self, now=1_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


def make_cargo_target(path: Path) -> Path:
    path.mkdir(parents=True)
    (path / pool_tool.CACHEDIR_TAG).write_text(f"{pool_tool.CARGO_TAG_SIGNATURE}\n# cache dir\n")
    return path


def write_bytes(path: Path, size: int, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)
    if executable:
        path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_main(*argv, env=None):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = pool_tool.main(list(argv), env=env if env is not None else {})
    return code, out.getvalue(), err.getvalue()


class PoolTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.root = self.tmp / "pool"
        self.clock = Clock()

    def pool(self, slots=2):
        return pool_tool.Pool(self.root, slots, clock=self.clock)


class LeaseTests(PoolTestCase):
    def test_one_slot_cannot_be_leased_twice(self):
        pool = self.pool(slots=1)
        first = pool.try_lease("fp")
        self.assertIsNotNone(first)
        self.assertIsNone(pool.try_lease("fp"))
        first.release()
        self.assertIsNotNone(pool.try_lease("fp"))

    def test_two_leases_get_different_slots(self):
        pool = self.pool(slots=2)
        a, b = pool.try_lease("fp"), pool.try_lease("fp")
        self.assertNotEqual(a.slot.name, b.slot.name)
        self.assertIsNone(pool.try_lease("fp"))

    def test_lease_is_seen_by_a_second_pool_object(self):
        held = self.pool(slots=1).try_lease("fp")
        self.assertIsNone(self.pool(slots=1).try_lease("fp"))
        self.assertTrue(self.pool(slots=1).is_leased(held.slot))

    def test_release_is_idempotent(self):
        lease = self.pool(slots=1).try_lease("fp")
        lease.release()
        lease.release()

    def test_prefers_most_recently_used_warm_slot(self):
        pool = self.pool(slots=3)
        for index, when in ((0, 10.0), (1, 30.0), (2, 20.0)):
            self.clock.now = when
            lease = pool.try_lease("fp")
            self.assertIsNotNone(lease)
            lease.release()
        # Re-stamp so slot-1 is the newest regardless of acquire order.
        pool.slot(1).write_meta("fp", 99.0)
        chosen = pool.try_lease("fp")
        self.assertEqual(chosen.slot.name, "slot-1")

    def test_fingerprint_change_wipes_the_slot(self):
        pool = self.pool(slots=1)
        lease = pool.try_lease("fp-a")
        write_bytes(lease.slot.path / "debug" / "deps" / "dep.rlib", 100)
        lease.release()
        warm = pool.try_lease("fp-a")
        self.assertTrue((warm.slot.path / "debug" / "deps" / "dep.rlib").exists())
        warm.release()
        cold = pool.try_lease("fp-b")
        self.assertFalse((cold.slot.path / "debug").exists())

    def test_lease_waits_until_a_slot_frees_up(self):
        pool = self.pool(slots=1)
        held = pool.try_lease("fp")
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            self.clock.now += seconds
            if len(sleeps) == 2:
                held.release()

        lease = pool.lease("fp", wait=10, sleep=sleep)
        self.assertIsNotNone(lease)
        self.assertEqual(len(sleeps), 2)

    def test_lease_gives_up_after_the_wait(self):
        pool = self.pool(slots=1)
        pool.try_lease("fp")

        def sleep(seconds):
            self.clock.now += seconds

        self.assertIsNone(pool.lease("fp", wait=3, sleep=sleep))

    def test_fewer_than_one_slot_is_rejected(self):
        with self.assertRaises(pool_tool.PoolError):
            pool_tool.Pool(self.root, 0)


class SweepTests(PoolTestCase):
    def fill(self, pool, size=100):
        lease = pool.try_lease("fp")
        write_bytes(lease.slot.path / "debug" / "deps" / "x.rlib", size)
        return lease

    def test_sweep_wipes_only_old_idle_slots(self):
        pool = self.pool(slots=2)
        self.clock.now = 0.0
        # Hold both leases at once: a released slot is warm and would be handed out again.
        old, recent = self.fill(pool), self.fill(pool)
        old.release()
        self.clock.now = 6 * DAY
        recent.release()
        self.clock.now = 8 * DAY
        report = pool.sweep(max_age_days=7)
        self.assertEqual(report["swept"], [old.slot.name])
        self.assertFalse(old.slot.path.exists())
        self.assertTrue(recent.slot.path.exists())
        self.assertGreater(report["freed_bytes"], 0)

    def test_sweep_never_touches_a_leased_slot(self):
        pool = self.pool(slots=1)
        self.clock.now = 0.0
        lease = self.fill(pool)
        self.clock.now = 30 * DAY
        report = pool.sweep(max_age_days=7)
        self.assertEqual(report["swept"], [])
        self.assertTrue((lease.slot.path / "debug").exists())

    def test_sweep_removes_old_orphaned_temp_dirs(self):
        pool = self.pool(slots=1)
        self.root.mkdir(parents=True)
        orphan = self.root / "tmp-abc"
        orphan.mkdir()
        os.utime(orphan, (0, 0))
        fresh = self.root / "tmp-def"
        fresh.mkdir()
        self.clock.now = pool_tool.time.time()
        report = pool.sweep(max_age_days=7)
        self.assertIn("tmp-abc", report["swept"])
        self.assertFalse(orphan.exists())
        self.assertTrue(fresh.exists())


class WatchdogTests(PoolTestCase):
    def make_slots(self, pool, count):
        """Fill `count` slots; slot i is released at time i + 1, so lower indexes are older."""
        leases = []
        for _ in range(count):
            lease = pool.try_lease("fp")
            write_bytes(lease.slot.path / "debug" / "deps" / "x.rlib", 100)
            leases.append(lease)
        for when, lease in enumerate(leases):
            self.clock.now = float(when + 1)
            lease.release()
        return [lease.slot for lease in leases]

    def test_wipes_least_recently_used_first_until_enough_is_free(self):
        pool = self.pool(slots=3)
        slots = self.make_slots(pool, 3)
        free = {"value": 10}

        def fake_free(_path):
            return free["value"]

        original = pool._wipe_if_idle

        def wipe_and_free(slot):
            free["value"] += 10
            return original(slot)

        pool._wipe_if_idle = wipe_and_free
        report = pool.watchdog(min_free_bytes=30, free=fake_free)
        self.assertTrue(report["ok"])
        self.assertEqual(report["swept"], [slots[0].name, slots[1].name])
        self.assertTrue(slots[2].path.exists())

    def test_does_nothing_when_there_is_enough_space(self):
        pool = self.pool(slots=2)
        slots = self.make_slots(pool, 2)
        report = pool.watchdog(min_free_bytes=5, free=lambda _p: 100)
        self.assertTrue(report["ok"])
        self.assertEqual(report["swept"], [])
        self.assertTrue(all(s.path.exists() for s in slots))

    def test_leased_slots_are_skipped_and_the_failure_is_reported(self):
        pool = self.pool(slots=1)
        lease = pool.try_lease("fp")
        write_bytes(lease.slot.path / "debug" / "deps" / "x.rlib", 100)
        report = pool.watchdog(min_free_bytes=10, free=lambda _p: 0)
        self.assertFalse(report["ok"])
        self.assertEqual(report["swept"], [])
        self.assertTrue(lease.slot.path.exists())


class MeasureTests(PoolTestCase):
    def test_reports_each_part_of_a_profile(self):
        target = make_cargo_target(self.tmp / "target")
        write_bytes(target / "debug" / "deps" / "libdep.rlib", 8192)
        write_bytes(target / "debug" / "deps" / "integration_tests-abc123", 8192, executable=True)
        write_bytes(target / "debug" / "deps" / "other_tests-def456", 8192, executable=True)
        write_bytes(target / "debug" / "incremental" / "crate" / "query.bin", 8192)
        write_bytes(target / "release" / "deps" / "libdep.rlib", 4096)
        report = pool_tool.measure(target)
        debug = report["profiles"]["debug"]
        self.assertEqual(debug["binaries_in_deps"], 2)
        self.assertGreaterEqual(debug["deps"], 3 * 8192)
        self.assertGreaterEqual(debug["incremental"], 8192)
        self.assertGreaterEqual(report["total_bytes"], debug["total"])
        self.assertEqual(report["profiles"]["release"]["binaries_in_deps"], 0)

    def test_missing_target_dir_is_reported_not_an_error(self):
        report = pool_tool.measure(self.tmp / "nope")
        self.assertFalse(report["exists"])
        self.assertEqual(report["total_bytes"], 0)

    def test_hard_links_are_counted_once(self):
        folder = self.tmp / "links"
        write_bytes(folder / "a.bin", 8192)
        os.link(folder / "a.bin", folder / "b.bin")
        single = self.tmp / "single"
        write_bytes(single / "a.bin", 8192)
        self.assertEqual(pool_tool.dir_size(folder), pool_tool.dir_size(single))

    def test_cli_json(self):
        target = make_cargo_target(self.tmp / "target")
        write_bytes(target / "debug" / "deps" / "libdep.rlib", 4096)
        code, out, _ = run_main("--json", "measure", "--target-dir", str(target))
        self.assertEqual(code, 0)
        self.assertIn("debug", json.loads(out)["profiles"])

    def test_json_flag_is_accepted_after_the_subcommand(self):
        code, out, _ = run_main("measure", "--json", "--target-dir", str(self.tmp / "missing"))
        self.assertEqual(code, 0)
        self.assertFalse(json.loads(out)["exists"])


class CleanWorktreeTests(PoolTestCase):
    def worktree(self):
        tree = self.tmp / "wt"
        (tree).mkdir()
        (tree / ".git").write_text("gitdir: /elsewhere\n")
        return tree

    def test_removes_only_cargo_target_dirs(self):
        tree = self.worktree()
        backend = make_cargo_target(tree / "apps" / "backend" / "target")
        write_bytes(backend / "debug" / "deps" / "x.rlib", 100)
        other_cargo = make_cargo_target(tree / "tool" / "target")
        plain = tree / "docs" / "target"  # a folder that merely happens to be called target
        write_bytes(plain / "keep.md", 10)
        report = pool_tool.clean_worktree(tree, dry_run=False)
        self.assertEqual(sorted(report["removed"]), ["apps/backend/target", "tool/target"])
        self.assertFalse(backend.exists())
        self.assertFalse(other_cargo.exists())
        self.assertTrue((plain / "keep.md").exists())

    def test_dry_run_keeps_everything(self):
        tree = self.worktree()
        target = make_cargo_target(tree / "target")
        write_bytes(target / "debug" / "deps" / "x.rlib", 100)
        report = pool_tool.clean_worktree(tree, dry_run=True)
        self.assertEqual(report["removed"], ["target"])
        self.assertTrue(target.exists())

    def test_git_directory_is_never_entered(self):
        tree = self.tmp / "wt"
        (tree / ".git").mkdir(parents=True)
        inside_git = make_cargo_target(tree / ".git" / "target")
        report = pool_tool.clean_worktree(tree, dry_run=False)
        self.assertEqual(report["removed"], [])
        self.assertTrue(inside_git.exists())

    def test_refuses_a_directory_that_is_not_a_worktree(self):
        folder = self.tmp / "plain"
        make_cargo_target(folder / "target")
        with self.assertRaises(pool_tool.PoolError):
            pool_tool.clean_worktree(folder, dry_run=False)
        self.assertTrue((folder / "target").exists())

    def test_cli_exit_code_two_for_a_non_worktree(self):
        code, _, err = run_main("clean-worktree", str(self.tmp))
        self.assertEqual(code, 2)
        self.assertIn("not a git worktree", err)


class RunTests(PoolTestCase):
    def run_pool(self, *extra, command=None, env=None):
        probe = self.tmp / "probe.json"
        script = (
            "import json, os, sys; "
            "json.dump({k: os.environ.get(k) for k in "
            "('CARGO_TARGET_DIR', 'CARGO_INCREMENTAL', 'CARGO_TARGET_POOL_SLOT')}, open(sys.argv[1], 'w'))"
        )
        command = command or [sys.executable, "-c", script, str(probe)]
        base = ["--pool-dir", str(self.root), "--slots", "1", "run", *extra, "--", *command]
        code, out, err = run_main(*base, env=env)
        seen = json.loads(probe.read_text()) if probe.exists() else None
        return code, seen, err

    def test_runs_the_command_inside_a_leased_slot(self):
        code, seen, _ = self.run_pool()
        self.assertEqual(code, 0)
        self.assertEqual(seen["CARGO_TARGET_DIR"], str(self.root / "slot-0"))
        self.assertEqual(seen["CARGO_INCREMENTAL"], "0")
        self.assertEqual(seen["CARGO_TARGET_POOL_SLOT"], "slot-0")

    def test_keeps_an_incremental_setting_the_caller_already_made(self):
        code, seen, _ = self.run_pool(env={"CARGO_INCREMENTAL": "1", "PATH": os.environ.get("PATH", "")})
        self.assertEqual(code, 0)
        self.assertEqual(seen["CARGO_INCREMENTAL"], "1")

    def test_the_slot_is_free_again_after_the_command(self):
        self.run_pool()
        self.assertFalse(self.pool(slots=1).is_leased(self.pool(slots=1).slot(0)))

    def test_propagates_the_exit_code_and_still_releases(self):
        code, _, _ = self.run_pool(command=[sys.executable, "-c", "raise SystemExit(7)"])
        self.assertEqual(code, 7)
        self.assertIsNotNone(self.pool(slots=1).try_lease("anything"))

    def test_fails_with_75_when_every_slot_is_busy(self):
        held = self.pool(slots=1).try_lease("fp")
        code, seen, err = self.run_pool("--on-busy", "fail")
        self.assertEqual(code, pool_tool.EXIT_BUSY)
        self.assertIsNone(seen)
        self.assertIn("no free slot", err)
        held.release()

    def test_temp_policy_uses_a_throwaway_dir_that_is_deleted(self):
        held = self.pool(slots=1).try_lease("fp")
        code, seen, _ = self.run_pool("--on-busy", "temp")
        self.assertEqual(code, 0)
        target = Path(seen["CARGO_TARGET_DIR"])
        self.assertTrue(target.name.startswith("tmp-"))
        self.assertFalse(target.exists())
        held.release()

    def test_refuses_to_start_below_the_free_space_threshold(self):
        code, seen, err = self.run_pool("--min-free-gb", str(10**9))
        self.assertEqual(code, pool_tool.EXIT_LOW_DISK)
        self.assertIsNone(seen)
        self.assertIn("refusing to start", err)

    def test_a_command_is_required(self):
        code, _, err = run_main("--pool-dir", str(self.root), "run", "--")
        self.assertEqual(code, 2)
        self.assertIn("needs a command", err)

    def test_slot_stays_leased_while_a_child_still_holds_it(self):
        # The descriptor is inherited, so a leftover child keeps the slot leased after the parent is gone.
        lease = self.pool(slots=1).try_lease("fp")
        os.set_inheritable(lease.fd, True)
        import subprocess
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], pass_fds=(lease.fd,))
        try:
            lease.release()
            self.assertTrue(self.pool(slots=1).is_leased(self.pool(slots=1).slot(0)))
        finally:
            child.kill()
            child.wait()
        self.assertFalse(self.pool(slots=1).is_leased(self.pool(slots=1).slot(0)))


class ConfigTests(unittest.TestCase):
    def test_pool_dir_and_slots_come_from_the_environment(self):
        env = {"CARGO_TARGET_POOL_DIR": "/data/pool", "CARGO_TARGET_POOL_SLOTS": "6"}
        self.assertEqual(pool_tool.default_pool_dir(env), Path("/data/pool"))
        self.assertEqual(pool_tool.default_slots(env), 6)
        self.assertEqual(pool_tool.default_slots({}), pool_tool.DEFAULT_SLOTS)

    def test_a_bad_slot_count_is_a_usage_error(self):
        code, _, err = run_main("status", env={"CARGO_TARGET_POOL_SLOTS": "many"})
        self.assertEqual(code, 2)
        self.assertIn("CARGO_TARGET_POOL_SLOTS", err)

    def test_fingerprint_changes_with_rustflags_and_toolchain(self):
        base = pool_tool.build_fingerprint({}, "rustc 1")
        self.assertNotEqual(base, pool_tool.build_fingerprint({"RUSTFLAGS": "-C target-cpu=native"}, "rustc 1"))
        self.assertNotEqual(base, pool_tool.build_fingerprint({}, "rustc 2"))
        self.assertEqual(base, pool_tool.build_fingerprint({"UNRELATED": "x"}, "rustc 1"))


if __name__ == "__main__":
    unittest.main()
