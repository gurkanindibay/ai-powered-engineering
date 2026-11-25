"""Archive branch publication tests against a local bare repository."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "pages_archive.py"
spec = importlib.util.spec_from_file_location("pages_archive", SCRIPT)
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)

IDENTITY = {"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
            "GIT_CONFIG_GLOBAL": os.devnull}


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def write(root: Path, name: str, text: str) -> None:
    (root / name).parent.mkdir(parents=True, exist_ok=True)
    (root / name).write_text(text, encoding="utf-8")


class PagesArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        patcher = mock.patch.dict(os.environ, IDENTITY)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.root = Path(temporary.name)
        self.remote = self.root / "remote.git"
        git(self.root, "init", "-q", "--bare", "-b", "master", str(self.remote))
        self.seed = self.root / "seed"
        git(self.root, "init", "-q", "-b", "master", str(self.seed))
        git(self.seed, "commit", "-q", "--allow-empty", "-m", "init")
        git(self.seed, "remote", "add", "origin", str(self.remote))
        git(self.seed, "push", "-q", "origin", "master")
        self.checkouts = 0

    def seed_gh_pages(self) -> str:
        git(self.seed, "switch", "-q", "--orphan", "gh-pages")
        for number in (1, 2):
            write(self.seed, f"reports/{number}-1/summary.json", f'{{"run": {number}}}')
            git(self.seed, "add", "-A")
            git(self.seed, "commit", "-q", "-m", f"publish {number}")
        git(self.seed, "push", "-q", "origin", "gh-pages")
        return git(self.seed, "rev-parse", "gh-pages")

    def checkout(self) -> tuple[Path, Path]:
        """A fresh shallow clone, like the Actions checkout."""
        self.checkouts += 1
        repo = self.root / f"checkout{self.checkouts}"
        git(self.root, "clone", "-q", "--depth=1", self.remote.as_uri(), str(repo))
        return repo, self.root / f"site{self.checkouts}"

    def publish_run(self, number: int) -> dict:
        repo, site = self.checkout()
        archive.restore(repo, site)
        write(site, f"reports/{number}-1/summary.json", "{}")
        return archive.publish(site, f"publish {number}")

    def archive_files(self) -> list[str]:
        return git(self.remote, "ls-tree", "-r", "--name-only", "gh-pages-archive").splitlines()

    def archive_log(self) -> list[str]:
        return git(self.remote, "log", "--format=%s", "gh-pages-archive").splitlines()

    def test_first_publish_seeds_from_gh_pages_and_leaves_it_untouched(self):
        old_tip = self.seed_gh_pages()
        repo, site = self.checkout()
        self.assertEqual(archive.restore(repo, site)["source"], "gh-pages")
        write(site, "reports/3-1/summary.json", "{}")

        result = archive.publish(site, "publish 3")

        self.assertTrue(result["published"])
        self.assertEqual(self.archive_log(), ["publish 3"])
        self.assertEqual(git(self.remote, "rev-parse", "gh-pages"), old_tip)
        self.assertEqual(git(self.remote, "rev-list", "--count", "gh-pages"), "2")
        self.assertEqual(self.archive_files(), [f"reports/{n}-1/summary.json" for n in (1, 2, 3)])
        self.assertEqual(git(site, "rev-parse", "HEAD"), result["commit"])

    def test_later_publish_keeps_a_single_commit_and_drops_replaced_files(self):
        self.seed_gh_pages()
        repo, site = self.checkout()
        archive.restore(repo, site)
        write(site, "reports/2-1/serenity/index.html", "old tree")
        archive.publish(site, "publish A")

        repo, site = self.checkout()
        self.assertEqual(archive.restore(repo, site)["source"], "gh-pages-archive")
        (site / "reports/2-1/serenity/index.html").unlink()
        write(site, "reports/4-1/summary.json", "{}")
        archive.publish(site, "publish B")

        self.assertEqual(self.archive_log(), ["publish B"])
        self.assertEqual(self.archive_files(), [f"reports/{n}-1/summary.json" for n in (1, 2, 4)])

    def test_starts_an_empty_archive_when_no_branch_exists(self):
        repo, site = self.checkout()
        self.assertIsNone(archive.restore(repo, site)["source"])
        write(site, "reports/1-1/summary.json", "{}")

        archive.publish(site, "first")

        self.assertEqual(self.archive_log(), ["first"])

    def test_unchanged_archive_is_not_pushed_again(self):
        first = self.publish_run(1)
        repo, site = self.checkout()
        archive.restore(repo, site)

        again = archive.publish(site, "second")

        self.assertFalse(again["published"])
        self.assertEqual(again["commit"], first["commit"])
        self.assertEqual(self.archive_log(), ["publish 1"])

    def test_refuses_to_publish_when_an_archived_report_would_be_lost(self):
        self.seed_gh_pages()
        repo, site = self.checkout()
        archive.restore(repo, site)
        (site / "reports/1-1/summary.json").unlink()

        with self.assertRaisesRegex(ValueError, "lost: 1-1"):
            archive.publish(site, "lossy")

        self.assertEqual(git(self.remote, "for-each-ref", "refs/heads/gh-pages-archive"), "")

    def test_refuses_to_overwrite_a_concurrent_publish(self):
        self.publish_run(1)
        stale_repo, stale = self.checkout()
        archive.restore(stale_repo, stale)
        self.publish_run(2)
        write(stale, "reports/3-1/summary.json", "{}")

        with self.assertRaisesRegex(ValueError, "changed since"):
            archive.publish(stale, "stale")

        self.assertEqual(self.archive_log(), ["publish 2"])

    def test_refuses_to_replace_an_archive_created_after_restore(self):
        stale_repo, stale = self.checkout()
        archive.restore(stale_repo, stale)
        self.publish_run(1)
        write(stale, "reports/2-1/summary.json", "{}")

        with self.assertRaisesRegex(ValueError, "changed since"):
            archive.publish(stale, "stale")

        self.assertEqual(self.archive_log(), ["publish 1"])

    def test_unreachable_remote_is_an_error_not_an_empty_archive(self):
        repo, site = self.checkout()
        git(repo, "remote", "set-url", "origin", str(self.root / "missing.git"))

        with self.assertRaisesRegex(ValueError, "ls-remote"):
            archive.restore(repo, site)

        self.assertFalse(site.exists())


if __name__ == "__main__":
    unittest.main()
