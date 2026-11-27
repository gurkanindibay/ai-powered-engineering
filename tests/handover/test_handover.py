import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import handover as ho  # noqa: E402


def git(repo, *args, check=True):
    return subprocess.run(["git", "-c", "user.email=test@example.com", "-c", "user.name=Test", *args],
                          cwd=repo, check=check, capture_output=True, text=True)


def make_repo(path: Path) -> Path:
    path.mkdir(parents=True)
    git(path, "init", "--quiet", "-b", "main")
    (path / "README.md").write_text("base\n")
    git(path, "add", ".")
    git(path, "commit", "--quiet", "-m", "base")
    return path


class HandoverTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = make_repo(self.base / "repo")
        self.envelopes = self.base / "envelopes"

    def options(self, **overrides):
        values = dict(issue=7, reason="provider_quota_exhausted", pr=99, provider="claude",
                      harness="claude_code", model="claude-sonnet-5-5", agent_name="Alparslan",
                      session_id="s1", risk_tier="high", role="backend_developer",
                      excluded_providers=["claude"], root=self.envelopes)
        values.update(overrides)
        return ho.CaptureOptions(**values)

    def capture(self, **overrides):
        return ho.capture(self.repo, self.options(**overrides))

    def test_clean_worktree_capture_writes_a_valid_envelope(self):
        result = self.capture()
        path = Path(result["path"])
        self.assertEqual(path.name, "7-001.json")
        envelope, errors = ho.validate_file(path)
        self.assertEqual(errors, [])
        self.assertEqual(envelope["handover_id"], "ho-7-001")
        self.assertEqual(envelope["git_state"]["issue"], 7)
        self.assertEqual(envelope["git_state"]["pr"], 99)
        self.assertEqual(envelope["git_state"]["branch"], "main")
        self.assertEqual(envelope["git_state"]["head_sha"], git(self.repo, "rev-parse", "HEAD").stdout.strip())
        self.assertFalse(envelope["git_state"]["wip_committed"])
        self.assertEqual(envelope["from"]["agent_name"], "Alparslan")
        self.assertEqual(envelope["target_constraints"], {"risk_tier": "high", "role": "backend_developer",
                                                          "excluded_providers": ["claude"]})
        self.assertEqual(envelope["progress"]["last_verification"]["status"], "unverified")
        self.assertLessEqual(ho.envelope_bytes(envelope), ho.MAX_ENVELOPE_BYTES)
        self.assertTrue(envelope["created_at"].endswith("Z"))

    def test_dirty_capture_commits_only_safe_paths_and_marks_unverified(self):
        (self.repo / "src").mkdir()
        (self.repo / "src" / "app.py").write_text("VALUE = 1\n")
        (self.repo / ".env").write_text("SECRET=1\n")
        (self.repo / "certs").mkdir()
        (self.repo / "certs" / "server.pem").write_text("key\n")
        result = self.capture()
        self.assertTrue(result["wip"].committed)
        self.assertEqual(git(self.repo, "log", "-1", "--format=%s").stdout.strip(),
                         "wip/handover-001: provider_quota_exhausted checkpoint")
        committed = git(self.repo, "show", "--pretty=format:", "--name-only", "HEAD").stdout.split()
        self.assertEqual(committed, ["src/app.py"])
        self.assertIn("?? .env", git(self.repo, "status", "--porcelain").stdout)
        self.assertEqual(sorted(result["protected"]), [".env", "certs/server.pem"])
        envelope = result["envelope"]
        self.assertTrue(envelope["git_state"]["wip_committed"])
        self.assertEqual(envelope["git_state"]["head_sha"], git(self.repo, "rev-parse", "HEAD").stdout.strip())
        self.assertEqual(envelope["git_state"]["base_sha"], git(self.repo, "rev-parse", "HEAD~1").stdout.strip())
        self.assertEqual(envelope["progress"]["last_verification"]["status"], "unverified")
        self.assertIn("Not captured (protected path): .env", envelope["progress"]["remaining"])
        self.assertFalse(any(".env" in pointer for pointer in envelope["key_pointers"]))
        self.assertEqual(ho.validate_envelope(envelope), [])

    def test_pre_staged_protected_file_is_never_committed(self):
        (self.repo / "src").mkdir()
        (self.repo / "src" / "app.py").write_text("VALUE = 1\n")
        (self.repo / ".env").write_text("SECRET=1\n")
        git(self.repo, "add", ".env")  # the normal crash state after `git add -A`
        result = self.capture()
        self.assertTrue(result["wip"].committed)
        committed = git(self.repo, "show", "--pretty=format:", "--name-only", "HEAD").stdout.split()
        self.assertEqual(committed, ["src/app.py"])
        self.assertIn("A  .env", git(self.repo, "status", "--porcelain").stdout)

    def test_failed_commit_falls_back_to_a_patch(self):
        (self.repo / "src").mkdir()
        (self.repo / "src" / "app.py").write_text("VALUE = 1\n")
        hook = self.repo / ".git" / "hooks" / "pre-commit"
        hook.write_text("#!/bin/sh\nexit 1\n")
        os.chmod(hook, 0o755)
        result = self.capture()
        self.assertFalse(result["wip"].committed)
        patch = Path(result["wip"].patch)
        self.assertTrue(patch.is_file())
        self.assertIn("src/app.py", patch.read_text())
        self.assertFalse(result["envelope"]["git_state"]["wip_committed"])
        self.assertEqual(ho.validate_file(Path(result["path"]))[1], [])

    def test_sequence_increments_and_never_overwrites(self):
        first = self.capture()
        second = self.capture()
        self.assertEqual(Path(first["path"]).name, "7-001.json")
        self.assertEqual(Path(second["path"]).name, "7-002.json")
        with self.assertRaises(ho.HandoverError) as caught:
            self.capture(seq=1)
        self.assertIn("already exists", str(caught.exception))

    def test_oversized_input_is_trimmed_to_the_cap(self):
        remaining = [f"step {index} " + "x" * 200 for index in range(500)]
        result = self.capture(remaining=remaining)
        envelope = result["envelope"]
        self.assertLessEqual(ho.envelope_bytes(envelope), ho.MAX_ENVELOPE_BYTES)
        self.assertLess(len(envelope["progress"]["remaining"]), len(remaining))
        self.assertEqual(ho.validate_envelope(envelope), [])

    def test_validation_catches_tampering_missing_fields_and_oversized_files(self):
        result = self.capture()
        tampered = json.loads(json.dumps(result["envelope"]))
        tampered["progress"]["completed"].append("trust me")
        self.assertIn("checksum", ho.validate_envelope(tampered)[0])
        missing = json.loads(json.dumps(result["envelope"]))
        del missing["reason"]
        self.assertIn("missing fields", ho.validate_envelope(missing)[0])
        oversize = Path(result["path"])
        oversize.write_text(oversize.read_text() + " " * (ho.MAX_ENVELOPE_BYTES + 1))
        self.assertIn("cap", ho.validate_file(oversize)[1][0])

    def test_render_escapes_content_and_refuses_invalid_envelopes(self):
        result = self.capture()
        envelope = json.loads(json.dumps(result["envelope"]))
        envelope["progress"]["completed"] = ["<script>alert(1)</script>"]
        envelope["checksum_sha256"] = ho.checksum(envelope)
        body = ho.render(envelope)
        self.assertTrue(body.startswith("<details>"))
        self.assertIn("&lt;script&gt;", body)
        self.assertNotIn("<script>alert", body)
        broken = json.loads(json.dumps(envelope))
        broken["progress"]["completed"].append("changed")
        with self.assertRaises(ho.HandoverError):
            ho.render(broken)

    def test_cli_capture_validate_and_post_summary(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = ho.main(["capture", "--issue", "11", "--json", "--worktree", str(self.repo),
                            "--root", str(self.envelopes)])
        self.assertEqual(code, 0)
        payload = json.loads(out.getvalue())
        self.assertTrue(payload["ok"])
        path = Path(payload["path"])
        self.assertTrue(path.is_file())
        with redirect_stdout(io.StringIO()) as validated:
            self.assertEqual(ho.main(["validate", str(path), "--json"]), 0)
        self.assertTrue(json.loads(validated.getvalue())["ok"])

        posted = {}

        def runner(args, stdin):
            posted["args"], posted["body"] = args, stdin
            return ""

        with redirect_stdout(io.StringIO()):
            self.assertEqual(ho.main(["render", str(path), "--post-pr", "553"], runner=runner), 0)
        self.assertEqual(posted["args"], ["pr", "comment", "553", "--body-file", "-"])
        self.assertIn("ho-11-001", posted["body"])

    def test_cli_rejects_invalid_envelope_and_unconfirmed_export(self):
        result = self.capture()
        broken = Path(result["path"])
        data = json.loads(broken.read_text())
        data["reason"] = "not-a-reason"
        broken.write_text(json.dumps(data))
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(ho.main(["validate", str(broken)]), 1)
            self.assertEqual(ho.main(["export-t3", "--candidate", str(self.repo), "--branch", "main",
                                      "--issue", "7", "--repo", str(self.repo)]), 1)
        self.assertFalse(any(self.envelopes.glob("7-002.json")))


class ExportT3Test(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.origin = self.base / "origin.git"
        subprocess.run(["git", "init", "--bare", "--quiet", str(self.origin)], check=True)
        self.repo = make_repo(self.base / "repo")
        git(self.repo, "remote", "add", "origin", str(self.origin))
        git(self.repo, "checkout", "--quiet", "-b", "feature/handover")
        (self.repo / "src").mkdir()
        (self.repo / "src" / "base.py").write_text("BASE = 1\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "--quiet", "-m", "branch base")
        git(self.repo, "push", "--quiet", "-u", "origin", "feature/handover")
        git(self.repo, "checkout", "--quiet", "main")
        self.candidate = make_repo(self.base / "candidate")
        (self.candidate / "src").mkdir()
        (self.candidate / "src" / "app.py").write_text("VALUE = 2\n")
        self.envelopes = self.base / "envelopes"

    def export(self, **overrides):
        values = dict(candidate=self.candidate, branch="feature/handover", issue=12, pr=553,
                      repo=self.repo, child_cancelled=True, push=True, root=self.envelopes,
                      provider="t3", harness="t3", model="deepseek-flash",
                      thread_id="thread-1", child_id="child-1")
        values.update(overrides)
        return ho.export_t3(ho.ExportOptions(**values))

    def test_export_is_refused_until_the_child_is_confirmed_cancelled(self):
        with self.assertRaises(ho.HandoverError):
            self.export(child_cancelled=False)
        self.assertFalse(self.envelopes.exists())

    def test_export_pushes_candidate_changes_onto_the_pr_branch(self):
        result = self.export()
        self.assertTrue(result["pushed"])
        git(self.repo, "fetch", "--quiet", "origin")
        self.assertEqual(git(self.repo, "show", "origin/feature/handover:src/app.py").stdout,
                         "VALUE = 2\n")
        candidate_head = git(self.candidate, "rev-parse", "HEAD").stdout.strip()
        subject = git(self.repo, "log", "-1", "--format=%s", "origin/feature/handover").stdout.strip()
        self.assertEqual(subject, f"wip/handover-001: export T3 candidate {candidate_head[:7]}")
        envelope, errors = ho.validate_file(Path(result["path"]))
        self.assertEqual(errors, [])
        self.assertEqual(envelope["git_state"]["branch"], "feature/handover")
        self.assertEqual(envelope["git_state"]["head_sha"], result["head_sha"])
        self.assertTrue(envelope["git_state"]["wip_committed"])
        self.assertEqual(envelope["t3_context"]["child_id"], "child-1")
        self.assertTrue(envelope["t3_context"]["child_cancelled"])
        self.assertNotIn("README.md", envelope["key_pointers"] + envelope["progress"]["completed"])
        # The temporary export worktree is gone again.
        worktrees = git(self.repo, "worktree", "list", "--porcelain").stdout
        self.assertEqual(worktrees.count("worktree "), 1)

    def test_export_refuses_candidate_history_with_protected_paths(self):
        before = git(self.repo, "rev-parse", "feature/handover").stdout.strip()
        (self.candidate / ".env").write_text("SECRET=1\n")
        git(self.candidate, "add", "-A")
        git(self.candidate, "commit", "--quiet", "-m", "leak a credential")
        with self.assertRaises(ho.HandoverError) as caught:
            self.export()
        self.assertIn(".env", str(caught.exception))
        self.assertEqual(git(self.repo, "rev-parse", "feature/handover").stdout.strip(), before)
        self.assertFalse(self.envelopes.exists())

    def test_local_export_updates_the_branch_without_pushing(self):
        result = self.export(push=False)
        self.assertFalse(result["pushed"])
        self.assertEqual(git(self.repo, "show", "feature/handover:src/app.py").stdout, "VALUE = 2\n")
        self.assertEqual(git(self.repo, "rev-parse", "feature/handover").stdout.strip(), result["head_sha"])

    def test_export_uses_the_pr_branch_base_when_the_candidate_root_differs(self):
        candidate = self.base / "candidate-different"
        candidate.mkdir()
        git(candidate, "init", "--quiet", "-b", "main")
        (candidate / "README.md").write_text("different candidate base\n")
        git(candidate, "add", ".")
        git(candidate, "commit", "--quiet", "-m", "candidate root")
        (candidate / "src").mkdir()
        (candidate / "src" / "app.py").write_text("VALUE = 3\n")
        branch_base = git(self.repo, "rev-parse", "feature/handover").stdout.strip()
        self.assertNotEqual(git(candidate, "rev-list", "--max-parents=0", "HEAD").stdout.strip(),
                            git(self.repo, "rev-list", "--max-parents=0", "HEAD").stdout.strip())
        result = self.export(candidate=candidate, push=False)
        envelope, errors = ho.validate_file(Path(result["path"]))
        self.assertEqual(errors, [])
        self.assertEqual(envelope["git_state"]["base_sha"], branch_base)
        self.assertEqual(envelope["git_state"]["head_sha"], result["head_sha"])


if __name__ == "__main__":
    unittest.main()
