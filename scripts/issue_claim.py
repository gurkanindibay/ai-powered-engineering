#!/usr/bin/env python3
"""Claim issues (and PRs) so different agent harnesses can identify each other.

A claim is three GitHub labels applied together:

    in progress            the work is taken (AGENTS.md rule 10)
    agent:<name>           readable agent name from scripts/agent_names.py,
                           bound to the model (e.g. agent:Alparslan = Sonnet)
    claim:<harness>/<id>   owner: harness (codex, claude, antigravity, ...) and
                           its session id in ONE label, so they can't drift apart

Any agent can read the labels to see who is working on an issue and, with the
session id, find that session. `claim` refuses an issue another session owns
(including legacy bare `in progress` issues with no owner) unless `--force`.

Usage:
    python3 scripts/issue_claim.py claim 123 --harness claude --session <id> --model <model-id>
    python3 scripts/issue_claim.py sync 123 --pr 130      # copy the issue's labels to its PR
    python3 scripts/issue_claim.py status 123 [--json]
    python3 scripts/issue_claim.py release 123 --harness claude --session <id>
    python3 scripts/issue_claim.py claim 123 --harness codex --model gpt-6.2-sol
                                                  # session from $AGENT_SESSION_ID or generated

`claim` needs the model (--model or $AGENT_MODEL). It prints the agent's name
and a session title starting with `[<name>]`; use it as the harness session
title. `release` frees the name.

The PR that delivers an issue carries the same labels, so the PR shows its
owner too: `sync <issue> --pr <pr>` copies them (run it when the PR is opened),
`claim ... --pr <pr>` claims and syncs in one step, and `release ... --pr <pr>`
removes the claim from both. A PR already owned by another session is refused.

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
import time
import urllib.parse
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

import agent_names

IN_PROGRESS = "in progress"
CLAIM_PREFIX = "claim:"
KNOWN_HARNESSES = ("codex", "claude", "antigravity")
AGENT_PREFIX = agent_names.LABEL_PREFIX
AGENT_COLOR = "0e8a16"
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
        msg = f"{done.stderr.strip()} {done.stdout.strip()}".strip()
        raise ClaimError(f"gh {' '.join(args[:3])} failed: {msg[:300]}")
    return done.stdout


def repo_slug(run: Runner) -> str:
    return run(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()


def read_labels(run: Runner, repo: str, number: int) -> list[str]:
    out = run(["api", f"repos/{repo}/issues/{number}", "--jq", "[.labels[].name]"])
    return json.loads(out or "[]")


def ensure_label(run: Runner, repo: str, name: str) -> None:
    color = AGENT_COLOR if name.startswith(AGENT_PREFIX) else LABEL_COLORS[
        IN_PROGRESS if name == IN_PROGRESS else CLAIM_PREFIX]
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
    quoted = urllib.parse.quote(name, safe="")  # `/` and `:` must not split the path
    try:
        run(["api", "-X", "DELETE", f"repos/{repo}/issues/{number}/labels/{quoted}"])
    except ClaimError as exc:
        if "404" not in str(exc):
            raise


EVENT_RETRIES = 5
EVENT_RETRY_SECONDS = 1.0


def claim_order(run: Runner, repo: str, number: int, labels: list[str], own: str) -> list[str]:
    """Claim labels still on the issue, oldest first by GitHub's own event order.

    The server assigns `labeled` event ids in the order the writes landed, so
    every session that re-reads after its own write agrees on who was first.
    The events API can lag a label write by a few seconds, so retry until our
    own `labeled` event is listed; only then is the order trustworthy.
    """
    order: list[str] = []
    for attempt in range(EVENT_RETRIES):
        out = run(["api", "--paginate", f"repos/{repo}/issues/{number}/events",
                   "--jq", r'.[] | select(.event=="labeled") | "\(.id) \(.label.name)"'])
        order = []
        for line in sorted((l for l in out.splitlines() if l.strip()), key=lambda l: int(l.split(" ", 1)[0])):
            name = line.split(" ", 1)[1]
            if name.startswith(CLAIM_PREFIX) and name in labels and name not in order:
                order.append(name)
        if own in order:
            return order
        if attempt < EVENT_RETRIES - 1:
            time.sleep(EVENT_RETRY_SECONDS)
    # Our event never showed up: do not guess an order that could disagree
    # with the other session's. If anyone else holds a claim label, treat
    # ours as lost (safe: we back off); if nobody does, we are the only claimer.
    others = sorted(l for l in labels if l.startswith(CLAIM_PREFIX) and l != own)
    return others + [own]


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
    first = claim_order(run, repo, number, current, mine_label)[0]
    if first != mine_label:
        remove_label(run, repo, number, mine_label)
        drop_unused_claim_label(run, repo, mine_label)
        return False, f"#{number} was claimed first by {first[len(CLAIM_PREFIX):]}; backed off"
    return True, f"#{number} claimed by {harness}/{session}"


def names_used_by_others(run: Runner, repo: str, own: str) -> set[str]:
    """Agent names on open in-progress issues/PRs owned by another session: the
    only view of agents that do not share this machine's reservation file."""
    out = run(["api", "--paginate",
               f"repos/{repo}/issues?state=open&per_page=100&labels={urllib.parse.quote(IN_PROGRESS)}",
               "--jq", ".[] | [.labels[].name] | @json"])
    taken: set[str] = set()
    for line in filter(str.strip, out.splitlines()):
        labels = json.loads(line)
        if own not in labels:
            taken.update(l[len(AGENT_PREFIX):] for l in labels if l.startswith(AGENT_PREFIX))
    return taken


