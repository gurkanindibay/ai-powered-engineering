#!/usr/bin/env python3
"""Remove unused git worktrees that are provably safe to drop.

A worktree is removed only when ALL of these hold:
  * it is not the main checkout and is not locked or prunable;
  * it was not modified within the grace period (default 60 minutes),
    so a live session is not pulled out from under its agent;
  * its working tree is clean (no modified or untracked files);
  * its work is delivered: the HEAD commit is an ancestor of origin/<base>,
    or its branch has a PR that is MERGED or CLOSED, and the branch has no
    commits ahead of its upstream;
  * `git worktree remove` (never --force) accepts it.

Branches are kept; only the worktree directory is removed. Stale entries are
pruned at the end. The default mode is a dry run; pass --apply to remove.

Usage:
  python3 scripts/cleanup_unused_worktrees.py            # dry run, text
  python3 scripts/cleanup_unused_worktrees.py --json     # dry run, JSON
  python3 scripts/cleanup_unused_worktrees.py --apply    # remove eligible worktrees
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

DEFAULT_GRACE_MINUTES = 60
DEFAULT_BASE = "master"


@dataclass
class WorktreeEntry:
    path: str
    head: str = ""
    branch: Optional[str] = None
    locked: bool = False
    prunable: bool = False
    detached: bool = False


@dataclass
class Decision:
    path: str
    branch: Optional[str]
    action: str  # "removed", "would_remove", "kept", "error"
    reason: str
    details: dict = field(default_factory=dict)


def run_git(repo: Path, *args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=check,
    )


def parse_worktree_list(porcelain: str) -> list[WorktreeEntry]:
    entries: list[WorktreeEntry] = []
    current: Optional[WorktreeEntry] = None
    for line in porcelain.splitlines():
        if not line:
            if current is not None:
                entries.append(current)
                current = None
            continue
        key, _, value = line.partition(" ")
        if key == "worktree":
            if current is not None:
                entries.append(current)
            current = WorktreeEntry(path=value)
        elif current is None:
            continue
        elif key == "HEAD":
            current.head = value
        elif key == "branch":
            current.branch = value.removeprefix("refs/heads/")
        elif key == "detached":
            current.detached = True
        elif key == "locked":
            current.locked = True
        elif key == "prunable":
            current.prunable = True
    if current is not None:
        entries.append(current)
    return entries


def last_activity_epoch(worktree: Path, git_dir: Optional[str]) -> float:
    candidates = [worktree.stat().st_mtime]
    if git_dir:
        gd = Path(git_dir)
        for name in ("index", "HEAD"):
            target = gd / name
            if target.exists():
                candidates.append(target.stat().st_mtime)
    return max(candidates)


def git_dir_of(worktree: Path) -> Optional[str]:
    result = run_git(worktree, "rev-parse", "--absolute-git-dir")
    return result.stdout.strip() or None if result.returncode == 0 else None


def in_use_by_process(worktree: Path) -> bool:
    """True when any process (Linux /proc) has its working directory inside the worktree."""
    root = str(worktree.resolve())
    proc = Path("/proc")
    if not proc.is_dir():
        return False
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            cwd = os.readlink(entry / "cwd")
        except OSError:
            continue
        if cwd == root or cwd.startswith(root + os.sep):
            return True
    return False


def is_clean(worktree: Path) -> bool:
    result = run_git(worktree, "status", "--porcelain")
    return result.returncode == 0 and result.stdout.strip() == ""


def is_delivered_to_base(repo: Path, head: str, base: str) -> bool:
    if not head:
        return False
    result = run_git(repo, "merge-base", "--is-ancestor", head, f"origin/{base}")
    return result.returncode == 0


def pr_states(repo: Path, branch: str) -> list[str]:
    try:
        result = subprocess.run(
            ["gh", "pr", "list", "--head", branch, "--state", "all",
             "--json", "state", "--limit", "5"],
            capture_output=True,
            text=True,
            cwd=str(repo),
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0:
        return []
    try:
        return [item["state"] for item in json.loads(result.stdout or "[]")]
    except (ValueError, KeyError, TypeError):
        return []


def has_unpushed_commits(worktree: Path, branch: str) -> Optional[bool]:
    """True/False when an upstream exists; None when there is no upstream."""
    upstream = run_git(worktree, "rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}")
    if upstream.returncode != 0:
        return None
    ahead = run_git(worktree, "rev-list", "--count", f"{upstream.stdout.strip()}..HEAD")
    return ahead.returncode != 0 or ahead.stdout.strip() != "0"


def evaluate(repo: Path, entry: WorktreeEntry, base: str, grace_seconds: float,
             now: float) -> Decision:
    path = Path(entry.path)
    branch = entry.branch

    if entry.locked:
        return Decision(entry.path, branch, "kept", "locked")
    if entry.prunable or not path.is_dir():
        return Decision(entry.path, branch, "kept", "missing or prunable (left to git worktree prune)")

    if in_use_by_process(path):
        return Decision(entry.path, branch, "kept", "a running process is inside this worktree")

    git_dir = git_dir_of(path)
    idle = now - last_activity_epoch(path, git_dir)
    if idle < grace_seconds:
        return Decision(entry.path, branch, "kept",
                        "recently active", {"idle_seconds": round(idle)})

    if not is_clean(path):
        return Decision(entry.path, branch, "kept", "uncommitted or untracked changes")

    delivered = is_delivered_to_base(repo, entry.head, base)
    states: list[str] = []
    unpushed: Optional[bool] = None
    if branch:
        states = pr_states(repo, branch)
        unpushed = has_unpushed_commits(path, branch)
    pr_done = any(state in ("MERGED", "CLOSED") for state in states)

    details = {"delivered_to_base": delivered, "pr_states": states, "unpushed": unpushed}

    if not delivered:
        if not (pr_done and unpushed is not True):
            return Decision(entry.path, branch, "kept",
                            "work not delivered (no merged commit and no finished PR)", details)
    elif unpushed is True:
        return Decision(entry.path, branch, "kept", "commits not pushed to upstream", details)

    return Decision(entry.path, branch, "would_remove", "delivered and clean", details)


def remove(repo: Path, decision: Decision) -> Decision:
    result = run_git(repo, "worktree", "remove", decision.path)
    if result.returncode != 0:
        decision.action = "error"
        decision.reason = "git worktree remove refused: " + (result.stderr.strip() or "unknown")
        return decision
    decision.action = "removed"
    return decision


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Remove unused, clean, delivered git worktrees (dry run unless --apply).")
    parser.add_argument("--apply", action="store_true", help="actually remove eligible worktrees")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--base", default=DEFAULT_BASE,
                        help=f"base branch on origin (default: {DEFAULT_BASE})")
    parser.add_argument("--grace-minutes", type=float, default=DEFAULT_GRACE_MINUTES,
                        help=f"skip worktrees active within this many minutes (default: {DEFAULT_GRACE_MINUTES})")
    args = parser.parse_args(argv)

    repo = Path(__file__).resolve().parent.parent
    listing = run_git(repo, "worktree", "list", "--porcelain")
    if listing.returncode != 0:
        print(listing.stderr.strip(), file=sys.stderr)
        return 2

    entries = parse_worktree_list(listing.stdout)
    main_path = entries[0].path if entries else ""
    now = time.time()
    grace = args.grace_minutes * 60

    run_git(repo, "fetch", "--quiet", "origin", args.base)

    decisions: list[Decision] = []
    for entry in entries:
        if entry.path == main_path:
            continue
        decision = evaluate(repo, entry, args.base, grace, now)
        if decision.action == "would_remove" and args.apply:
            decision = remove(repo, decision)
        decisions.append(decision)

    run_git(repo, "worktree", "prune")

    if args.json:
        print(json.dumps({"apply": args.apply, "decisions": [asdict(d) for d in decisions]}, indent=2))
    else:
        mode = "APPLY" if args.apply else "DRY RUN"
        print(f"[{mode}] {len(decisions)} linked worktrees checked")
        for d in decisions:
            print(f"  {d.action:<12} {d.path}  ({d.branch or 'detached'}): {d.reason}")
    return 1 if any(d.action == "error" for d in decisions) else 0


if __name__ == "__main__":
    sys.exit(main())
