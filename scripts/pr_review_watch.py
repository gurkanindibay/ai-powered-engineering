#!/usr/bin/env python3
"""Wait for actionable GitHub pull request activity and exit (AGENTS.md rules 15–16).

Event-driven companion to pr_review_queue.py. The reviewer agent runs it as a
background command (or with its harness's monitor tool) and is woken only when
the review queue has something new, instead of re-checking on a model timer.

Event sources (``--source``):

    webhook   ``gh webhook forward`` (the ``cli/gh-webhook`` extension) relays the
              repository's pull request, review, comment and CI events to a local HTTP listener on 127.0.0.1. Each
              event only triggers a queue recheck through the GitHub API, so the
              payload is never trusted. Needs admin rights on the repository.
    poll      a quiet ``gh`` check every ``--interval`` seconds. Review lookups
              run only when the open-PR list (heads, drafts, CI state, update times) changed.
    auto      webhook when the extension is installed, else poll (default). A
              webhook forwarder that fails or dies falls back to poll.

Only a poll tick uses the cheap path (review lookups skipped while the PR list
is unchanged). A webhook event, which may be a review or a dismissal, always
refreshes the review history. Whatever the source, a full safety refresh runs
every ``--recheck`` seconds on its own deadline, so a lost event or a
review-only change delays a review but never loses it.

Right after a push GitHub briefly reports no checks for the new head. Such a
head is held for ``--ci-grace`` seconds (default 300) and counts as ready only if
no check shows up by then (a PR that really runs no CI).

A PR is ready only when the author has sent it since the bot's last review (see
pr_review_queue.py and .agents/rules/pr-review-rounds.md). Pushes and comments
between rounds do not wake the reviewer; ``--any-change`` makes them do so.

A ready PR that you have already handled for this head (for example one you
left with a COMMENT because CI is red) can be ignored with ``--seen N@SHA``. The
suppression is tied to the CI state: ``N@SHA:failed`` pins it (preferred: pass
the state from the wake-up you handled), and a bare ``N@SHA`` takes the state the
watcher first sees for that head, or ``absent`` if the PR is not ready then (for
example a rerun is still pending), so its next appearance wakes you. The watcher
wakes again when that PR gets a new head *or* its CI state changes (for example
a rerun on the same commit that turns red into green).

``--repo owner/name`` scopes everything (listener, PR listing, review history)
to that repository; by default the current checkout's repository is used.

Usage:
    python3 scripts/pr_review_watch.py                      # wait, print ready PRs, exit 0
    python3 scripts/pr_review_watch.py --json               # same, as JSON
    python3 scripts/pr_review_watch.py --source poll --interval 60
    python3 scripts/pr_review_watch.py --seen 257@ab12cd34ef56 --timeout 3600

Exit codes: 0 actionable activity found, 2 gh/usage error, 3 --timeout reached.
Needs an authenticated `gh` (reading only; reviews are posted via review_bot.py).
"""

from __future__ import annotations

import argparse
import json
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_review_activity as activity_tool  # noqa: E402
import pr_review_queue as queue_tool  # noqa: E402

EVENTS = (
    "pull_request,pull_request_review,pull_request_review_comment,issue_comment,"
    "check_run,check_suite,status,workflow_run"
)
EXIT_READY, EXIT_ERROR, EXIT_TIMEOUT = 0, 2, 3

Gh = queue_tool.Gh
Entry = dict[str, Any]
# What woke a trigger: a poll tick (cheap recheck), an event (full refresh) or the timeout.
TICK, EVENT, TIMEOUT = "tick", "event", "timeout"
# wait(timeout_seconds) -> TICK | EVENT | TIMEOUT
Trigger = Callable[[float], str]
CI_STATES = {"none", "pending", "failed", "passed"}
# (number, head[:12]) -> CI state the suppression applies to; None = take the first one seen.
Seen = dict[tuple[int, str], "str | None"]


def parse_seen(values: list[str]) -> Seen:
    seen: Seen = {}
    for value in values:
        number, sep, rest = value.partition("@")
        head, _, ci = rest.partition(":")
        if (not sep or not number.lstrip("#").isdigit() or len(head) < 7
                or (ci and ci not in CI_STATES)):
            raise ValueError(f"--seen expects N@SHA (7+ hex chars) or N@SHA:<{'|'.join(sorted(CI_STATES))}>, got {value!r}")
        seen[(int(number.lstrip("#")), head[:12])] = ci or None
    return seen


