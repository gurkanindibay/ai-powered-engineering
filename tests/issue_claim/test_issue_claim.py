import io
import json
import sys
import unittest
import urllib.parse
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import issue_claim as ic  # noqa: E402


class FakeGh:
    """In-memory GitHub for one issue: labels plus the server's labeled-event log."""

    def __init__(self, labels=()):
        self.labels = []
        self.events = []
        self.repo_labels_deleted = []
        self.event_reads = 0
        self.lag = []  # per-read count of newest events hidden (API lag)
        self.add(list(labels))

    def add(self, names):
        for name in names:
            if name not in self.labels:
                self.labels.append(name)
                self.events.append((len(self.events) + 1, name))

    def __call__(self, args):
        joined = " ".join(args)
        if args[0] == "repo":
            return "o/r\n"
        if "issues?state=all" in joined:
            return "0"
        if "/events" in joined:
            self.event_reads += 1
            visible = self.events[: max(0, len(self.events) - self.lag.pop(0))] if self.lag else self.events
            return "\n".join(f"{i} {n}" for i, n in visible)
        if "--jq" in args and "/issues/" in joined:
            return json.dumps(self.labels)
        if "-X" in args and args[args.index("-X") + 1] == "DELETE":
            if "/issues/" not in args[-1]:
                self.repo_labels_deleted.append(args[-1])
                return ""
            raw = args[-1].rsplit("/labels/", 1)[1]
            if "/" in raw or ":" in raw or " " in raw:
                raise ic.ClaimError("404")  # GitHub reads an unencoded `/` as a path separator
            name = urllib.parse.unquote(raw)
            if name not in self.labels:
                raise ic.ClaimError("404")
            self.labels.remove(name)
            return ""
        added = [a.split("=", 1)[1] for a in args if a.startswith("labels[]=")]
        if added:
            self.add(added)
        return ""  # label creation


def run_cli(fake, *argv):
    out = io.StringIO()
    with redirect_stdout(out):
        code = ic.main([*argv, "--json"], run=fake, env={})
    return code, json.loads(out.getvalue())


