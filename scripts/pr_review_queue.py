#!/usr/bin/env python3
"""List the open PRs a reviewer agent should review now (AGENTS.md rule 16).

Reviews run in rounds (.agents/rules/pr-review-rounds.md). Any review the bot
submits (APPROVE, REQUEST_CHANGES or COMMENT) ends a round, and the next one
starts only when the author submits the PR again: "Ready for review" on a draft,
or a review request naming the bot. A PR is *ready for review* when it is not a
draft, its CI checks have all finished, and it has a submission the bot has not
answered. The bot's review history and the PR timeline are the state, so nothing
is stored locally. Reasons a PR needs a review:

    new          the bot never reviewed this PR (opened ready, or a draft marked ready)
    new_head     submitted again after the bot's last review, with new commits
    requested    submitted again after the bot's last review, same commit
    unfinished   the bot's last review of this head was dismissed (with
                 --any-change, also when it is a COMMENT)

`--any-change` ignores submissions: any new head, or a head with no final
verdict, needs a review.

A PR that needs a review but whose checks are still running is reported under
`waiting_ci`, not `ready`: look again next cycle (or `gh pr checks <n> --watch`).

Usage:
    python3 scripts/pr_review_queue.py                 # ready PRs, one per line
    python3 scripts/pr_review_queue.py --json          # ready, waiting_ci, skipped
    python3 scripts/pr_review_queue.py --all           # also show waiting_ci and skipped
    python3 scripts/pr_review_queue.py --skip-author my-login

Exit codes: 0 ok (even when nothing is ready), 2 gh/usage error.
Needs an authenticated `gh` (reading only; reviews are posted via review_bot.py).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any, Callable

BOT_LOGIN = "local-reviewer-agent[bot]"
FINAL_STATES = {"APPROVED", "CHANGES_REQUESTED"}
PENDING_STATUSES = {"QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED"}
PENDING_STATES = {"PENDING", "EXPECTED"}
FAILED_CONCLUSIONS = {"FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR"}

Gh = Callable[[list[str]], str]


class GhError(RuntimeError):
    pass


def run_gh(args: list[str]) -> str:
    try:
        proc = subprocess.run(["gh", *args], capture_output=True, text=True, check=False, timeout=60)
    except FileNotFoundError as exc:
        raise GhError("gh CLI not found") from exc
    except subprocess.TimeoutExpired as exc:
        raise GhError("gh command timed out") from exc
    if proc.returncode != 0:
        raise GhError(f"gh {' '.join(args[:3])} failed: {proc.stderr.strip()[:300]}")
    return proc.stdout


def ci_state(rollup: list[dict[str, Any]] | None) -> str:
    """Summarise statusCheckRollup as none | pending | failed | passed."""
    if not rollup:
        return "none"
    failed = False
    for check in rollup:
        status = (check.get("status") or "").upper()
        state = (check.get("state") or "").upper()
        if status in PENDING_STATUSES or state in PENDING_STATES:
            return "pending"
        conclusion = (check.get("conclusion") or state).upper()
        if conclusion in FAILED_CONCLUSIONS:
            failed = True
    return "failed" if failed else "passed"


def review_reason(head: str, last_review: dict[str, Any] | None) -> str | None:
    """Why the bot still owes a review of `head`, or None when it already gave a verdict."""
    if last_review is None:
        return "new"
    if last_review.get("commit_id") != head:
        return "new_head"
    if last_review.get("state") in FINAL_STATES:
        return None
    return "unfinished"


def round_reason(head: str, last_review: dict[str, Any] | None,
                 submitted_at: str | None) -> tuple[str | None, str]:
    """(why a review is owed, why not) when only an author submission opens a round."""
    if last_review is None or last_review.get("state") == "DISMISSED":
        return review_reason(head, last_review), ""
    same_head = last_review.get("commit_id") == head
    if submitted_at and submitted_at > (last_review.get("submitted_at") or ""):
        return ("requested" if same_head else "new_head"), ""
    return None, ("already_reviewed" if same_head else "not_submitted")


def classify(pr: dict[str, Any], last_review: dict[str, Any] | None, skip_authors: set[str],
             submitted_at: str | None = None, any_change: bool = False) -> dict[str, Any]:
    head = pr.get("headRefOid", "")
    ci = ci_state(pr.get("statusCheckRollup"))
    entry = {
        "number": pr["number"],
        "title": pr.get("title", ""),
        "author": (pr.get("author") or {}).get("login", ""),
        "head": head[:12],
        "ci": ci,
        "last_review": (last_review or {}).get("state"),
        "last_reviewed": ((last_review or {}).get("commit_id") or "")[:12] or None,
    }
    if pr.get("isDraft"):
        return {**entry, "bucket": "skipped", "reason": "draft"}
    if entry["author"] in skip_authors:
        return {**entry, "bucket": "skipped", "reason": "own_pr"}
    if any_change:
        reason, idle = review_reason(head, last_review), "already_reviewed"
    else:
        reason, idle = round_reason(head, last_review, submitted_at)
    if reason is None:
        return {**entry, "bucket": "skipped", "reason": idle,
                "reviewed_at": (last_review or {}).get("submitted_at")}
    if ci == "pending":
        return {**entry, "bucket": "waiting_ci", "reason": reason}
    return {**entry, "bucket": "ready", "reason": reason}


def last_bot_review(gh: Gh, number: int, bot_login: str) -> dict[str, Any] | None:
    jq = f'.[]|select(.user.login=="{bot_login}" and .state!="PENDING")|{{state,commit_id,submitted_at}}'
    out = gh(["api", f"repos/{{owner}}/{{repo}}/pulls/{number}/reviews", "--paginate", "--jq", jq])
    reviews = [json.loads(line) for line in out.splitlines() if line.strip()]
    reviews.sort(key=lambda r: r.get("submitted_at") or "")
    return reviews[-1] if reviews else None


def last_submission(gh: Gh, number: int, bot_login: str) -> str | None:
    """When the author last sent the PR to review: "Ready for review", or a request naming the bot."""
    jq = ('.[]|select(.event=="ready_for_review" or (.event=="review_requested" and '
          f'.requested_reviewer.login=="{bot_login}"))|.created_at')
    out = gh(["api", f"repos/{{owner}}/{{repo}}/issues/{number}/timeline", "--paginate", "--jq", jq])
    return max((line.strip() for line in out.splitlines() if line.strip()), default=None)


def build_queue(gh: Gh, bot_login: str = BOT_LOGIN, skip_authors: set[str] | None = None,
                limit: int = 100, any_change: bool = False) -> dict[str, list[dict[str, Any]]]:
    fields = "number,title,isDraft,headRefOid,author,statusCheckRollup"
    prs = json.loads(gh(["pr", "list", "--state", "open", "--limit", str(limit), "--json", fields]) or "[]")
    queue: dict[str, list[dict[str, Any]]] = {"ready": [], "waiting_ci": [], "skipped": []}
    for pr in prs:
        # Drafts are skipped without a review lookup.
        review = None if pr.get("isDraft") else last_bot_review(gh, pr["number"], bot_login)
        # The timeline is read only when an earlier review makes the submission time matter.
        submitted = None if review is None or any_change else last_submission(gh, pr["number"], bot_login)
        entry = classify(pr, review, skip_authors or set(), submitted, any_change)
        queue[entry.pop("bucket")].append(entry)
    return queue


def format_text(queue: dict[str, list[dict[str, Any]]], show_all: bool) -> str:
    lines = [f"#{e['number']}\t{e['reason']}\tci={e['ci']}\t{e['head']}\t{e['title'][:70]}" for e in queue["ready"]]
    if show_all:
        lines += [f"#{e['number']}\twaiting_ci({e['reason']})\t{e['head']}\t{e['title'][:70]}" for e in queue["waiting_ci"]]
        lines += [f"#{e['number']}\tskip:{e['reason']}" for e in queue["skipped"]]
    return "\n".join(lines) if lines else "nothing to review"


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--json", action="store_true", help="machine-readable output (all buckets)")
    p.add_argument("--all", action="store_true", help="also list waiting_ci and skipped PRs in text mode")
    p.add_argument("--bot-login", default=BOT_LOGIN, help=f"reviewer login (default {BOT_LOGIN})")
    p.add_argument("--skip-author", action="append", default=[], metavar="LOGIN", help="skip PRs by this author (repeatable)")
    p.add_argument("--limit", type=int, default=100, help="max open PRs to inspect")
    p.add_argument("--any-change", action="store_true",
                   help="review every new head, without waiting for the author to submit it")
    return p.parse_args(argv)


def main(argv: list[str] | None = None, gh: Gh = run_gh) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        queue = build_queue(gh, args.bot_login, set(args.skip_author), args.limit, args.any_change)
    except (GhError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(queue, indent=2) if args.json else format_text(queue, args.all))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