def unseen(ready: list[Entry], seen: Seen) -> list[Entry]:
    """Drop PRs suppressed by --seen while their head *and* CI state are unchanged.
    SHAs match by prefix, so `264@5a9f4328` and the queue's 12-char head agree."""
    out = []
    for e in ready:
        key = seen_key(seen, e)
        if key is None or e["reason"] == "feedback":
            out.append(e)
            continue
        if seen[key] is None:
            seen[key] = e.get("ci")  # bind to the first state observed
        if seen[key] != e.get("ci"):
            out.append(e)
    return out


def seen_key(seen: Seen, e: Entry) -> tuple[int, str] | None:
    head = e["head"][:12]
    return next((k for k in seen if k[0] == e["number"] and (head.startswith(k[1]) or k[1].startswith(head))), None)


def bind_absent(seen: Seen, ready: list[Entry]) -> None:
    """At the first check, a bare --seen PR that is not ready (for example its CI rerun is
    still pending) binds to "absent", so its later appearance in any state wakes the reviewer."""
    present = {seen_key(seen, e) for e in ready if e["reason"] != "feedback"}
    for key, state in seen.items():
        if state is None and key not in present:
            seen[key] = "absent"


def scoped_gh(gh: Gh, repo: str) -> Gh:
    """Point every queue read at `repo`: `gh pr ...` gets --repo, API paths get the slug."""
    def run(args: list[str]) -> str:
        if args and args[0] == "pr":
            return gh([*args, "--repo", repo])
        if args and args[0] == "api":
            return gh([a.replace("repos/{owner}/{repo}/", f"repos/{repo}/") for a in args])
        return gh(args)
    return run


class QueueCheck:
    """Recompute the ready list, skipping review lookups while the PR list is unchanged."""

    def __init__(self, gh: Gh, bot_login: str, skip_authors: set[str], limit: int,
                 seen_activity: set[str] | None = None, any_change: bool = False) -> None:
        self.any_change = any_change
        self.seen_activity = seen_activity or set()
        self.gh, self.bot_login, self.skip_authors, self.limit = gh, bot_login, skip_authors, limit
        self._fingerprint: dict[int, tuple[str, bool, str, str | None]] | None = None
        self._feedback: dict[int, tuple[str, str, str | None, list[Entry]]] = {}
        self._ready: list[Entry] = []

    def fingerprint(self) -> dict[int, tuple[str, bool, str, str | None]]:
        fields = "number,isDraft,headRefOid,updatedAt,statusCheckRollup"
        prs = json.loads(self.gh(["pr", "list", "--state", "open", "--limit", str(self.limit),
                                  "--json", fields]) or "[]")
        return {
            pr["number"]: (pr.get("headRefOid", ""), bool(pr.get("isDraft")),
                           queue_tool.ci_state(pr.get("statusCheckRollup")), pr.get("updatedAt"))
            for pr in prs
        }

    def __call__(self, force: bool = False) -> list[Entry]:
        current = self.fingerprint()
        if force or current != self._fingerprint:
            queue = queue_tool.build_queue(self.gh, self.bot_login, self.skip_authors, self.limit,
                                           self.any_change)
            ready = queue["ready"]
            feedback = {}
            # In rounds mode comments never wake the reviewer: the author submits instead.
            for entry in (queue["skipped"] if self.any_change else []):
                reviewed_at = entry.get("reviewed_at")
                if reviewed_at is None:
                    continue
                number = entry["number"]
                listing = current.get(number)
                signature = (entry["head"], reviewed_at, listing[3] if listing else None)
                cached = self._feedback.get(number)
                if force or listing is None or cached is None or signature != cached[:3]:
                    activity = activity_tool.read_activity(
                        self.gh, number, self.bot_login, reviewed_at, include_reviews=False,
                    )
                else:
                    activity = cached[3]
                feedback[number] = (*signature, activity)
                fresh = [item for item in activity if item["cursor"] not in self.seen_activity]
                if fresh:
                    ready.append({**entry, "reason": "feedback", "activity": fresh})
            self._ready = ready
            self._feedback = feedback
            self._fingerprint = current
        return self._ready