class IssueClaimTests(unittest.TestCase):
    def stale_first_read(self, first=()):
        """Make the next claim's first read see `first` (the issue looked free)."""
        real, calls = ic.read_labels, {"n": 0}

        def racing(run, repo, number):
            calls["n"] += 1
            return list(first) if calls["n"] == 1 else real(run, repo, number)

        ic.read_labels = racing
        self.addCleanup(setattr, ic, "read_labels", real)

    def test_claim_adds_in_progress_and_one_owner_label(self):
        fake = FakeGh()
        code, out = run_cli(fake, "claim", "7", "--harness", "Claude", "--session", "abc 123")
        self.assertEqual(code, 0)
        self.assertEqual(sorted(fake.labels), ["claim:claude/abc-123", "in progress"])
        self.assertEqual(out["session"], "abc-123")

    def test_other_session_is_refused(self):
        fake = FakeGh(["in progress", "claim:codex/s1"])
        code, out = run_cli(fake, "claim", "7", "--harness", "claude", "--session", "s2")
        self.assertEqual(code, 1)
        self.assertIn("codex/s1", out["message"])
        self.assertIn("claim:codex/s1", fake.labels)

    def test_bare_in_progress_is_refused(self):
        code, _ = run_cli(FakeGh(["in progress"]), "claim", "7", "--harness", "claude", "--session", "s2")
        self.assertEqual(code, 1)

    def test_same_session_reclaim_ok_and_force_takes_over(self):
        fake = FakeGh(["in progress", "claim:claude/s1"])
        self.assertEqual(run_cli(fake, "claim", "7", "--harness", "claude", "--session", "s1")[0], 0)
        code, _ = run_cli(fake, "claim", "7", "--harness", "codex", "--session", "s9", "--force")
        self.assertEqual(code, 0)
        self.assertEqual(sorted(fake.labels), ["claim:codex/s9", "in progress"])

    def test_same_harness_race_loser_leaves_winner_intact(self):
        fake = FakeGh(["in progress", "claim:claude/a"])
        self.stale_first_read()
        code, out = run_cli(fake, "claim", "1", "--harness", "claude", "--session", "b")
        self.assertEqual(code, 1)
        self.assertIn("claude/a", out["message"])
        self.assertEqual(ic.parse_owner(fake.labels), ic.Owner(True, "claude", "a"))
        self.assertEqual(run_cli(fake, "release", "1", "--harness", "claude", "--session", "a")[0], 0)

    def test_cross_harness_race_leaves_no_stray_label(self):
        fake = FakeGh(["in progress", "claim:codex/a"])
        self.stale_first_read()
        self.assertEqual(run_cli(fake, "claim", "1", "--harness", "claude", "--session", "b")[0], 1)
        self.assertEqual(sorted(fake.labels), ["claim:codex/a", "in progress"])
        self.assertEqual(ic.parse_owner(fake.labels), ic.Owner(True, "codex", "a"))
        self.assertEqual(run_cli(fake, "release", "1", "--harness", "codex", "--session", "a")[0], 0)
        self.assertEqual(fake.labels, [])

    def test_earlier_claim_wins_even_with_larger_session_id(self):
        # b claimed first (server order); a, with the smaller id but a stale
        # first read, must back off instead of creating two owners.
        fake = FakeGh(["in progress", "claim:claude/b"])
        self.stale_first_read()
        code, out = run_cli(fake, "claim", "1", "--harness", "claude", "--session", "a")
        self.assertEqual(code, 1)
        self.assertIn("claude/b", out["message"])
        self.assertEqual(ic.parse_owner(fake.labels).session, "b")

    def test_release_only_by_owner_and_drops_repo_label(self):
        fake = FakeGh(["in progress", "claim:claude/s1"])
        self.assertEqual(run_cli(fake, "release", "7", "--harness", "codex", "--session", "x")[0], 1)
        self.assertEqual(run_cli(fake, "release", "7", "--harness", "claude", "--session", "s1")[0], 0)
        self.assertEqual(fake.labels, [])
        self.assertTrue(any("claim%3Aclaude%2Fs1" in d for d in fake.repo_labels_deleted))

    def test_status_and_generated_session(self):
        code, out = run_cli(FakeGh(["in progress", "claim:antigravity/z"]), "status", "7")
        self.assertEqual((code, out["harness"], out["session"], out["owned"]), (0, "antigravity", "z", True))
        self.assertEqual(len(ic.resolve_session("codex", None, {})), 12)
        self.assertEqual(ic.resolve_session("codex", None, {"CODEX_SESSION_ID": "Q 1"}), "q-1")
        self.assertLessEqual(len(ic.claim_label("antigravity", ic.resolve_session("antigravity", "x" * 80, {}))), 50)

    def test_events_api_lag_is_retried_until_own_event_shows(self):
        ic.EVENT_RETRY_SECONDS = 0
        self.addCleanup(setattr, ic, "EVENT_RETRY_SECONDS", 1.0)
        fake = FakeGh()
        fake.lag = [2, 1]  # our two new events are hidden on the first reads
        code, _ = run_cli(fake, "claim", "1", "--harness", "claude", "--session", "a")
        self.assertEqual(code, 0)
        self.assertEqual(fake.event_reads, 3)

    def test_missing_own_event_backs_off_when_another_claim_exists(self):
        ic.EVENT_RETRY_SECONDS = 0
        self.addCleanup(setattr, ic, "EVENT_RETRY_SECONDS", 1.0)
        fake = FakeGh(["in progress", "claim:codex/z"])
        self.stale_first_read()
        fake.lag = [9] * ic.EVENT_RETRIES
        code, _ = run_cli(fake, "claim", "1", "--harness", "claude", "--session", "a")
        self.assertEqual(code, 1)
        self.assertEqual(sorted(fake.labels), ["claim:codex/z", "in progress"])

    def test_ensure_label_only_ignores_already_exists(self):
        def bad(args):
            raise ic.ClaimError("gh api failed: 422 Validation Failed invalid color")
        with self.assertRaises(ic.ClaimError):
            ic.ensure_label(bad, "o/r", "claim:x/y")


if __name__ == "__main__":
    unittest.main()
