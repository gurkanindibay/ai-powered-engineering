import json
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import pr_review_watch as w  # noqa: E402

DONE = [{"status": "COMPLETED", "conclusion": "SUCCESS"}]
RUNNING = [{"status": "IN_PROGRESS", "conclusion": ""}]


def pr(number, head="aaa111bbb222ccc", draft=False, rollup=DONE):
    return {"number": number, "title": f"PR {number}", "isDraft": draft, "headRefOid": head,
            "author": {"login": "dev"}, "statusCheckRollup": rollup}


def entry(number, head="aaa111bbb222"):
    return {"number": number, "head": head, "reason": "new", "ci": "passed", "title": f"PR {number}"}


class FakeGh:
    """Serves `gh pr list` and the per-PR review lookups; counts review lookups."""

    def __init__(self, prs, reviews=None):
        self.prs, self.reviews, self.review_calls = prs, reviews or {}, 0

    def __call__(self, args):
        if args[0] == "pr":
            return json.dumps(self.prs)
        if args[0] == "repo":
            return "owner/name\n"
        self.review_calls += 1
        number = int(args[1].split("/pulls/")[1].split("/")[0])
        return "\n".join(json.dumps(r) for r in self.reviews.get(number, []))


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class Seen(unittest.TestCase):
    def test_parse(self):
        seen = w.parse_seen(["#257@ab12cd34ef567890", "3@abc1234:failed"])
        self.assertEqual(seen, {(257, "ab12cd34ef56"): None, (3, "abc1234"): "failed"})

    def test_rejects_bad_values(self):
        for bad in ["257", "x@abcdef1", "5@", "5@abc", "5@abcdef1:green"]:
            with self.assertRaises(ValueError):
                w.parse_seen([bad])

    def test_filter_by_head_and_ci_state(self):
        seen = w.parse_seen(["257@ab12cd34ef56"])
        ready = [entry(257, "ab12cd34ef56"), entry(257, "ffffffffffff"), entry(9)]
        self.assertEqual([(e["number"], e["head"]) for e in w.unseen(ready, seen)],
                         [(257, "ffffffffffff"), (9, "aaa111bbb222")])
        self.assertEqual(seen[(257, "ab12cd34ef56")], "passed")  # bound to the first state seen

    def test_short_sha_matches_queue_head(self):
        # The queue reports 12-char heads; a 7- or 8-char SHA from `git log --oneline` must match.
        seen = w.parse_seen(["264@5a9f4328"])
        self.assertEqual(w.unseen([entry(264, "5a9f432883b0")], seen), [])
        self.assertEqual(len(w.unseen([entry(264, "5a9f999999b0")], seen)), 1)
        self.assertEqual(len(w.unseen([entry(265, "5a9f432883b0")], seen)), 1)  # other PR

    def test_same_head_ci_rerun_wakes(self):
        # Reviewer left a COMMENT on a red head; the author reruns CI on the same commit.
        seen = w.parse_seen(["4@aaa111bbb222"])
        red = {**entry(4), "ci": "failed"}
        self.assertEqual(w.unseen([red], seen), [])
        self.assertEqual(w.unseen([red], seen), [])  # still red: stays quiet
        self.assertEqual([e["ci"] for e in w.unseen([entry(4)], seen)], ["passed"])

    def test_restart_during_pending_rerun_wakes_when_green(self):
        """Reviewer restarts with a bare --seen while a same-commit rerun is still pending:
        the PR is not ready at the first check, so turning green must wake the reviewer."""
        results = [[], [entry(4)]]  # first: rerun pending (absent from ready), then passed
        seen = w.parse_seen(["4@aaa111bbb222"])
        found = w.watch(lambda f: results.pop(0), lambda t: w.EVENT, seen, 900, None)
        self.assertEqual([(e["number"], e["ci"]) for e in found], [(4, "passed")])
        self.assertEqual(seen[(4, "aaa111bbb222")], "absent")

    def test_restart_with_red_ci_stays_quiet_until_green(self):
        red = {**entry(4), "ci": "failed"}
        results = [[red], [red], [], [entry(4)]]
        seen = w.parse_seen(["4@aaa111bbb222:failed"])
        found = w.watch(lambda f: results.pop(0), lambda t: w.EVENT, seen, 900, None)
        self.assertEqual([e["ci"] for e in found], ["passed"])
        self.assertEqual(results, [])  # woke only on the green snapshot

    def test_pinned_state(self):
        seen = w.parse_seen(["4@aaa111bbb222:failed"])
        self.assertEqual(len(w.unseen([entry(4)], seen)), 1)  # already green: not suppressed


