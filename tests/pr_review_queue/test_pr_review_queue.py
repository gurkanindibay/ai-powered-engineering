import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import pr_review_queue as q  # noqa: E402

DONE = [{"status": "COMPLETED", "conclusion": "SUCCESS"}]
RUNNING = [{"status": "IN_PROGRESS", "conclusion": ""}]
RED = [{"status": "COMPLETED", "conclusion": "FAILURE"}]


def pr(number, head="aaa", draft=False, rollup=DONE, author="dev"):
    return {"number": number, "title": f"PR {number}", "isDraft": draft, "headRefOid": head,
            "author": {"login": author}, "statusCheckRollup": rollup}


def review(state, commit, at="2026-01-01T00:00:00Z"):
    return {"state": state, "commit_id": commit, "submitted_at": at}


class FakeGh:
    def __init__(self, prs, reviews):
        self.prs, self.reviews, self.calls = prs, reviews, []
        self.submissions = {}

    def __call__(self, args):
        self.calls.append(args)
        if args[0] == "api" and args[1].endswith("/timeline"):
            return self.submissions.get(int(args[1].split("/issues/")[1].split("/")[0]), "")
        if args[0] == "pr":
            return json.dumps(self.prs)
        number = int(args[1].split("/pulls/")[1].split("/")[0])
        return "\n".join(json.dumps(r) for r in self.reviews.get(number, []))


class CiState(unittest.TestCase):
    def test_states(self):
        self.assertEqual(q.ci_state(None), "none")
        self.assertEqual(q.ci_state(DONE), "passed")
        self.assertEqual(q.ci_state(RUNNING), "pending")
        self.assertEqual(q.ci_state(RED), "failed")
        self.assertEqual(q.ci_state(DONE + RUNNING), "pending")
        self.assertEqual(q.ci_state([{"state": "PENDING"}]), "pending")
        self.assertEqual(q.ci_state([{"state": "SUCCESS"}]), "passed")


class Rounds(unittest.TestCase):
    AT = "2026-01-01T00:00:00Z"
    LATER = "2026-01-02T00:00:00Z"

    def outcome(self, last, head="aaa", submitted=None, any_change=False):
        e = q.classify(pr(1, head=head), last, set(), submitted, any_change)
        return e["bucket"], e["reason"]

    def test_every_review_event_ends_the_round(self):
        for state in ("APPROVED", "CHANGES_REQUESTED", "COMMENTED"):
            last = review(state, "aaa", self.AT)
            self.assertEqual(self.outcome(last), ("skipped", "already_reviewed"), state)
            self.assertEqual(self.outcome(last, head="bbb"), ("skipped", "not_submitted"), state)

    def test_submission_after_the_review_opens_a_round(self):
        last = review("CHANGES_REQUESTED", "aaa", self.AT)
        self.assertEqual(self.outcome(last, submitted=self.LATER), ("ready", "requested"))
        self.assertEqual(self.outcome(last, head="bbb", submitted=self.LATER), ("ready", "new_head"))

    def test_submission_before_the_review_is_already_answered(self):
        last = review("APPROVED", "aaa", self.LATER)
        self.assertEqual(self.outcome(last, submitted=self.AT), ("skipped", "already_reviewed"))

    def test_dismissed_review_still_owes_a_verdict(self):
        self.assertEqual(self.outcome(review("DISMISSED", "aaa", self.AT)), ("ready", "unfinished"))

    def test_any_change_reviews_every_new_head(self):
        last = review("CHANGES_REQUESTED", "aaa", self.AT)
        self.assertEqual(self.outcome(last, head="bbb", any_change=True), ("ready", "new_head"))


class LastSubmission(unittest.TestCase):
    def test_cache_rereads_only_when_the_pr_or_review_changes(self):
        calls, cache = [], {}

        def gh(args):
            calls.append(args)
            return "2026-01-02T00:00:00Z\n"

        def read(updated, reviewed):
            return q.cached_submission(gh, {"number": 5, "updatedAt": updated},
                                       {"submitted_at": reviewed}, "bot", cache)

        for updated, reviewed in [("a", "r1"), ("a", "r1"), ("b", "r1"), ("b", "r2")]:
            self.assertEqual(read(updated, reviewed), "2026-01-02T00:00:00Z")
        self.assertEqual(len(calls), 3)

    def test_newest_matching_timeline_event(self):
        calls = []

        def gh(args):
            calls.append(args)
            return "2026-01-02T00:00:00Z\n2026-01-01T00:00:00Z\n"

        self.assertEqual(q.last_submission(gh, 5, "bot"), "2026-01-02T00:00:00Z")
        self.assertIn("issues/5/timeline", calls[0][1])
        self.assertIn('requested_reviewer.login=="bot"', calls[0][-1])
        self.assertIsNone(q.last_submission(lambda _: "", 5, "bot"))


