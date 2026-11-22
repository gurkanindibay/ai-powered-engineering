"""Read GitHub PR activity and produce compact, stable acknowledgement cursors."""

from __future__ import annotations

import hashlib
import json
from typing import Any

from pr_review_queue import Gh, ci_state

Activity = dict[str, Any]
PR_FIELDS = "number,state,isDraft,headRefOid,author,mergeable,reviewDecision,statusCheckRollup"
ENDPOINTS = {
    "conversation": "issues/{number}/comments",
    "inline": "pulls/{number}/comments",
    "review": "pulls/{number}/reviews",
}
ACTIVITY_FIELDS = (
    '.[] | select(.state != "PENDING") | '
    '{id, author: .user.login, url: .html_url, state, '
    'at: (.updated_at // .submitted_at // .created_at), '
    'body, commit: .commit_id}'
)


def read_activity(gh: Gh, number: int, skip_login: str, since: str | None = None,
                  *, include_reviews: bool = True) -> list[Activity]:
    activity = []
    for kind, endpoint in ENDPOINTS.items():
        if kind == "review" and not include_reviews:
            continue
        path = "repos/{owner}/{repo}/" + endpoint.format(number=number)
        output = gh(["api", path, "--paginate", "--jq", ACTIVITY_FIELDS])
        for line in filter(str.strip, output.splitlines()):
            item = json.loads(line)
            author, at = item["author"], item["at"]
            if not author or author.casefold() == skip_login.casefold() or not at:
                continue
            if since is not None and at < since:
                continue
            version = json.dumps([kind, item], sort_keys=True)
            cursor = hashlib.sha256(version.encode()).hexdigest()
            activity.append({
                "kind": kind, "id": item["id"], "author": author, "at": at,
                "url": item["url"], "state": item["state"], "commit": item["commit"],
                "cursor": cursor,
            })
    return sorted(activity, key=lambda item: (item["at"], item["kind"], item["id"]))


def author_snapshot(gh: Gh, repo: str, number: int) -> Activity:
    pr = json.loads(gh(["pr", "view", str(number), "--json", PR_FIELDS]))
    author = (pr.get("author") or {}).get("login")
    if not author:
        raise ValueError(f"PR #{number} has no GitHub author login")
    activity = read_activity(gh, number, author) if pr["state"] == "OPEN" else []
    return {
        "repo": repo, "number": number, "state": pr["state"], "head": pr["headRefOid"],
        "draft": pr["isDraft"], "mergeable": pr["mergeable"],
        "review_decision": pr["reviewDecision"], "ci": ci_state(pr["statusCheckRollup"]),
        "activity": activity,
    }


def author_changes(snapshot: Activity, previous: Activity) -> Activity | None:
    changed = [
        key for key in snapshot
        if key not in {"repo", "number", "activity", "mergeable"} and snapshot[key] != previous[key]
        and (key != "ci" or snapshot[key] != "pending")
    ]
    mergeable, prior_mergeable = snapshot["mergeable"], previous["mergeable"]
    # GitHub briefly reports UNKNOWN while it recomputes mergeability.
    if (mergeable == "CONFLICTING" and prior_mergeable != "CONFLICTING"
            or mergeable == "MERGEABLE" and prior_mergeable == "CONFLICTING"):
        changed.append("mergeable")
    prior = {item["cursor"] for item in previous["activity"]}
    activity = [item for item in snapshot["activity"] if item["cursor"] not in prior]
    if not changed and not activity:
        return None
    return {"snapshot": snapshot, "changed": changed, "activity": activity}