def assign_name(run: Runner, repo: str, number: int, harness: str, session: str, model: str,
                state: Path) -> str:
    """Reserve the agent's name, label the issue with it, return the session title."""
    entry = agent_names.reserve(state, harness, session, model, issue=number,
                                taken_elsewhere=names_used_by_others(run, repo, claim_label(harness, session)))
    wanted = agent_names.label_for(entry["name"])
    labels = read_labels(run, repo, number)
    for label in labels:
        if label.startswith(AGENT_PREFIX) and label != wanted:
            remove_label(run, repo, number, label)
    if wanted not in labels:
        add_labels(run, repo, number, [wanted])
    title = run(["api", f"repos/{repo}/issues/{number}", "--jq", ".title"]).strip()
    return agent_names.session_title(entry["name"], number, title)


def drop_unused_claim_label(run: Runner, repo: str, label: str) -> None:
    """Delete a repo-level claim label once no issue or PR carries it."""
    if not label.startswith(CLAIM_PREFIX):
        return
    quoted = urllib.parse.quote(label, safe="")
    users = run(["api", f"repos/{repo}/issues?state=all&per_page=1&labels={quoted}", "--jq", "length"]).strip()
    if users == "0":
        try:
            run(["api", "-X", "DELETE", f"repos/{repo}/labels/{quoted}"])
        except ClaimError as exc:
            if "404" not in str(exc):
                raise


def sync_pr(run: Runner, repo: str, issue: int, pr: int, force: bool = False) -> tuple[bool, str]:
    """Copy the issue's `in progress`, owner and agent-name labels to the PR that delivers it."""
    issue_labels = read_labels(run, repo, issue)
    claims = [f"{CLAIM_PREFIX}{h}/{s}" for h, s in claims_in(issue_labels)]
    if not claims:
        return False, f"#{issue} has no claim label to copy; claim it first"
    pr_labels = read_labels(run, repo, pr)
    foreign = [c for c in claims_in(pr_labels) if f"{CLAIM_PREFIX}{c[0]}/{c[1]}" not in claims]
    if foreign and not force:
        return False, f"PR #{pr} is already owned by {foreign[0][0]}/{foreign[0][1]}; not overwriting"
    for harness, session in foreign:
        remove_label(run, repo, pr, f"{CLAIM_PREFIX}{harness}/{session}")
        drop_unused_claim_label(run, repo, f"{CLAIM_PREFIX}{harness}/{session}")
    names = [l for l in issue_labels if l.startswith(AGENT_PREFIX)]
    if names:
        for label in pr_labels:
            if label.startswith(AGENT_PREFIX) and label not in names:
                remove_label(run, repo, pr, label)
    missing = [l for l in (IN_PROGRESS, *claims, *names) if l not in pr_labels]
    if missing:
        add_labels(run, repo, pr, missing)
    return True, f"PR #{pr} labeled like #{issue} ({', '.join(claims)})"


