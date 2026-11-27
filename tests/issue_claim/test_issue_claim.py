import io
import itertools
import json
import re
import sys
import tempfile
import unittest
import urllib.parse
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import agent_names  # noqa: E402
import issue_claim as ic  # noqa: E402

TITLE = "Show the held advance"


class FakeGh:
    """In-memory GitHub for one issue: labels plus the server's labeled-event log."""

    def __init__(self, labels=()):
        self.labels = []
        self.events = []
        self.repo_labels_deleted = []
        self.event_reads = 0
        self.other_open = []  # label lists of other open in-progress issues
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
        if "issues?state=open" in joined:
            return "\n".join(json.dumps(labels) for labels in self.other_open)
        if args[-1] == ".title":
            return TITLE + "\n"
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


class FakeRepo:
    """Routes calls to one FakeGh per issue/PR number (PRs share the issues API)."""

    def __init__(self, **items):
        self.items = {int(k[1:]): v for k, v in items.items()}  # i10=..., p20=...

    def __call__(self, args):
        match = re.search(r"/issues/(\d+)", " ".join(args))
        target = self.items[int(match.group(1))] if match else next(iter(self.items.values()))
        return target(args)


STATE_DIR = tempfile.TemporaryDirectory()
STATE_NUMBERS = itertools.count()


def run_cli(fake, *argv, model="claude-sonnet-5-5", state=None):
    if state is None:  # one throwaway reservation file per fake GitHub
        if not hasattr(fake, "state_path"):  # not id(fake): ids are reused after GC
            fake.state_path = Path(STATE_DIR.name) / f"{next(STATE_NUMBERS)}.json"
        state = fake.state_path
    env = {"AGENT_NAMES_STATE": str(state), **({"AGENT_MODEL": model} if model else {})}
    out = io.StringIO()
    with redirect_stdout(out), redirect_stderr(io.StringIO()):
        code = ic.main([*argv, "--json"], run=fake, env=env)
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
        self.assertEqual(sorted(fake.labels), ["agent:Alparslan", "claim:claude/abc-123", "in progress"])
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
        self.assertEqual(sorted(fake.labels), ["agent:Alparslan", "claim:codex/s9", "in progress"])

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

class PullRequestLabelTests(unittest.TestCase):
    def repo(self, issue=(), pr=()):
        return FakeRepo(i10=FakeGh(issue), p20=FakeGh(pr))

    def test_sync_copies_both_labels_to_the_pr(self):
        repo = self.repo(["in progress", "claim:claude/abc"])
        code, out = run_cli(repo, "sync", "10", "--pr", "20")
        self.assertEqual(code, 0, out)
        self.assertEqual(sorted(repo.items[20].labels), ["claim:claude/abc", "in progress"])

    def test_sync_is_idempotent(self):
        repo = self.repo(["in progress", "claim:claude/abc"], ["in progress", "claim:claude/abc"])
        self.assertEqual(run_cli(repo, "sync", "10", "--pr", "20")[0], 0)
        self.assertEqual(len(repo.items[20].labels), 2)

    def test_sync_needs_a_claimed_issue(self):
        repo = self.repo(["in progress"])
        code, out = run_cli(repo, "sync", "10", "--pr", "20")
        self.assertEqual(code, 1, out)
        self.assertEqual(repo.items[20].labels, [])

    def test_sync_refuses_a_pr_owned_by_someone_else(self):
        repo = self.repo(["in progress", "claim:claude/abc"], ["in progress", "claim:codex/zzz"])
        code, _ = run_cli(repo, "sync", "10", "--pr", "20")
        self.assertEqual(code, 1)
        self.assertIn("claim:codex/zzz", repo.items[20].labels)
        self.assertNotIn("claim:claude/abc", repo.items[20].labels)

    def test_sync_requires_pr_argument(self):
        with redirect_stderr(io.StringIO()):
            code = ic.main(["sync", "10"], run=self.repo(["in progress", "claim:claude/abc"]), env={})
        self.assertEqual(code, 2)

    def test_claim_with_pr_labels_both(self):
        repo = self.repo()
        code, out = run_cli(repo, "claim", "10", "--harness", "claude", "--session", "abc", "--pr", "20")
        self.assertEqual(code, 0, out)
        for number in (10, 20):
            self.assertEqual(sorted(repo.items[number].labels), ["agent:Alparslan", "claim:claude/abc", "in progress"])

    def test_release_with_pr_clears_both(self):
        both = ["in progress", "claim:claude/abc"]
        repo = self.repo(both, both)
        code, out = run_cli(repo, "release", "10", "--harness", "claude", "--session", "abc", "--pr", "20")
        self.assertEqual(code, 0, out)
        self.assertEqual(repo.items[10].labels, [])
        self.assertEqual(repo.items[20].labels, [])

    def test_release_with_pr_by_non_owner_changes_nothing(self):
        both = ["in progress", "claim:codex/zzz"]
        repo = self.repo(both, both)
        code, _ = run_cli(repo, "release", "10", "--harness", "claude", "--session", "abc", "--pr", "20")
        self.assertEqual(code, 1)
        self.assertEqual(len(repo.items[20].labels), 2)


class AgentNameTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.state = Path(tmp.name) / "names.json"
        self.roster = agent_names.load_roster()

    def reserve(self, session, model="claude-sonnet-5-5", **kwargs):
        return agent_names.reserve(self.state, "claude", session, model, **kwargs)["name"]

    def first_name(self, model):
        return agent_names.family_of(self.roster, model)["names"][0]

    def test_each_model_has_its_bound_names(self):
        expected = {
            "claude-fable-5-2": "Fatih Sultan Mehmet", "claude-opus-5-5[1m]": "Yavuz Sultan Selim",
            "Sonnet 5.5": "Alparslan", "claude-haiku-5-5": "Ulubatlı Hasan",
            "gpt-6.2-astra": "Metehan", "GPT-6.2 Sol": "Melikşah", "gpt-6.1-sol": "Tuğrul Bey",
            "gemini-ultra": "Gazneli Mahmud", "gemini-4-neon": "Çelebi Mehmet",
            "gemini-4-carbon": "Danişmend Gazi", "gemini-4-argon": "Cezzar Ahmed Paşa",
            "gemini-4-hydrogen": "Mihaloğlu Ali Bey", "gemini-nano": "Çete Emir Ayşe",
            "gemini-3.1-pro": "Baybars", "Gemini 3.8 Flash": "Kuşçubaşı Eşref",
            "deepseek/deepseek-chat": "Piri Reis",
        }
        self.assertEqual({m: self.first_name(m) for m in expected}, expected)

    def test_later_gpt_version_does_not_inherit_the_6_2_names(self):
        self.assertEqual(self.first_name("gpt-6.20-sol"), "Tuğrul Bey")

    def test_model_spellings_share_one_name(self):
        self.assertEqual([self.reserve("a", "sonnet"), self.reserve("a")], ["Alparslan", "Alparslan"])
        self.assertEqual([e["model"] for e in agent_names.read_state(self.state)], ["claude-sonnet-5-5"])

    def test_model_switch_moves_the_issue_to_the_new_name(self):
        self.reserve("a", issue=1)
        self.assertEqual(self.reserve("a", "opus", issue=1), "Yavuz Sultan Selim")
        self.assertEqual([(e["name"], e["issues"]) for e in agent_names.read_state(self.state)],
                         [("Yavuz Sultan Selim", [1])])

    def test_lock_excludes_a_second_holder(self):
        self.addCleanup(setattr, agent_names, "LOCK_TIMEOUT_SECONDS", agent_names.LOCK_TIMEOUT_SECONDS)
        agent_names.LOCK_TIMEOUT_SECONDS = 0.1
        with agent_names.locked(self.state):
            with self.assertRaises(agent_names.RosterError):
                self.reserve("a")
        self.assertEqual(self.reserve("a"), "Alparslan")

    def test_every_model_has_five_names_that_no_other_model_uses(self):
        self.assertNotIn("pool", self.roster)
        self.assertTrue(all(len(m["names"]) >= 5 for m in self.roster["models"]))
        names = [n for m in self.roster["models"] for n in m["names"]]
        self.assertEqual(len(names), len(set(names)))
        self.assertTrue(all(len(agent_names.label_for(f"{n} 99")) <= ic.MAX_LABEL for n in names))

    def test_concurrent_agents_use_all_family_names_before_numbering(self):
        got = [self.reserve(str(i)) for i in range(6)]
        self.assertEqual(got, [*agent_names.family_of(self.roster, "sonnet")["names"], "Alparslan 2"])
        self.assertEqual(self.reserve("0"), "Alparslan")

    def test_unlisted_model_is_refused_before_github_is_touched(self):
        fake = FakeGh()
        with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
            code = ic.main(["claim", "7", "--harness", "claude", "--session", "a", "--model", "mystery-1"],
                           run=fake, env={"AGENT_NAMES_STATE": str(self.state)})
        self.assertEqual((code, fake.labels, agent_names.read_state(self.state)), (2, [], []))

    def test_name_used_elsewhere_is_skipped(self):
        self.assertEqual(self.reserve("b", taken_elsewhere={"Alparslan"}), "Kılıç Arslan")

    def test_release_frees_name_only_after_last_issue(self):
        self.reserve("a", issue=1)
        self.reserve("a", issue=2)
        self.assertEqual(agent_names.release(self.state, "claude", "a", issue=1), [])
        self.assertEqual(agent_names.release(self.state, "claude", "a", issue=2), ["Alparslan"])
        self.assertEqual(self.reserve("b"), "Alparslan")

    def test_idle_reservation_expires_but_issue_holder_stays(self):
        later = agent_names.now_utc() + agent_names.IDLE_TTL
        self.reserve("idle")
        self.reserve("busy", issue=1)
        self.assertEqual(self.reserve("new", now=later), "Alparslan")

    def test_corrupt_state_is_not_overwritten_and_github_is_untouched(self):
        self.state.write_text("{broken")
        fake = FakeGh()
        out = io.StringIO()
        with redirect_stderr(out), redirect_stdout(io.StringIO()):
            code = ic.main(["claim", "7", "--harness", "claude", "--session", "a", "--model", "opus"],
                           run=fake, env={"AGENT_NAMES_STATE": str(self.state)})
        self.assertEqual((code, fake.labels, self.state.read_text()), (2, [], "{broken"))

    def test_claim_requires_a_model(self):
        fake = FakeGh()
        with redirect_stderr(io.StringIO()):
            code = ic.main(["claim", "7", "--harness", "claude", "--session", "a"],
                           run=fake, env={"AGENT_NAMES_STATE": str(self.state)})
        self.assertEqual((code, fake.labels), (2, []))

    def test_claim_reports_title_and_avoids_names_on_other_open_issues(self):
        fake = FakeGh()
        fake.other_open = [["in progress", "claim:claude/other-machine", "agent:Alparslan"]]
        code, out = run_cli(fake, "claim", "7", "--harness", "claude", "--session", "a", state=self.state)
        self.assertEqual((code, out["agent"], out["session_title"]),
                         (0, "Kılıç Arslan", f"[Kılıç Arslan] #7 {TITLE}"))
        self.assertIn("agent:Kılıç Arslan", fake.labels)
        run_cli(fake, "release", "7", "--harness", "claude", "--session", "a", state=self.state)
        self.assertEqual((fake.labels, agent_names.read_state(self.state)), ([], []))

    def test_refused_claim_reserves_nothing(self):
        fake = FakeGh(["in progress", "claim:codex/x", "agent:Melikşah"])
        code, _ = run_cli(fake, "claim", "7", "--harness", "claude", "--session", "a", state=self.state)
        self.assertEqual((code, agent_names.read_state(self.state)), (1, []))

    def test_force_takeover_replaces_label_and_frees_previous_name(self):
        fake = FakeGh()
        run_cli(fake, "claim", "7", "--harness", "claude", "--session", "a", state=self.state)
        run_cli(fake, "claim", "7", "--harness", "codex", "--session", "b", "--force",
                model="gpt-6.2-sol", state=self.state)
        self.assertEqual(sorted(fake.labels), ["agent:Melikşah", "claim:codex/b", "in progress"])
        self.assertEqual([e["name"] for e in agent_names.read_state(self.state)], ["Melikşah"])

    def test_state_directory_ignores_itself(self):
        state = self.state.parent / agent_names.STATE_RELATIVE
        agent_names.reserve(state, "claude", "a", "opus")
        self.assertEqual((state.parent / ".gitignore").read_text(), "*\n")

    def test_long_session_title_is_truncated(self):
        title = agent_names.session_title("Alparslan", 1, "x" * 200)
        self.assertEqual(len(title), agent_names.TITLE_MAX)


