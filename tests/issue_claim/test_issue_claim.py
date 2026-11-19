import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import issue_claim as ic  # noqa: E402


class FakeGh:
    """In-memory GitHub label store for one issue."""

    def __init__(self, labels):
        self.labels = list(labels)

    def __call__(self, args):
        if args[0] == "repo":
            return "o/r\n"
        if len(args) > 1 and "issues?state=all" in args[1]:
            return "0"
        if args[:1] == ["api"] and "--jq" in args:
            return json.dumps(self.labels)
        if "-X" in args and args[args.index("-X") + 1] == "DELETE":
            name = args[-1].rsplit("/labels/", 1)[1].replace("%20", " ").replace("%3A", ":")
            if "/issues/" not in args[-1]:
                return ""  # repo-level label deletion
            if name not in self.labels:
                raise ic.ClaimError("404")
            self.labels.remove(name)
            return ""
        if args[-1].startswith("labels[]=") or any(a.startswith("labels[]=") for a in args):
            self.labels += [a.split("=", 1)[1] for a in args if a.startswith("labels[]=")]
            return ""
        return ""  # label creation


def run_cli(fake, *argv):
    out = io.StringIO()
    with redirect_stdout(out):
        code = ic.main([*argv, "--json"], run=fake, env={})
    return code, json.loads(out.getvalue())


class IssueClaimTests(unittest.TestCase):
    def test_claim_adds_three_labels(self):
        fake = FakeGh([])
        code, out = run_cli(fake, "claim", "7", "--harness", "Claude", "--session", "abc 123")
        self.assertEqual(code, 0)
        self.assertEqual(sorted(fake.labels), ["harness:claude", "in progress", "session:abc-123"])
        self.assertEqual(out["session"], "abc-123")

    def test_other_session_is_refused(self):
        fake = FakeGh(["in progress", "harness:codex", "session:s1"])
        code, out = run_cli(fake, "claim", "7", "--harness", "claude", "--session", "s2")
        self.assertEqual(code, 1)
        self.assertIn("codex/s1", out["message"])
        self.assertIn("harness:codex", fake.labels)

    def test_bare_in_progress_is_refused(self):
        fake = FakeGh(["in progress"])
        code, _ = run_cli(fake, "claim", "7", "--harness", "claude", "--session", "s2")
        self.assertEqual(code, 1)

    def test_same_session_reclaim_ok_and_force_takes_over(self):
        fake = FakeGh(["in progress", "harness:claude", "session:s1"])
        self.assertEqual(run_cli(fake, "claim", "7", "--harness", "claude", "--session", "s1")[0], 0)
        code, _ = run_cli(fake, "claim", "7", "--harness", "codex", "--session", "s9", "--force")
        self.assertEqual(code, 0)
        self.assertEqual(sorted(fake.labels), ["harness:codex", "in progress", "session:s9"])

    def test_same_harness_race_keeps_exactly_one_winner(self):
        # Session "a" already won; "b" (same harness) loses and must not
        # strip the shared harness label or `in progress`.
        fake = FakeGh(["in progress", "harness:claude", "session:a"])
        real_read = ic.read_labels
        calls = {"n": 0}

        def racing(run, repo, number):
            calls["n"] += 1
            # first read: issue looked free to "b"
            return [] if calls["n"] == 1 else real_read(run, repo, number)

        ic.read_labels = racing
        try:
            code, out = run_cli(fake, "claim", "1", "--harness", "claude", "--session", "b")
        finally:
            ic.read_labels = real_read
        self.assertEqual(code, 1)
        self.assertIn("session a", out["message"])
        self.assertEqual(ic.parse_owner(fake.labels), ic.Owner(True, "claude", "a"))
        self.assertEqual(run_cli(fake, "release", "1", "--harness", "claude", "--session", "a")[0], 0)

    def test_smallest_session_wins_when_racing_claim_is_ours(self):
        fake = FakeGh(["in progress", "harness:claude", "session:b"])
        real_read = ic.read_labels
        calls = {"n": 0}

        def racing(run, repo, number):
            calls["n"] += 1
            return [] if calls["n"] == 1 else real_read(run, repo, number)

        ic.read_labels = racing
        try:
            code, _ = run_cli(fake, "claim", "1", "--harness", "claude", "--session", "a")
        finally:
            ic.read_labels = real_read
        self.assertEqual(code, 0)

    def test_ensure_label_only_ignores_already_exists(self):
        def bad(args):
            raise ic.ClaimError("gh api failed: 422 Validation Failed invalid color")
        with self.assertRaises(ic.ClaimError):
            ic.ensure_label(bad, "o/r", "session:x")

    def test_release_only_by_owner(self):
        fake = FakeGh(["in progress", "harness:claude", "session:s1"])
        self.assertEqual(run_cli(fake, "release", "7", "--harness", "codex", "--session", "x")[0], 1)
        self.assertEqual(run_cli(fake, "release", "7", "--harness", "claude", "--session", "s1")[0], 0)
        self.assertEqual(fake.labels, [])

    def test_status_and_generated_session(self):
        fake = FakeGh(["in progress", "harness:antigravity", "session:z"])
        code, out = run_cli(fake, "status", "7")
        self.assertEqual((code, out["harness"], out["session"], out["owned"]), (0, "antigravity", "z", True))
        self.assertEqual(len(ic.resolve_session("codex", None, {})), 12)
        self.assertEqual(ic.resolve_session("codex", None, {"CODEX_SESSION_ID": "Q 1"}), "q-1")


if __name__ == "__main__":
    unittest.main()