def settle(found: list[Entry], first_seen: dict[tuple[int, str], float], now: float,
           ci_grace: float) -> tuple[list[Entry], float | None]:
    """Hold heads that report no checks yet: right after a push GitHub has not registered
    the CI runs, so `ci == "none"` would look ready. Such a head counts as ready only once
    it has shown no checks for `ci_grace` seconds (a PR that really runs no CI).
    Returns the ready entries and the time the next held head becomes due, if any."""
    ready, next_due = [], None
    for e in found:
        if e.get("ci") != "none" or e.get("reason") == "feedback":
            ready.append(e)
            continue
        key = (e["number"], e["head"][:12])
        due = first_seen.setdefault(key, now) + ci_grace
        if now >= due:
            ready.append(e)
        else:
            next_due = due if next_due is None else min(next_due, due)
    return ready, next_due


def watch(check: Callable[[bool], list[Entry]], trigger: Trigger, seen: Seen,
          recheck: float, timeout: float | None, debounce: float = 0.0,
          clock: Callable[[], float] = time.monotonic,
          sleep: Callable[[float], None] = time.sleep, ci_grace: float = 0.0) -> list[Entry] | None:
    """Return the first non-empty list of unseen ready PRs, or None when `timeout` passes.

    A full refresh (review history included) runs at the start, on every EVENT, on a
    TIMEOUT, and whenever the independent `recheck` deadline has passed, so frequent
    poll ticks or webhook events can never postpone it."""
    first_seen: dict[tuple[int, str], float] = {}
    first = True

    def settled_check(force: bool) -> tuple[list[Entry], float | None]:
        nonlocal first
        ready = check(force)
        if first:
            bind_absent(seen, ready)
            first = False
        return settle(unseen(ready, seen), first_seen, clock(), ci_grace)

    return wait_for_action(settled_check, trigger, recheck, timeout, debounce, clock, sleep)


def wait_for_action(check: Callable[[bool], tuple[list[Entry], float | None]],
                    trigger: Trigger, recheck: float,
                    timeout: float | None, debounce: float,
                    clock: Callable[[], float] = time.monotonic,
                    sleep: Callable[[float], None] = time.sleep) -> list[Entry] | None:
    deadline = None if timeout is None else clock() + timeout
    next_refresh = clock()
    while True:
        force = clock() >= next_refresh
        if force:
            next_refresh = clock() + recheck
        found, next_due = check(force)
        if found:
            return found
        now = clock()
        remaining = next_refresh - now if deadline is None else min(next_refresh, deadline) - now
        if next_due is not None:
            remaining = min(remaining, next_due - now)
        if deadline is not None and now >= deadline:
            return None
        woke = trigger(max(remaining, 0.001))
        if woke == EVENT:
            if debounce:
                sleep(debounce)  # let a burst of events (push + check runs) settle
            next_refresh = clock()  # an event may be a review change: refresh review history


def poll_trigger(interval: float, sleep: Callable[[float], None] = time.sleep) -> Trigger:
    """Every `interval` seconds is a TICK; the fingerprint keeps it cheap."""
    def wait(timeout: float) -> str:
        sleep(min(interval, timeout))
        return TICK if interval <= timeout else TIMEOUT
    return wait


class _Handler(BaseHTTPRequestHandler):
    signal: threading.Event

    def do_POST(self) -> None:  # noqa: N802 (http.server API)
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(min(length, 1 << 20))
        self.send_response(204)
        self.end_headers()
        self.signal.set()

    def log_message(self, *args: Any) -> None:  # keep stdout for the result only
        return


