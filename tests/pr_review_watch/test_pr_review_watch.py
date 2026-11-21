import json
import sys
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
    def test_parse_and_filter(self):
        seen = w.parse_seen(["#257@ab12cd34ef567890", "3@xyz"])
        self.assertEqual(seen, {(257, "ab12cd34ef56"), (3, "xyz")})
        ready = [entry(257, "ab12cd34ef56"), entry(257, "ffffffffffff"), entry(9)]
        self.assertEqual([(e["number"], e["head"]) for e in w.unseen(ready, seen)],
                         [(257, "ffffffffffff"), (9, "aaa111bbb222")])

    def test_rejects_bad_values(self):
        for bad in ["257", "x@sha", "5@"]:
            with self.assertRaises(ValueError):
                w.parse_seen([bad])


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


class WatchLoop(unittest.TestCase):
    def test_returns_immediately_when_ready(self):
        found = w.watch(lambda force: [entry(4)], lambda t: self.fail("no wait"), set(), 900, None)
        self.assertEqual([e["number"] for e in found], [4])

    def test_waits_for_event_then_returns(self):
        results = [[], [], [entry(7)]]
        forces, waits = [], []

        def check(force):
            forces.append(force)
            return results.pop(0)

        def trigger(timeout):
            waits.append(timeout)
            return len(waits) == 2  # first wait times out (safety recheck), second is an event

        clock = FakeClock()
        found = w.watch(check, trigger, set(), 900, None, debounce=5, clock=clock, sleep=clock.sleep)
        self.assertEqual([e["number"] for e in found], [7])
        self.assertEqual(forces, [True, True, False])  # initial + safety recheck force, event does not
        self.assertEqual(clock.now, 5)  # debounced once, after the event

    def test_seen_pr_does_not_wake(self):
        results = [[entry(4)], [entry(4), entry(5)]]
        found = w.watch(lambda f: results.pop(0), lambda t: True, {(4, "aaa111bbb222")}, 900, None)
        self.assertEqual([e["number"] for e in found], [5])

    def test_timeout(self):
        clock = FakeClock()

        def trigger(timeout):
            clock.sleep(timeout)
            return False

        found = w.watch(lambda f: [], trigger, set(), 900, 2000, clock=clock, sleep=clock.sleep)
        self.assertIsNone(found)
        self.assertEqual(clock.now, 2000)


class PollTrigger(unittest.TestCase):
    def test_interval_counts_as_event_unless_cut_by_timeout(self):
        clock = FakeClock()
        wait = w.poll_trigger(60, sleep=clock.sleep)
        self.assertTrue(wait(900))
        self.assertEqual(clock.now, 60)
        self.assertFalse(wait(30))
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
            return True

        wait = w.webhook_trigger(QuietListener(), DeadForwarder(), fallback, notes.append)
        self.assertTrue(wait(30))
        self.assertTrue(wait(30))
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
