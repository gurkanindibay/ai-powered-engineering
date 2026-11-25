"""Tests for scripts/cleanup_unused_worktrees.py against real temporary repositories."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import cleanup_unused_worktrees as cleanup  # noqa: E402

# Fixtures are seconds old, so evaluating two grace periods ahead makes them idle.
GRACE = 60 * 60


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@example.test", *args],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


class CleanupTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)
        origin = self.root / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "master", str(origin)], check=True)
        self.repo = self.root / "repo"
        subprocess.run(["git", "clone", "-q", str(origin), str(self.repo)],
                       check=True, capture_output=True)
        git(self.repo, "checkout", "-q", "-B", "master")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base")
        git(self.repo, "push", "-q", "-u", "origin", "master")
        self.states: list[str] = []
        patcher = mock.patch.object(cleanup, "pr_states", lambda repo, branch: self.states)
        patcher.start()
        self.addCleanup(patcher.stop)

    def add_worktree(self, name: str, commit: bool = False, push: bool = False) -> Path:
        path = self.root / name
        git(self.repo, "worktree", "add", "-q", "-b", name, str(path), "origin/master")
        if commit:
            git(path, "commit", "-q", "--allow-empty", "-m", name)
        if push:
            git(path, "push", "-q", "-u", "origin", name)
        return path

    def decide(self, path: Path, now: float | None = None) -> cleanup.Decision:
        listing = git(self.repo, "worktree", "list", "--porcelain")
        entry = next(e for e in cleanup.parse_worktree_list(listing) if e.path == str(path))
        return cleanup.evaluate(self.repo, entry, "master", GRACE,
                                time.time() + 2 * GRACE if now is None else now)

    def test_idle_clean_delivered_worktree_is_eligible(self) -> None:
        self.assertEqual(self.decide(self.add_worktree("done")).action, "would_remove")

    def test_recently_active_worktree_is_kept(self) -> None:
        decision = self.decide(self.add_worktree("fresh"), now=time.time())
        self.assertEqual((decision.action, decision.reason), ("kept", "recently active"))

    def test_locked_worktree_is_kept(self) -> None:
        path = self.add_worktree("held")
        git(self.repo, "worktree", "lock", str(path))
        self.assertEqual(self.decide(path).reason, "locked")

    @unittest.skipUnless(Path("/proc").is_dir(), "needs Linux /proc")
    def test_worktree_with_a_running_process_is_kept(self) -> None:
        path = self.add_worktree("busy")
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], cwd=path)
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        self.assertIn("running process", self.decide(path).reason)

    def test_untracked_file_keeps_the_worktree(self) -> None:
        path = self.add_worktree("dirty")
        (path / "notes.txt").write_text("unsaved")
        self.assertEqual(self.decide(path).reason, "uncommitted or untracked changes")

    def test_undelivered_commit_is_kept(self) -> None:
        path = self.add_worktree("wip", commit=True, push=True)
        self.assertEqual(self.decide(path).action, "kept")

    def test_pushed_branch_with_merged_pr_is_eligible(self) -> None:
        path = self.add_worktree("merged", commit=True, push=True)
        self.states = ["MERGED"]
        self.assertEqual(self.decide(path).action, "would_remove")

    def test_unpushed_commit_after_merged_pr_is_kept(self) -> None:
        path = self.add_worktree("ahead", commit=True, push=True)
        git(path, "commit", "-q", "--allow-empty", "-m", "local only")
        self.states = ["MERGED"]
        self.assertEqual(self.decide(path).action, "kept")

    def test_open_pr_wins_over_an_older_merged_pr(self) -> None:
        path = self.add_worktree("reused", commit=True, push=True)
        self.states = ["OPEN", "MERGED"]
        decision = self.decide(path)
        self.assertEqual((decision.action, decision.reason), ("kept", "branch has an open PR"))

    def test_status_check_does_not_rewrite_the_index(self) -> None:
        path = self.add_worktree("quiet")
        (path / "file.txt").write_text("x")
        git(path, "add", "file.txt")
        git(path, "commit", "-q", "-m", "file")
        # A new mtime with unchanged content makes a plain `git status` refresh the index.
        later = time.time() + 5
        os.utime(path / "file.txt", (later, later))
        index = Path(cleanup.git_dir_of(path)) / "index"
        before = index.stat().st_mtime_ns
        self.assertTrue(cleanup.is_clean(path))
        self.assertEqual(index.stat().st_mtime_ns, before)

    def run_main(self, *argv: str) -> dict:
        output = io.StringIO()
        fake_script = self.repo / "scripts" / "cleanup_unused_worktrees.py"
        with mock.patch.object(cleanup, "__file__", str(fake_script)), \
                contextlib.redirect_stdout(output):
            self.assertEqual(cleanup.main(["--json", "--grace-minutes", "0", *argv]), 0)
        return json.loads(output.getvalue())

    def test_dry_run_removes_and_prunes_nothing(self) -> None:
        kept = self.add_worktree("eligible")
        gone = self.add_worktree("deleted-by-hand")
        shutil.rmtree(gone)
        self.run_main()
        self.assertTrue(kept.is_dir())
        self.assertIn(str(gone), git(self.repo, "worktree", "list", "--porcelain"))

    def test_apply_removes_the_worktree_and_keeps_its_branch(self) -> None:
        path = self.add_worktree("eligible")
        report = self.run_main("--apply")
        self.assertEqual([d["action"] for d in report["decisions"]], ["removed"])
        self.assertFalse(path.exists())
        self.assertIn("eligible", git(self.repo, "branch", "--list", "eligible"))


if __name__ == "__main__":
    unittest.main()