class QueueCheckTest(unittest.TestCase):
    def test_skips_review_lookups_while_pr_list_unchanged(self):
        gh = FakeGh([pr(1)])
        check = w.QueueCheck(gh, "bot", set(), 100)
        self.assertEqual([e["number"] for e in check()], [1])
        self.assertEqual(gh.review_calls, 1)
        check()
        self.assertEqual(gh.review_calls, 1)  # same fingerprint: cached
        check(force=True)
        self.assertEqual(gh.review_calls, 2)
        gh.prs = [pr(1, head="new000head000")]
        check()
        self.assertEqual(gh.review_calls, 3)  # new head: recomputed

    def test_ci_finishing_changes_fingerprint(self):
        gh = FakeGh([pr(1, rollup=RUNNING)])
        check = w.QueueCheck(gh, "bot", set(), 100)
        self.assertEqual(check(), [])
        gh.prs = [pr(1, rollup=DONE)]
        self.assertEqual([e["number"] for e in check()], [1])


class LoopGh:
    """Fixture API for both sides of the same PR."""

    def __init__(self):
        self.pr = {**pr(42), "state": "OPEN", "mergeable": "MERGEABLE", "reviewDecision": ""}
        self.bot_reviews = []
        self.activity = {"reviews": [], "comments": [], "inline": []}

    def __call__(self, args):
        if args[:2] == ["pr", "list"]:
            return json.dumps([self.pr] if self.pr["state"] == "OPEN" else [])
        if args[:2] == ["pr", "view"]:
            return json.dumps(self.pr)
        if args[:2] == ["repo", "view"]:
            return "owner/repo"
        path = args[1]
        if path.endswith("/reviews"):
            items = self.bot_reviews if "commit_id,submitted_at" in args[-1] else self.activity["reviews"]
        else:
            items = self.activity["inline" if "/pulls/" in path else "comments"]
        return "\n".join(json.dumps(item) for item in items)

    def add_review(self, state, at):
        head = self.pr["headRefOid"]
        self.bot_reviews.append({"state": state, "commit_id": head, "submitted_at": at})
        self.activity["reviews"].append(feedback(len(self.bot_reviews), "bot", at, state=state, commit=head))
        self.pr["reviewDecision"] = state


def feedback(number, author, at, **fields):
    return {"id": number, "author": author, "at": at, "url": f"https://example.test/{number}",
            "state": None, "commit": None, "body": "Review feedback", **fields}


