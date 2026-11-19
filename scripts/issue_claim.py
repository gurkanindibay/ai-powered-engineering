#!/usr/bin/env python3
"""Claim issues (and PRs) so different agent harnesses can identify each other.

A claim is two GitHub labels applied together:

    in progress            the work is taken (AGENTS.md rule 10)
    claim:<harness>/<id>   owner: harness (codex, claude, antigravity, ...) and
                           its session id in ONE label, so they can't drift apart

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
then a generated id that is printed. Keep it: `release` needs the same id
(the harness variables may not be set by every harness).

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
CLAIM_PREFIX = "claim:"
KNOWN_HARNESSES = ("codex", "claude", "antigravity")
LABEL_COLORS = {IN_PROGRESS: "fbca04", CLAIM_PREFIX: "5319e7"}
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
    session = session[: MAX_LABEL - len(CLAIM_PREFIX) - len(harness) - 1].strip("-")
    if not session:
        raise ClaimError("session id is empty after normalisation")
    return session


def claim_label(harness: str, session: str) -> str:
    return f"{CLAIM_PREFIX}{harness}/{session}"


def claims_in(labels: list[str]) -> list[tuple[str, str]]:
    found = []
    for label in sorted(labels):
        if label.startswith(CLAIM_PREFIX) and "/" in label:
            harness, session = label[len(CLAIM_PREFIX):].split("/", 1)
            found.append((harness, session))
    return found


def parse_owner(labels: list[str]) -> Owner:
    """The owner is encoded in ONE label, `claim:<harness>/<session>`, so a
    harness and its session can never be separated or mismatched."""
    claims = claims_in(labels)
    harness, session = claims[0] if claims else (None, None)
    return Owner(IN_PROGRESS in labels or bool(claims), harness, session)


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
    color = LABEL_COLORS.get(IN_PROGRESS if name == IN_PROGRESS else CLAIM_PREFIX, "ededed")
    try:
        run(["api", "-X", "POST", f"repos/{repo}/labels", "-f", f"name={name}", "-f", f"color={color}"])
    except ClaimError as exc:
        if "already_exists" not in str(exc):
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


def claim_order(run: Runner, repo: str, number: int, labels: list[str]) -> list[str]:
    """Claim labels still on the issue, oldest first by GitHub's own event order.

    The server assigns `labeled` event ids in the order the writes landed, so
    every session that re-reads after its own write agrees on who was first.
    """
    out = run(["api", "--paginate", f"repos/{repo}/issues/{number}/events",
               "--jq", r'.[] | select(.event=="labeled") | "\(.id) \(.label.name)"'])
    order: list[str] = []
    for line in sorted((l for l in out.splitlines() if l.strip()), key=lambda l: int(l.split(" ", 1)[0])):
        name = line.split(" ", 1)[1]
        if name.startswith(CLAIM_PREFIX) and name in labels and name not in order:
            order.append(name)
    return order or [l for l in sorted(labels) if l.startswith(CLAIM_PREFIX)]


def claim(run: Runner, repo: str, number: int, harness: str, session: str, force: bool) -> tuple[bool, str]:
    labels = read_labels(run, repo, number)
    owner = parse_owner(labels)
    mine_label = claim_label(harness, session)
    mine = owner.harness == harness and owner.session == session
    if owner.in_progress and not mine and not force:
        who = f"{owner.harness}/{owner.session}" if owner.owned else "an unidentified agent (bare `in progress`)"
        return False, f"#{number} is already in progress, owned by {who}; pick another issue"
    if force:
        for label in labels:
            if label.startswith(CLAIM_PREFIX) and label != mine_label:
                remove_label(run, repo, number, label)
                drop_unused_claim_label(run, repo, label)
    add_labels(run, repo, number, [l for l in (IN_PROGRESS, mine_label) if l not in labels])
    if force:
        return True, f"#{number} claimed by {harness}/{session}"
    # Concurrent claims: the earliest claim label by server event order wins.
    # A loser removes only its own claim label; `in progress` stays for the winner.
    current = read_labels(run, repo, number)
    first = claim_order(run, repo, number, current)[0]
    if first != mine_label:
        remove_label(run, repo, number, mine_label)
        drop_unused_claim_label(run, repo, mine_label)
        return False, f"#{number} was claimed first by {first[len(CLAIM_PREFIX):]}; backed off"
    return True, f"#{number} claimed by {harness}/{session}"


def drop_unused_claim_label(run: Runner, repo: str, label: str) -> None:
    """Delete a repo-level claim label once no issue or PR carries it."""
    if not label.startswith(CLAIM_PREFIX):
        return
    quoted = label.replace(":", "%3A").replace("/", "%2F")
    users = run(["api", f"repos/{repo}/issues?state=all&per_page=1&labels={quoted}", "--jq", "length"]).strip()
    if users == "0":
        try:
            run(["api", "-X", "DELETE", f"repos/{repo}/labels/{quoted}"])
        except ClaimError as exc:
            if "404" not in str(exc):
                raise


def release(run: Runner, repo: str, number: int, harness: str, session: str, force: bool) -> tuple[bool, str]:
    labels = read_labels(run, repo, number)
    owner = parse_owner(labels)
    if owner.in_progress and not force and not (owner.harness == harness and owner.session == session):
        return False, f"#{number} is owned by {owner.harness}/{owner.session}, not {harness}/{session}"
    for label in [IN_PROGRESS, *(l for l in labels if l.startswith(CLAIM_PREFIX))]:
        remove_label(run, repo, number, label)
        drop_unused_claim_label(run, repo, label)
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