class Classify(unittest.TestCase):
    def bucket(self, p, last=None, skip=()):
        e = q.classify(p, last, set(skip), any_change=True)
        return e["bucket"], e["reason"]

    def test_new_pr_is_ready(self):
        self.assertEqual(self.bucket(pr(1)), ("ready", "new"))

    def test_new_commit_after_review_is_ready(self):
        self.assertEqual(self.bucket(pr(1, "bbb"), review("CHANGES_REQUESTED", "aaa")), ("ready", "new_head"))

    def test_final_verdict_on_head_is_skipped(self):
        for state in ("APPROVED", "CHANGES_REQUESTED"):
            self.assertEqual(self.bucket(pr(1), review(state, "aaa")), ("skipped", "already_reviewed"))

    def test_comment_on_head_is_unfinished(self):
        self.assertEqual(self.bucket(pr(1), review("COMMENT", "aaa")), ("ready", "unfinished"))
        self.assertEqual(self.bucket(pr(1), review("DISMISSED", "aaa")), ("ready", "unfinished"))

    def test_pending_ci_waits(self):
        self.assertEqual(self.bucket(pr(1, rollup=RUNNING)), ("waiting_ci", "new"))

    def test_failed_ci_is_still_ready(self):
        self.assertEqual(self.bucket(pr(1, rollup=RED)), ("ready", "new"))

    def test_draft_and_own_pr_skipped(self):
        self.assertEqual(self.bucket(pr(1, draft=True)), ("skipped", "draft"))
        self.assertEqual(self.bucket(pr(1, author="me"), skip=["me"]), ("skipped", "own_pr"))


class BuildQueue(unittest.TestCase):
    def test_uses_latest_bot_review_and_skips_draft_lookup(self):
        reviews = {
            2: [review("CHANGES_REQUESTED", "old", "2026-01-01T00:00:00Z"),
                review("APPROVED", "bbb", "2026-01-02T00:00:00Z")],
            3: [review("COMMENT", "ccc")],
        }
        gh = FakeGh([pr(1), pr(2, "bbb"), pr(3, "ccc"), pr(4, draft=True), pr(5, rollup=RUNNING)], reviews)
        queue = q.build_queue(gh, any_change=True)
        self.assertEqual([e["number"] for e in queue["ready"]], [1, 3])
        self.assertEqual([e["number"] for e in queue["waiting_ci"]], [5])
        self.assertEqual({e["number"]: e["reason"] for e in queue["skipped"]},
                         {2: "already_reviewed", 4: "draft"})
        looked_up = [c[1] for c in gh.calls if c[0] == "api"]
        self.assertFalse(any("/pulls/4/" in c for c in looked_up))

    def test_rounds_read_the_timeline_only_after_an_earlier_review(self):
        gh = FakeGh([pr(1), pr(2, "bbb"), pr(3, "ccc")],
                    {2: [review("CHANGES_REQUESTED", "old")], 3: [review("CHANGES_REQUESTED", "old")]})
        gh.submissions = {2: "2026-01-03T00:00:00Z\n"}
        queue = q.build_queue(gh)
        self.assertEqual([(e["number"], e["reason"]) for e in queue["ready"]], [(1, "new"), (2, "new_head")])
        self.assertEqual([(e["number"], e["reason"]) for e in queue["skipped"]], [(3, "not_submitted")])
        self.assertFalse(any("/issues/1/" in c[1] for c in gh.calls if c[0] == "api"))

    def test_main_ok_and_error(self):
        self.assertEqual(q.main(["--json"], gh=FakeGh([pr(1)], {})), 0)

        def broken(args):
            raise q.GhError("boom")
        self.assertEqual(q.main([], gh=broken), 2)

    def test_empty_text_output(self):
        queue = q.build_queue(FakeGh([], {}))
        self.assertEqual(q.format_text(queue, False), "nothing to review")


if __name__ == "__main__":
    unittest.main()