class DeveloperReviewerLoop(unittest.TestCase):
    def test_changes_requested_push_green_approval_and_close(self):
        gh = LoopGh()
        check = w.QueueCheck(gh, "bot", set(), 100)

        def snapshot():
            return w.activity_tool.author_snapshot(gh, "owner/repo", 42)

        base = snapshot()
        self.assertEqual(check()[0]["reason"], "new")

        gh.add_review("CHANGES_REQUESTED", "2026-11-22T10:00:00Z")
        change = w.activity_tool.author_changes(snapshot(), base)
        self.assertEqual(change["activity"][0]["state"], "CHANGES_REQUESTED")
        self.assertEqual(check(force=True), [])

        gh.pr.update(headRefOid="bbb222ccc333ddd", statusCheckRollup=RUNNING)
        self.assertEqual(check(), [])
        gh.pr.update(statusCheckRollup=DONE)
        self.assertEqual(check()[0]["reason"], "new_head")

        base = snapshot()
        gh.add_review("APPROVED", "2026-11-22T10:02:00Z")
        change = w.activity_tool.author_changes(snapshot(), base)
        self.assertEqual(change["activity"][0]["state"], "APPROVED")
        self.assertEqual(check(force=True), [])

        gh.pr.update(state="MERGED")
        self.assertEqual(w.activity_tool.author_changes(snapshot(), change["snapshot"])["changed"], ["state"])

    def test_same_head_feedback_is_independent_of_verdict_and_ci_suppression(self):
        gh = LoopGh()
        gh.add_review("APPROVED", "2026-11-22T10:00:00Z")
        gh.activity["inline"] = [
            feedback(1, "dev", "2026-11-22T09:59:00Z"),
            feedback(2, "bot", "2026-11-22T10:01:00Z"),
            feedback(3, "dev", "2026-11-22T10:02:00Z"),
        ]
        check = w.QueueCheck(gh, "bot", set(), 100)
        found = w.watch(check, lambda _: self.fail("must wake"), w.parse_seen(["42@aaa111bbb222:passed"]),
                        900, None, ci_grace=300)
        self.assertEqual(found[0]["reason"], "feedback")
        self.assertEqual([item["id"] for item in found[0]["activity"]], [3])
        cursor = found[0]["activity"][0]["cursor"]
        acknowledged = w.QueueCheck(gh, "bot", set(), 100, {cursor})
        self.assertEqual(acknowledged(), [])
        gh.activity["comments"] = [feedback(7, "dev", "2026-11-22T10:03:00Z")]
        gh.pr["updatedAt"] = "2026-11-22T10:03:00Z"
        self.assertEqual([item["id"] for item in acknowledged()[0]["activity"]], [7])
        gh.activity["inline"][2]["body"] = "Clarification"
        self.assertEqual([item["id"] for item in acknowledged(force=True)[0]["activity"]], [3, 7])

    def test_author_cli_ignores_own_replies_and_resumes_from_wake_up_json(self):
        gh = LoopGh()
        args = ["--source", "poll", "--author-pr", "42", "--json", "--timeout", "0"]
        with tempfile.TemporaryDirectory() as folder:
            baseline = Path(folder) / "pr.json"
            code, out = _capture(lambda: w.main([*args, "--snapshot"], gh=gh))
            self.assertEqual(code, 0)
            baseline.write_text(out)
            after = [*args, "--after", str(baseline)]
            gh.activity["comments"] = [feedback(1, "dev", "2026-11-22T10:01:00Z")]
            self.assertEqual(_capture(lambda: w.main(after, gh=gh))[0], w.EXIT_TIMEOUT)
            gh.activity["inline"] = [feedback(1, "bot", "2026-11-22T10:02:00Z")]
            code, out = _capture(lambda: w.main(after, gh=gh))
            self.assertEqual(code, w.EXIT_READY)
            self.assertEqual([item["kind"] for item in json.loads(out)["activity"]], ["inline"])
            baseline.write_text(out)
            self.assertEqual(_capture(lambda: w.main(after, gh=gh))[0], w.EXIT_TIMEOUT)
            gh.activity["inline"][0]["body"] = "Edited review feedback"
            self.assertEqual(_capture(lambda: w.main(after, gh=gh))[0], w.EXIT_READY)

    def test_author_ignores_transient_mergeability_and_wakes_for_confirmed_conflicts(self):
        gh = LoopGh()
        known = w.activity_tool.author_snapshot(gh, "owner/repo", 42)
        unknown = {**known, "mergeable": "UNKNOWN"}
        conflict = {**known, "mergeable": "CONFLICTING"}
        changes = w.activity_tool.author_changes
        self.assertIsNone(changes(unknown, known))
        self.assertIsNone(changes(known, unknown))
        self.assertIsNone(changes(unknown, conflict))
        self.assertEqual(changes(conflict, unknown)["changed"], ["mergeable"])
        self.assertEqual(changes(known, conflict)["changed"], ["mergeable"])

    def test_subscriptions_include_comment_events(self):
        self.assertTrue({"pull_request_review_comment", "issue_comment", "pull_request_review"}
                        <= set(w.EVENTS.split(",")))


