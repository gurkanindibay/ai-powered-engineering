#!/usr/bin/env python3
"""Claim issues (and PRs) so different agent harnesses can identify each other.

A claim is three GitHub labels applied together:

    in progress            the work is taken (AGENTS.md rule 10)
    harness:<name>         which harness owns it: codex, claude, antigravity, ...
    session:<id>           the harness's own session identifier

Any agent can read the labels to see who is working on an issue and, with the
session id, find that session. `claim` refuses an issue another session owns
(including legacy bare `in progress` issues with no owner) unless `--force`.

Usage:
    python3 scripts/issue_claim.py claim 123 --harness claude --session <id>
    python3 scripts/issue_claim.py status 123 [--json]
    python3 scripts/issue_claim.py release 123 --harness claude --session <id>
    python3 scripts/issue_claim.py claim 123 --harness codex     # session from
                                                                  # $AGENT_SESSION_ID or generated

Session id resolution: --session, then $AGENT_SESSION_ID, then the harness
variable ($CLAUDE_SESSION_ID, $CODEX_SESSION_ID, $ANTIGRAVITY_SESSION_ID),
then a generated id that is printed so it can be reused for `release`.

Exit codes: 0 ok, 1 claim refused (owned by someone else), 2 usage/gh error.
Uses the REST API: `gh issue edit --add-label` fails on the classic-Projects
GraphQL error in this repository.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import uuid
from dataclasses import asdict, dataclass
from typing import Callable

IN_PROGRESS = "in progress"
HARNESS_PREFIX = "harness:"
SESSION_PREFIX = "session:"
KNOWN_HARNESSES = ("codex", "claude", "antigravity")
LABEL_COLORS = {IN_PROGRESS: "fbca04", HARNESS_PREFIX: "5319e7", SESSION_PREFIX: "c5def5"}
MAX_LABEL = 50  # GitHub label name limit
_SLUG = re.compile(r"[^a-z0-9._-]+")

Runner = Callable[[list[str]], str]


class ClaimError(Exception):
    """Usage or gh failure (exit 2)."""


@dataclass
class Owner:
    in_progress: bool
    harness: str | None
    session: str | None

    @property
    def owned(self) -> bool:
        return self.harness is not None and self.session is not None


def slug(value: str) -> str:
    return _SLUG.sub("-", value.strip().lower()).strip("-")


def resolve_session(harness: str, explicit: str | None, env: dict[str, str]) -> str:
    candidates = [explicit, env.get("AGENT_SESSION_ID"), env.get(f"{harness.upper()}_SESSION_ID")]
    value = next((c for c in candidates if c and c.strip()), None)
    session = slug(value) if value else uuid.uuid4().hex[:12]
    session = session[: MAX_LABEL - len(SESSION_PREFIX)]
    if not session:
        raise ClaimError("session id is empty after normalisation")
    return session


def parse_owner(labels: list[str]) -> Owner:
    harness = next((l[len(HARNESS_PREFIX):] for l in labels if l.startswith(HARNESS_PREFIX)), None)
    session = next((l[len(SESSION_PREFIX):] for l in labels if l.startswith(SESSION_PREFIX)), None)
    return Owner(IN_PROGRESS in labels, harness, session)


def gh(args: list[str]) -> str:
    try:
        done = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        raise ClaimError("gh CLI not found") from exc
    if done.returncode != 0:
        raise ClaimError(f"gh {' '.join(args[:3])} failed: {done.stderr.strip()[:300]}")
    return done.stdout


def repo_slug(run: Runner) -> str:
    return run(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()


def read_labels(run: Runner, repo: str, number: int) -> list[str]:
    out = run(["api", f"repos/{repo}/issues/{number}", "--jq", "[.labels[].name]"])
    return json.loads(out or "[]")


def ensure_label(run: Runner, repo: str, name: str) -> None:
    color = LABEL_COLORS.get(IN_PROGRESS if name == IN_PROGRESS else name.split(":")[0] + ":", "ededed")
    try:
        run(["api", "-X", "POST", f"repos/{repo}/labels", "-f", f"name={name}", "-f", f"color={color}"])
    except ClaimError as exc:
        if "already_exists" not in str(exc) and "422" not in str(exc):
            raise


def add_labels(run: Runner, repo: str, number: int, names: list[str]) -> None:
    for name in names:
        ensure_label(run, repo, name)
    args = ["api", "-X", "POST", f"repos/{repo}/issues/{number}/labels"]
    for name in names:
        args += ["-f", f"labels[]={name}"]
    run(args)


def remove_label(run: Runner, repo: str, number: int, name: str) -> None:
    quoted = name.replace(" ", "%20")
    try:
        run(["api", "-X", "DELETE", f"repos/{repo}/issues/{number}/labels/{quoted}"])
    except ClaimError as exc:
        if "404" not in str(exc):
            raise


def claim(run: Runner, repo: str, number: int, harness: str, session: str, force: bool) -> tuple[bool, str]:
    labels = read_labels(run, repo, number)
    owner = parse_owner(labels)
    mine = owner.harness == harness and owner.session == session
    if owner.in_progress and not mine and not force:
        who = f"{owner.harness}/{owner.session}" if owner.owned else "an unidentified agent (bare `in progress`)"
        return False, f"#{number} is already in progress, owned by {who}; pick another issue"
    stale = [l for l in labels if (l.startswith(HARNESS_PREFIX) or l.startswith(SESSION_PREFIX))]
    wanted = [IN_PROGRESS, f"{HARNESS_PREFIX}{harness}", f"{SESSION_PREFIX}{session}"]
    for label in stale:
        if label not in wanted:
            remove_label(run, repo, number, label)
    add_labels(run, repo, number, [l for l in wanted if l not in labels])
    # Re-read to detect a concurrent claim that landed between read and write.
    sessions = [l for l in read_labels(run, repo, number) if l.startswith(SESSION_PREFIX)]
    if len(sessions) > 1 and not force:
        remove_label(run, repo, number, f"{SESSION_PREFIX}{session}")
        remove_label(run, repo, number, f"{HARNESS_PREFIX}{harness}")
        return False, f"#{number} was claimed concurrently by another session; backed off"
    return True, f"#{number} claimed by {harness}/{session}"


def release(run: Runner, repo: str, number: int, harness: str, session: str, force: bool) -> tuple[bool, str]:
    owner = parse_owner(read_labels(run, repo, number))
    if owner.in_progress and not force and not (owner.harness == harness and owner.session == session):
        return False, f"#{number} is owned by {owner.harness}/{owner.session}, not {harness}/{session}"
    for label in (IN_PROGRESS, f"{HARNESS_PREFIX}{owner.harness}", f"{SESSION_PREFIX}{owner.session}"):
        if label.endswith(":None"):
            continue
        remove_label(run, repo, number, label)
    return True, f"#{number} released"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("action", choices=["claim", "status", "release"])
    parser.add_argument("number", type=int, help="issue or PR number")
    parser.add_argument("--harness", help=f"harness name, e.g. {', '.join(KNOWN_HARNESSES)}")
    parser.add_argument("--session", help="harness session id (default: env or generated)")
    parser.add_argument("--repo", help="owner/name (default: current repo)")
    parser.add_argument("--force", action="store_true", help="take over / release another owner's claim")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    return parser


def main(argv: list[str] | None = None, run: Runner = gh, env: dict[str, str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    env = dict(os.environ) if env is None else env
    try:
        repo = args.repo or repo_slug(run)
        if args.action == "status":
            owner = parse_owner(read_labels(run, repo, args.number))
            payload = {"issue": args.number, **asdict(owner), "owned": owner.owned}
            print(json.dumps(payload) if args.json else
                  f"#{args.number}: in_progress={owner.in_progress} harness={owner.harness} session={owner.session}")
            return 0
        if not args.harness:
            raise ClaimError("--harness is required for claim/release")
        harness = slug(args.harness)
        session = resolve_session(harness, args.session, env)
        fn = claim if args.action == "claim" else release
        ok, message = fn(run, repo, args.number, harness, session, args.force)
        payload = {"ok": ok, "message": message, "harness": harness, "session": session}
        print(json.dumps(payload) if args.json else f"{message} (session id: {session})")
        return 0 if ok else 1
    except ClaimError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}) if args.json else f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