def release(run: Runner, repo: str, number: int, harness: str, session: str, force: bool,
            pr: int | None = None) -> tuple[bool, str]:
    labels = read_labels(run, repo, number)
    owner = parse_owner(labels)
    if owner.in_progress and not force and not (owner.harness == harness and owner.session == session):
        return False, f"#{number} is owned by {owner.harness}/{owner.session}, not {harness}/{session}"
    pr_labels = read_labels(run, repo, pr) if pr is not None else []
    owned_prefixes = (CLAIM_PREFIX, AGENT_PREFIX)
    for label in dict.fromkeys([IN_PROGRESS, *(l for l in labels + pr_labels if l.startswith(owned_prefixes))]):
        if pr is not None:
            remove_label(run, repo, pr, label)  # PR first: the repo label is dropped once unused
        remove_label(run, repo, number, label)
        drop_unused_claim_label(run, repo, label)
    return True, f"#{number} released" + (f" (and PR #{pr})" if pr is not None else "")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("action", choices=["claim", "status", "release", "sync"])
    parser.add_argument("number", type=int, help="issue or PR number")
    parser.add_argument("--harness", help=f"harness name, e.g. {', '.join(KNOWN_HARNESSES)}")
    parser.add_argument("--session", help="harness session id (default: env or generated)")
    parser.add_argument("--model", help="model id, e.g. claude-sonnet-5-5; picks the agent name (claim; default: $AGENT_MODEL)")
    parser.add_argument("--pr", type=int, help="PR delivering the issue: labeled like the issue (claim/sync) or cleared (release)")
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
        if args.action == "sync":
            if args.pr is None:
                raise ClaimError("--pr is required for sync")
            ok, message = sync_pr(run, repo, args.number, args.pr, args.force)
            print(json.dumps({"ok": ok, "message": message}) if args.json else message)
            return 0 if ok else 1
        if not args.harness:
            raise ClaimError("--harness is required for claim/release")
        harness = slug(args.harness)
        session = resolve_session(harness, args.session, env)
        extra: dict[str, str] = {}
        if args.action == "release":
            owners = claims_in(read_labels(run, repo, args.number)) or [(harness, session)]
            ok, message = release(run, repo, args.number, harness, session, args.force, args.pr)
            if ok:
                state = agent_names.default_state_path(env)
                for owner_harness, owner_session in owners:
                    agent_names.release(state, owner_harness, owner_session, issue=args.number)
        else:
            model = args.model or env.get("AGENT_MODEL")
            if not model:
                raise ClaimError("--model (or $AGENT_MODEL) is required for claim: it picks your agent name")
            state = agent_names.default_state_path(env)
            agent_names.read_state(state)  # fail before touching GitHub if the file is broken
            previous = claims_in(read_labels(run, repo, args.number)) if args.force else []
            ok, message = claim(run, repo, args.number, harness, session, args.force)
            if ok:
                for owner_harness, owner_session in previous:
                    if (owner_harness, owner_session) != (harness, session):
                        agent_names.release(state, owner_harness, owner_session, issue=args.number)
                title = assign_name(run, repo, args.number, harness, session, model, state)
                extra = {"agent": title[1:title.index("]")], "session_title": title}
                message = f"{message} as {extra['agent']}"
            if ok and args.pr is not None:
                ok, pr_message = sync_pr(run, repo, args.number, args.pr, args.force)
                message = f"{message}; {pr_message}"
        payload = {"ok": ok, "message": message, "harness": harness, "session": session, **extra}
        text = f"{message} (session id: {session})"
        if extra:
            text += f"\nset your harness session title to: {extra['session_title']}"
        print(json.dumps(payload) if args.json else text)
        return 0 if ok else 1
    except (ClaimError, agent_names.RosterError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}) if args.json else f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