class WatchLoop(unittest.TestCase):
    def test_returns_immediately_when_ready(self):
        found = w.watch(lambda force: [entry(4)], lambda t: self.fail("no wait"), {}, 900, None)
        self.assertEqual([e["number"] for e in found], [4])

    def test_event_forces_refresh_and_debounces(self):
        results = [[], [], [entry(7)]]
        forces = []
        wakes = iter([w.TICK, w.EVENT])

        def check(force):
            forces.append(force)
            return results.pop(0)

        clock = FakeClock()

        def trigger(timeout):
            clock.sleep(1)
            return next(wakes)

        found = w.watch(check, trigger, {}, 900, None, debounce=5, clock=clock, sleep=clock.sleep)
        self.assertEqual([e["number"] for e in found], [7])
        self.assertEqual(forces, [True, False, True])  # start forced, tick cheap, event forced
        self.assertEqual(clock.now, 7)  # two waits of 1 s plus one 5 s debounce, after the event

    def test_continuous_ticks_still_refresh_on_schedule(self):
        """An unchanged PR list with a tick every 60 s must still get a full refresh every
        `recheck` seconds, so a review dismissal is noticed."""
        clock = FakeClock()
        forced_at = []

        def check(force):
            if force:
                forced_at.append(clock.now)
            return [entry(9)] if clock.now >= 2000 else []

        wait = w.poll_trigger(60, sleep=clock.sleep)
        found = w.watch(check, wait, {}, 900, None, clock=clock, sleep=clock.sleep)
        self.assertEqual([e["number"] for e in found], [9])
        self.assertEqual(forced_at, [0, 900, 1800])  # independent of the 60 s ticks

    def test_seen_pr_does_not_wake(self):
        results = [[entry(4)], [entry(4), entry(5)]]
        found = w.watch(lambda f: results.pop(0), lambda t: w.EVENT, w.parse_seen(["4@aaa111bbb222"]), 900, None)
        self.assertEqual([e["number"] for e in found], [5])

    def test_timeout(self):
        clock = FakeClock()

        def trigger(timeout):
            clock.sleep(timeout)
            return w.TIMEOUT

        found = w.watch(lambda f: [], trigger, {}, 900, 2000, clock=clock, sleep=clock.sleep)
        self.assertIsNone(found)
        self.assertEqual(clock.now, 2000)


class CiGrace(unittest.TestCase):
    """A head with no checks yet (just pushed) must not wake the reviewer before CI registers."""

    def no_ci(self, number, head="aaa111bbb222"):
        return {**entry(number, head), "ci": "none"}

    def test_settle_holds_then_releases(self):
        first_seen = {}
        ready, due = w.settle([self.no_ci(5), entry(6)], first_seen, now=100, ci_grace=300)
        self.assertEqual([e["number"] for e in ready], [6])
        self.assertEqual(due, 400)
        ready, due = w.settle([self.no_ci(5)], first_seen, now=399, ci_grace=300)
        self.assertEqual((ready, due), ([], 400))
        ready, due = w.settle([self.no_ci(5)], first_seen, now=400, ci_grace=300)
        self.assertEqual(([e["number"] for e in ready], due), ([5], None))

    def test_new_head_restarts_grace(self):
        first_seen = {}
        w.settle([self.no_ci(5, "old000000000")], first_seen, now=0, ci_grace=300)
        ready, due = w.settle([self.no_ci(5, "new000000000")], first_seen, now=350, ci_grace=300)
        self.assertEqual((ready, due), ([], 650))

    def test_watch_waits_for_checks_to_register(self):
        clock = FakeClock()
        # Just pushed: no checks; then CI registers (pending, so not ready); then it finishes.
        results = [[self.no_ci(7)], [], [entry(7)]]
        waits = []

        def trigger(timeout):
            waits.append(timeout)
            clock.sleep(10)
            return w.EVENT

        found = w.watch(lambda f: results.pop(0), trigger, {}, 900, None,
                        clock=clock, sleep=clock.sleep, ci_grace=300)
        self.assertEqual([e["ci"] for e in found], ["passed"])
        self.assertEqual(waits[0], 300)  # capped at the grace deadline, not the 900 s recheck

    def test_watch_releases_pr_without_ci_after_grace(self):
        clock = FakeClock()

        def trigger(timeout):
            clock.sleep(timeout)
            return w.TIMEOUT

        found = w.watch(lambda f: [self.no_ci(8)], trigger, {}, 900, None,
                        clock=clock, sleep=clock.sleep, ci_grace=300)
        self.assertEqual([e["number"] for e in found], [8])
        self.assertEqual(clock.now, 300)


