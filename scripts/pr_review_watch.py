#!/usr/bin/env python3
"""Block until a PR is ready for review, then print it and exit (AGENTS.md rule 16).

Event-driven companion to pr_review_queue.py. The reviewer agent runs it as a
background command (or with its harness's monitor tool) and is woken only when
the review queue has something new, instead of re-checking on a model timer.

Event sources (``--source``):

    webhook   ``gh webhook forward`` (the ``cli/gh-webhook`` extension) relays the
              repository's pull_request, pull_request_review, check_suite and
              workflow_run events to a local HTTP listener on 127.0.0.1. Each
              event only triggers a queue recheck through the GitHub API, so the
              payload is never trusted. Needs admin rights on the repository.
    poll      a quiet ``gh`` check every ``--interval`` seconds. Review lookups
              run only when the open-PR list (heads, drafts, CI state) changed.
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

A ready PR that you have already handled for this head (for example one you
left with a COMMENT because CI is red) can be ignored with ``--seen N@SHA``. The
suppression is tied to the CI state: ``N@SHA:failed`` pins it, and a bare
``N@SHA`` takes the state the watcher first sees for that head. The watcher
wakes again when that PR gets a new head *or* its CI state changes (for example
a rerun on the same commit that turns red into green).

``--repo owner/name`` scopes everything (listener, PR listing, review history)
to that repository; by default the current checkout's repository is used.

Usage:
    python3 scripts/pr_review_watch.py                      # wait, print ready PRs, exit 0
    python3 scripts/pr_review_watch.py --json               # same, as JSON
    python3 scripts/pr_review_watch.py --source poll --interval 60
    python3 scripts/pr_review_watch.py --seen 257@ab12cd34ef56 --timeout 3600

Exit codes: 0 ready PRs found, 2 gh/usage error, 3 --timeout reached.
Needs an authenticated `gh` (reading only; reviews are posted via review_bot.py).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_review_queue as queue_tool  # noqa: E402

EVENTS = "pull_request,pull_request_review,check_suite,workflow_run"
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
        head = e["head"][:12]
        key = next((k for k in seen if k[0] == e["number"] and (head.startswith(k[1]) or k[1].startswith(head))), None)
        if key is None:
            out.append(e)
            continue
        if seen[key] is None:
            seen[key] = e.get("ci")  # bind to the first state observed
        if seen[key] != e.get("ci"):
            out.append(e)
    return out


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

    def __init__(self, gh: Gh, bot_login: str, skip_authors: set[str], limit: int) -> None:
        self.gh, self.bot_login, self.skip_authors, self.limit = gh, bot_login, skip_authors, limit
        self._fingerprint: str | None = None
        self._ready: list[Entry] = []

    def fingerprint(self) -> str:
        fields = "number,isDraft,headRefOid,statusCheckRollup"
        prs = json.loads(self.gh(["pr", "list", "--state", "open", "--limit", str(self.limit),
                                  "--json", fields]) or "[]")
        summary = sorted((p["number"], p.get("headRefOid", ""), bool(p.get("isDraft")),
                          queue_tool.ci_state(p.get("statusCheckRollup"))) for p in prs)
        return json.dumps(summary)

    def __call__(self, force: bool = False) -> list[Entry]:
        current = self.fingerprint()
        if force or current != self._fingerprint:
            queue = queue_tool.build_queue(self.gh, self.bot_login, self.skip_authors, self.limit)
            self._ready = queue["ready"]
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
        if e.get("ci") != "none":
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
    deadline = None if timeout is None else clock() + timeout
    first_seen: dict[tuple[int, str], float] = {}
    next_refresh = clock()
    while True:
        force = clock() >= next_refresh
        if force:
            next_refresh = clock() + recheck
        found, next_due = settle(unseen(check(force), seen), first_seen, clock(), ci_grace)
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
        return run(["gh", "webhook", "--help"], capture_output=True, text=True, check=False).returncode == 0
    except FileNotFoundError:
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
    return "\n".join(f"#{e['number']}\t{e['reason']}\tci={e['ci']}\t{e['head']}\t{e['title'][:70]}" for e in found)


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--json", action="store_true", help="print {source, ready} as JSON")
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
    p.add_argument("--limit", type=int, default=100, help="max open PRs to inspect")
    args = p.parse_args(argv)
    if args.interval <= 0 or args.recheck <= 0 or args.debounce < 0 or args.ci_grace < 0:
        p.error("--interval and --recheck must be positive, --debounce and --ci-grace not negative")
    return args


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
        check = QueueCheck(scoped_gh(gh, repo), args.bot_login, set(args.skip_author), args.limit)
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
        found = watch(check, trigger, seen, args.recheck, args.timeout, args.debounce, ci_grace=args.ci_grace)
    except (queue_tool.GhError, json.JSONDecodeError) as exc:
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
    print(json.dumps({"source": source, "ready": found}, indent=2) if args.json else format_text(found), flush=True)
    return EXIT_READY


if __name__ == "__main__":
    raise SystemExit(main())