class HandoverTransferTests(unittest.TestCase):
    def owned(self, *extra, session="s1", harness="claude"):
        return FakeGh(["in progress", f"claim:{harness}/{session}", "agent:Alparslan", *extra])

    def transfer(self, fake, *extra, model="gpt-6.2-sol", **kw):
        return run_cli(fake, "transfer", "7", "--harness", "claude", "--session", "s1",
                       "--to-harness", "codex", "--to-session", "c9", "--to-model", model, *extra, **kw)

    def test_transfer_swaps_claim_and_agent_and_records_count(self):
        fake = self.owned()
        code, out = self.transfer(fake)
        self.assertEqual(code, 0, out)
        self.assertIn("claim:codex/c9", fake.labels)
        self.assertNotIn("claim:claude/s1", fake.labels)
        self.assertNotIn("agent:Alparslan", fake.labels)
        self.assertTrue(any(l.startswith("agent:") for l in fake.labels))
        self.assertIn("in progress", fake.labels)
        self.assertIn("handover:count-1", fake.labels)
        self.assertIn("handover:pending", fake.labels)
        self.assertEqual(out["handover_count"], 1)

    def test_new_claim_lands_before_old_is_removed(self):
        fake = self.owned()
        order = []
        real_add, real_remove = ic.add_labels, ic.remove_label
        ic.add_labels = lambda run, repo, n, names: (order.append(("add", list(names))), real_add(run, repo, n, names))[1]
        ic.remove_label = lambda run, repo, n, name: (order.append(("remove", name)), real_remove(run, repo, n, name))[1]
        self.addCleanup(setattr, ic, "add_labels", real_add)
        self.addCleanup(setattr, ic, "remove_label", real_remove)
        self.assertEqual(self.transfer(fake)[0], 0)
        first_add = next(i for i, (k, v) in enumerate(order) if k == "add" and "claim:codex/c9" in v)
        old_removed = next(i for i, (k, v) in enumerate(order) if k == "remove" and v == "claim:claude/s1")
        self.assertLess(first_add, old_removed)

    def test_non_owner_cannot_transfer_without_force(self):
        fake = self.owned(session="other")
        code, out = self.transfer(fake)
        self.assertEqual(code, 1)
        self.assertIn("claim:claude/other", fake.labels)
        self.assertNotIn("claim:codex/c9", fake.labels)

    def test_unclaimed_issue_cannot_be_transferred(self):
        self.assertEqual(self.transfer(FakeGh())[0], 1)

    def test_max_handovers_is_enforced(self):
        fake = self.owned("handover:count-3")
        code, out = self.transfer(fake)
        self.assertEqual(code, 1)
        self.assertIn("MAX_HANDOVERS", out["message"])
        self.assertIn("claim:claude/s1", fake.labels)
        self.assertEqual(out["handover_count"], 3)

    def test_count_increments_and_old_count_label_is_replaced(self):
        fake = self.owned("handover:count-1")
        self.assertEqual(self.transfer(fake)[0], 0)
        self.assertIn("handover:count-2", fake.labels)
        self.assertNotIn("handover:count-1", fake.labels)

    def test_unlisted_model_fails_before_touching_github(self):
        fake = self.owned()
        err = io.StringIO()
        with redirect_stderr(err), redirect_stdout(io.StringIO()):
            code = ic.main(["transfer", "7", "--harness", "claude", "--session", "s1", "--to-harness", "codex",
                            "--to-session", "c9", "--to-model", "mystery-model", "--json"],
                           run=fake, env={"AGENT_NAMES_STATE": str(Path(STATE_DIR.name) / "unlisted.json")})
        self.assertEqual(code, 2)
        self.assertEqual(sorted(fake.labels), ["agent:Alparslan", "claim:claude/s1", "in progress"])

    def test_pr_is_transferred_too(self):
        issue = self.owned()
        pr = self.owned()
        fake = FakeRepo(i7=issue, p8=pr)
        fake.state_path = Path(STATE_DIR.name) / "transfer-pr.json"
        code, _ = run_cli(fake, "transfer", "7", "--harness", "claude", "--session", "s1", "--to-harness", "codex",
                          "--to-session", "c9", "--to-model", "gpt-6.2-sol", "--pr", "8", state=fake.state_path)
        self.assertEqual(code, 0)
        for target in (issue, pr):
            self.assertIn("claim:codex/c9", target.labels)
            self.assertNotIn("claim:claude/s1", target.labels)
            self.assertIn("handover:count-1", target.labels)

    def test_accept_clears_pending_for_new_owner_only(self):
        fake = FakeGh(["in progress", "claim:codex/c9", "handover:pending", "handover:count-1"])
        code, _ = run_cli(fake, "accept", "7", "--harness", "claude", "--session", "s1")
        self.assertEqual(code, 1)
        self.assertIn("handover:pending", fake.labels)
        code, _ = run_cli(fake, "accept", "7", "--harness", "codex", "--session", "c9")
        self.assertEqual(code, 0)
        self.assertNotIn("handover:pending", fake.labels)
        self.assertIn("handover:count-1", fake.labels)

    def test_release_clears_handover_labels(self):
        fake = FakeGh(["in progress", "claim:codex/c9", "agent:Melikşah", "handover:pending", "handover:count-2"])
        code, _ = run_cli(fake, "release", "7", "--harness", "codex", "--session", "c9")
        self.assertEqual(code, 0)
        self.assertEqual(fake.labels, [])


if __name__ == "__main__":
    unittest.main()