class PollTrigger(unittest.TestCase):
    def test_interval_is_a_tick_unless_cut_by_timeout(self):
        clock = FakeClock()
        wait = w.poll_trigger(60, sleep=clock.sleep)
        self.assertEqual(wait(900), w.TICK)
        self.assertEqual(clock.now, 60)
        self.assertEqual(wait(30), w.TIMEOUT)
        self.assertEqual(clock.now, 90)


class Webhook(unittest.TestCase):
    def test_listener_signals_on_post(self):
        listener = w.WebhookListener().start()
        try:
            self.assertFalse(listener.wait(0.01))
            req = urllib.request.Request(listener.url, data=b'{"action":"opened"}', method="POST",
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                self.assertEqual(resp.status, 204)
            self.assertTrue(listener.wait(5))
            self.assertFalse(listener.wait(0.01))  # cleared after use
            self.assertTrue(listener.url.startswith("http://127.0.0.1:"))
        finally:
            listener.close()

    def test_dead_forwarder_falls_back_to_poll(self):
        class DeadForwarder:
            def poll(self):
                return 1

            def last_output(self):
                return "hook already exists"

        class QuietListener:
            def wait(self, timeout):
                return False

        notes, fallback_calls = [], []

        def fallback(timeout):
            fallback_calls.append(timeout)
            return w.TICK

        wait = w.webhook_trigger(QuietListener(), DeadForwarder(), fallback, notes.append)
        self.assertEqual(wait(30), w.TICK)
        self.assertEqual(wait(30), w.TICK)
        self.assertEqual(len(fallback_calls), 2)
        self.assertEqual(len(notes), 1)
        self.assertIn("hook already exists", notes[0])

    def test_webhook_available(self):
        class Proc:
            def __init__(self, code):
                self.returncode = code

        self.assertTrue(w.webhook_available(lambda *a, **k: Proc(0)))
        self.assertFalse(w.webhook_available(lambda *a, **k: Proc(1)))

        def missing(*a, **k):
            raise FileNotFoundError

        self.assertFalse(w.webhook_available(missing))


class RepoScope(unittest.TestCase):
    def test_scoped_gh_rewrites_listing_and_api(self):
        calls = []
        gh = w.scoped_gh(lambda a: calls.append(a) or "", "other/repo")
        gh(["pr", "list", "--json", "number"])
        gh(["api", "repos/{owner}/{repo}/pulls/3/reviews", "--paginate"])
        gh(["repo", "view"])
        self.assertEqual(calls[0][-2:], ["--repo", "other/repo"])
        self.assertEqual(calls[1][1], "repos/other/repo/pulls/3/reviews")
        self.assertEqual(calls[2], ["repo", "view"])

    def test_main_reads_only_the_given_repo(self):
        gh = FakeGh([pr(12)])
        calls = []

        def recording(args):
            calls.append(args)
            return gh(args)

        code, _ = _capture(lambda: w.main(["--source", "poll", "--repo", "other/repo"], gh=recording))
        self.assertEqual(code, 0)
        self.assertFalse(any(a[0] == "repo" for a in calls))  # no fallback to the checkout's repo
        for a in calls:
            if a[0] == "pr":
                self.assertIn("other/repo", a)
            if a[0] == "api":
                self.assertTrue(a[1].startswith("repos/other/repo/"), a[1])


class Main(unittest.TestCase):
    def test_poll_source_prints_ready_json(self):
        gh = FakeGh([pr(12), pr(13, draft=True)])
        out = _capture(lambda: w.main(["--source", "poll", "--json"], gh=gh))
        self.assertEqual(out[0], 0)
        data = json.loads(out[1])
        self.assertEqual(data["source"], "poll")
        self.assertEqual([e["number"] for e in data["ready"]], [12])

    def test_bad_seen_is_usage_error(self):
        self.assertEqual(_capture(lambda: w.main(["--source", "poll", "--seen", "oops"], gh=FakeGh([])))[0], 2)

    def test_gh_error_exit_2(self):
        def broken(args):
            raise w.queue_tool.GhError("boom")

        self.assertEqual(_capture(lambda: w.main(["--source", "poll"], gh=broken))[0], 2)


def _capture(fn):
    import contextlib
    import io

    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = fn()
    return code, out.getvalue()


if __name__ == "__main__":
    unittest.main()
