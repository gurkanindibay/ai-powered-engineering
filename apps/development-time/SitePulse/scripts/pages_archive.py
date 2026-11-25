#!/usr/bin/env python3
"""Restore and publish the SitePulse Pages archive state without growing git history.

The archive lives on `gh-pages-archive` as one parentless commit that every
publish replaces, so superseded report trees do not accumulate in the branch's
history. `gh-pages` holds the earlier history and is protected against
force-pushes; it is only read, to seed `gh-pages-archive` while that branch does
not exist yet.

Because the replaced commit is not kept, `publish` refuses a tree that is missing
any report archived in the commit it replaces.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

ARCHIVE_BRANCH = "gh-pages-archive"
SEED_BRANCH = "gh-pages"
BOT_NAME = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"
REPORT_SUMMARY = re.compile(r"^reports/(\d+-\d+)/summary\.json$")


def _git(cwd: Path, *args: str) -> str:
    done = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=False)
    if done.returncode:
        command = next(arg for arg in args if not arg.startswith("-") and "=" not in arg)
        raise ValueError(f"git {command} failed: {done.stderr.strip()[-500:]}")
    return done.stdout.strip()


def _remote_tip(repo: Path, remote: str, branch: str) -> str | None:
    """Return the remote branch SHA, or None only when the remote says it does not exist."""
    ref = f"refs/heads/{branch}"
    # An empty listing exits 0 here; any failure to reach the remote raises instead of looking absent.
    for line in _git(repo, "ls-remote", remote, ref).splitlines():
        sha, _, name = line.partition("\t")
        if name == ref:
            return sha
    return None


def restore(repo: Path, site: Path, remote: str = "origin") -> dict:
    """Check out the latest archive state as a worktree at `site`."""
    for branch in (ARCHIVE_BRANCH, SEED_BRANCH):
        if _remote_tip(repo, remote, branch) is None:
            continue
        # Only the tip tree is needed; never download the branch's history.
        _git(repo, "fetch", "--no-tags", "--depth=1", remote, f"refs/heads/{branch}")
        base = _git(repo, "rev-parse", "FETCH_HEAD")
        _git(repo, "worktree", "add", "--detach", str(site.resolve()), base)
        return {"source": branch, "base": base, "site": str(site)}
    _git(repo, "worktree", "add", "--orphan", "-b", "pages-state", str(site.resolve()))
    return {"source": None, "base": None, "site": str(site)}


def _reports(site: Path, treeish: str) -> set[str]:
    names = _git(site, "ls-tree", "-r", "--name-only", treeish, "--", "reports").splitlines()
    return {match.group(1) for name in names if (match := REPORT_SUMMARY.match(name))}


def publish(site: Path, message: str, remote: str = "origin") -> dict:
    """Replace the archive branch with one parentless commit of the `site` worktree."""
    has_base = subprocess.run(["git", "rev-parse", "--verify", "--quiet", "HEAD"],
                              cwd=site, capture_output=True, check=False).returncode == 0
    base = _git(site, "rev-parse", "HEAD") if has_base else None
    _git(site, "add", "-A")
    tree = _git(site, "write-tree")
    if base:
        # `ls-tree` limits paths to the current directory, so both calls run at the worktree root.
        missing = sorted(_reports(site, base) - _reports(site, tree))
        if missing:
            raise ValueError(f"refusing to publish: archived reports would be lost: {', '.join(missing[:10])}")
    tip = _remote_tip(site, remote, ARCHIVE_BRANCH)
    if tip and tip != base:
        raise ValueError(f"refusing to publish: {ARCHIVE_BRANCH} changed since the archive was restored")
    if tip and tree == _git(site, "rev-parse", f"{base}^{{tree}}"):
        return {"published": False, "commit": base, "branch": ARCHIVE_BRANCH}
    commit = _git(site, "-c", f"user.name={BOT_NAME}", "-c", f"user.email={BOT_EMAIL}",
                  "commit-tree", tree, "-m", message)
    # The lease rejects the push if another writer moved (or created) the branch in the meantime.
    _git(site, "push", f"--force-with-lease=refs/heads/{ARCHIVE_BRANCH}:{tip or ''}",
         remote, f"{commit}:refs/heads/{ARCHIVE_BRANCH}")
    # Later workflow steps package `HEAD` of this worktree.
    _git(site, "update-ref", "--no-deref", "HEAD", commit)
    return {"published": True, "commit": commit, "branch": ARCHIVE_BRANCH}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the result as JSON")
    parser.add_argument("--remote", default="origin")
    subparsers = parser.add_subparsers(dest="command", required=True)
    restore_parser = subparsers.add_parser("restore", help="check out the archive state as a git worktree")
    restore_parser.add_argument("--repo", type=Path, default=Path("."))
    restore_parser.add_argument("--site", type=Path, required=True)
    publish_parser = subparsers.add_parser(
        "publish", help=f"REPLACE branch {ARCHIVE_BRANCH} on the remote with the worktree's state")
    publish_parser.add_argument("--site", type=Path, required=True)
    publish_parser.add_argument("--message", required=True)
    args = parser.parse_args()
    try:
        if args.command == "restore":
            result = restore(args.repo, args.site, args.remote)
        else:
            result = publish(args.site, args.message, args.remote)
    except (OSError, ValueError) as error:
        parser.exit(1, f"pages_archive.py: error: {error}\n")
    if args.json:
        print(json.dumps(result))
    elif args.command == "restore":
        print(f"Restored archive state from {result['source'] or 'nothing (new archive)'}.")
    else:
        print(f"{'Published' if result['published'] else 'Unchanged'} {result['branch']} at {result['commit']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