class WebhookListener:
    """Local HTTP endpoint that `gh webhook forward` posts repository events to."""

    def __init__(self) -> None:
        self.signal = threading.Event()
        handler = type("Handler", (_Handler,), {"signal": self.signal})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/webhook"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self) -> "WebhookListener":
        self.thread.start()
        return self

    def wait(self, timeout: float) -> bool:
        got = self.signal.wait(timeout)
        self.signal.clear()
        return got

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def webhook_available(run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> bool:
    try:
        return run(["gh", "webhook", "--help"], capture_output=True, text=True, check=False, timeout=30).returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


class Forwarder:
    """`gh webhook forward` child process; its output is drained so the pipe never fills."""

    def __init__(self, repo: str, url: str) -> None:
        self.proc = subprocess.Popen(
            ["gh", "webhook", "forward", f"--repo={repo}", f"--events={EVENTS}", f"--url={url}"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.tail: deque[str] = deque(maxlen=5)
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self) -> None:
        if self.proc.stdout is not None:
            for line in self.proc.stdout:
                self.tail.append(line.strip())

    def poll(self) -> int | None:
        return self.proc.poll()

    def last_output(self) -> str:
        return " | ".join(t for t in self.tail if t)[:300]

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def webhook_trigger(listener: WebhookListener, forwarder: Forwarder,
                    fallback: Trigger, note: Callable[[str], None]) -> Trigger:
    """Wait on webhook events; switch to `fallback` for good if the forwarder exits."""
    state = {"fallen_back": False}

    def wait(timeout: float) -> str:
        if state["fallen_back"]:
            return fallback(timeout)
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return TIMEOUT
            if listener.wait(min(left, 5.0)):
                return EVENT
            code = forwarder.poll()
            if code is not None:
                note(f"webhook forwarder exited ({code}): {forwarder.last_output() or 'no output'}; polling instead")
                state["fallen_back"] = True
                return fallback(max(left, 0))
    return wait


def format_text(found: list[Entry]) -> str:
    lines = []
    for entry in found:
        lines.append(f"#{entry['number']}\t{entry['reason']}\tci={entry['ci']}\t"
                     f"{entry['head']}\t{entry['title'][:70]}")
        for item in entry.get("activity", []):
            lines.append(f"  {item['kind']}\t{item['author']}\t{item['url']}\t{item['cursor']}")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--json", action="store_true", help="print the wake-up result as JSON")
    p.add_argument("--author-pr", type=int, metavar="N",
                   help="watch one authored PR for reviews, comments and state changes")
    baseline = p.add_mutually_exclusive_group()
    baseline.add_argument("--snapshot", action="store_true", help="print the author snapshot as JSON and exit")
    baseline.add_argument("--after", type=Path, help="watch for changes since an author snapshot JSON file")
    p.add_argument("--seen-activity", action="append", default=[], metavar="CURSOR",
                   help="acknowledge one handled reviewer feedback item (repeatable)")
    p.add_argument("--source", choices=["auto", "webhook", "poll"], default="auto", help="event source (default auto)")
    p.add_argument("--interval", type=float, default=60.0, help="poll interval in seconds (default 60)")
    p.add_argument("--recheck", type=float, default=900.0, help="safety recheck in seconds (default 900)")
    p.add_argument("--debounce", type=float, default=5.0, help="seconds to let an event burst settle (default 5)")
    p.add_argument("--ci-grace", type=float, default=300.0,
                   help="seconds a head may show no CI checks before it counts as ready (default 300)")
    p.add_argument("--timeout", type=float, help="give up after this many seconds (exit 3)")
    p.add_argument("--seen", action="append", default=[], metavar="N@SHA[:CI]",
                   help="ignore PR N while its head is SHA and its CI state is unchanged (repeatable)")
    p.add_argument("--repo", help="owner/name for the listener, PR listing and review history (default: current repository)")
    p.add_argument("--bot-login", default=queue_tool.BOT_LOGIN, help=f"reviewer login (default {queue_tool.BOT_LOGIN})")
    p.add_argument("--skip-author", action="append", default=[], metavar="LOGIN", help="skip PRs by this author (repeatable)")
    p.add_argument("--any-change", action="store_true",
                   help="wake for every new head and new comment, not only when an author submits")
    p.add_argument("--limit", type=int, default=100, help="max open PRs to inspect")
    args = p.parse_args(argv)
    if args.interval <= 0 or args.recheck <= 0 or args.debounce < 0 or args.ci_grace < 0:
        p.error("--interval and --recheck must be positive, --debounce and --ci-grace not negative")
    if args.timeout is not None and args.timeout < 0:
        p.error("--timeout cannot be negative")
    if args.author_pr is not None:
        if args.author_pr < 1 or not (args.after or args.snapshot):
            p.error("--author-pr requires a positive PR number and --snapshot or --after")
        if args.seen or args.seen_activity:
            p.error("--seen and --seen-activity apply to reviewer mode")
    elif args.after or args.snapshot:
        p.error("--snapshot and --after require --author-pr")
    return args


def author_check(gh: Gh, repo: str, number: int, baseline: Path
                 ) -> Callable[[bool], tuple[list[Entry], None]]:
    previous = json.loads(baseline.read_text(encoding="utf-8"))
    required = {"repo", "number", "state", "head", "draft", "mergeable", "review_decision", "ci", "activity"}
    if isinstance(previous, dict) and "snapshot" in previous:
        previous = previous["snapshot"]
    if (not isinstance(previous, dict) or not required.issubset(previous)
            or str(previous["repo"]).casefold() != repo.casefold() or previous["number"] != number
            or not isinstance(previous["activity"], list)
            or any(not isinstance(item, dict) or not isinstance(item.get("cursor"), str)
                   for item in previous["activity"])):
        raise ValueError("--after must contain a snapshot for the watched repository and PR")

    def check(_force: bool) -> tuple[list[Entry], None]:
        snapshot = activity_tool.author_snapshot(gh, repo, number)
        changes = activity_tool.author_changes(snapshot, previous)
        return ([changes] if changes else []), None

    return check


def main(argv: list[str] | None = None, gh: Gh = queue_tool.run_gh) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    note = lambda msg: print(f"pr_review_watch: {msg}", file=sys.stderr, flush=True)  # noqa: E731
    try:
        seen = parse_seen(args.seen)
    except ValueError as exc:
        note(str(exc))
        return EXIT_ERROR

    poll = poll_trigger(args.interval)
    source, trigger = "poll", poll
    listener: WebhookListener | None = None
    forwarder: Forwarder | None = None
    try:
        # One repository for the listener, the PR listing and the review history.
        repo = args.repo or gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()
        scoped = scoped_gh(gh, repo)
        if args.snapshot:
            print(json.dumps(activity_tool.author_snapshot(scoped, repo, args.author_pr), indent=2))
            return EXIT_READY
        if args.author_pr is not None:
            check = author_check(scoped, repo, args.author_pr, args.after)
        else:
            check = QueueCheck(scoped, args.bot_login, set(args.skip_author), args.limit,
                               set(args.seen_activity), args.any_change)
        if args.source in ("auto", "webhook"):
            if webhook_available():
                listener = WebhookListener().start()
                forwarder = Forwarder(repo, listener.url)
                source, trigger = "webhook", webhook_trigger(listener, forwarder, poll, note)
            elif args.source == "webhook":
                note("gh webhook extension not installed (gh extension install cli/gh-webhook)")
                return EXIT_ERROR
            else:
                note("gh webhook extension not installed; polling every %gs" % args.interval)
        note(f"watching {repo} via {source}")
        if args.author_pr is not None:
            found = wait_for_action(check, trigger, args.recheck, args.timeout, args.debounce)
        else:
            found = watch(check, trigger, seen, args.recheck, args.timeout, args.debounce, ci_grace=args.ci_grace)
    except (queue_tool.GhError, OSError, ValueError) as exc:
        note(f"error: {exc}")
        return EXIT_ERROR
    except KeyboardInterrupt:
        return EXIT_TIMEOUT
    finally:
        if forwarder is not None:
            forwarder.stop()
        if listener is not None:
            listener.close()

    if found is None:
        note("timeout, nothing ready")
        return EXIT_TIMEOUT
    if args.author_pr is not None:
        result = found[0]
        if args.json:
            print(json.dumps(result, indent=2), flush=True)
        else:
            print(f"#{args.author_pr}: {len(result['activity'])} activity item(s), "
                  f"changed fields: {', '.join(result['changed']) or 'none'}", flush=True)
    else:
        print(json.dumps({"source": source, "ready": found}, indent=2) if args.json else format_text(found), flush=True)
    return EXIT_READY


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    raise SystemExit(main())
