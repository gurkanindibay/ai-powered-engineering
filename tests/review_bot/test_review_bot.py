import argparse
import contextlib
import io
import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import review_bot as rb  # noqa: E402

NOW = 1_800_000_000


def _decode(part: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


class FakeHttp:
    def __init__(self, head="abc123def456"):
        self.calls = []
        self.head = head
        self.token_mints = 0
        self.repo_visible = True
        self.revoked = set()

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, headers, json.loads(body) if body else None))
        token = headers["Authorization"].removeprefix("token ")
        if token in self.revoked:
            return 401, {"message": "Bad credentials"}
        if url.endswith("/access_tokens"):
            self.token_mints += 1
            return 201, {"token": f"ghs_{self.token_mints}", "expires_at": "2027-01-15T09:00:00Z"}
        if "/pulls/" in url and url.endswith("/reviews"):
            return 200, {"id": 9, "state": "APPROVED", "html_url": "https://x/r/9"}
        if "/pulls/" in url:
            return 200, {"head": {"sha": self.head}}
        if url.endswith("/comments"):
            return 201, {"id": 7, "html_url": "https://x/c/7"}
        if url.endswith("/app"):
            return 200, {"slug": "local-reviewer-agent", "id": 42, "permissions": {"pull_requests": "write"}}
        if url.endswith("/repos/o/r"):
            return (200, {"full_name": "o/r"}) if self.repo_visible else (404, {"message": "Not Found"})
        return 404, {"message": "Not Found"}


class KeyCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.key = self.dir / "key.pem"
        self.key.write_text("not a real key")
        os.chmod(self.key, 0o600)
        self.cfg = rb.Config("42", "184", self.key, "o/r")

    def tearDown(self):
        self.tmp.cleanup()

    def bot(self, http=None, cache=False):
        return rb.Bot(self.cfg, http or FakeHttp(), signer=lambda m, k: b"sig",
                      cache_dir=self.dir / "cache" if cache else None, now=lambda: NOW)


class JwtTest(KeyCase):
    def test_claims_allow_clock_drift_and_stay_under_ten_minutes(self):
        header, payload, sig = rb.build_jwt("42", self.key, NOW, signer=lambda m, k: b"sig").split(".")
        self.assertEqual(_decode(header), {"alg": "RS256", "typ": "JWT"})
        self.assertEqual(_decode(payload), {"iat": NOW - 60, "exp": NOW + 540, "iss": "42"})
        self.assertEqual(sig, rb._b64url(b"sig"))

    def test_openssl_signature_verifies(self):
        key = self.dir / "real.pem"
        pub = self.dir / "real.pub"
        subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"], check=True, capture_output=True)
        subprocess.run(["openssl", "rsa", "-in", str(key), "-pubout", "-out", str(pub)], check=True, capture_output=True)
        token = rb.build_jwt("42", key, NOW)
        header, payload, sig = token.split(".")
        sig_file = self.dir / "sig"
        sig_file.write_bytes(base64.urlsafe_b64decode(sig + "=" * (-len(sig) % 4)))
        proc = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(pub), "-signature", str(sig_file)],
                              input=f"{header}.{payload}".encode(), capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)


class ConfigTest(KeyCase):
    def ns(self, **kw):
        return argparse.Namespace(app_id=None, installation_id=None, key=None, repo=None, **kw)

    def env(self, **kw):
        return {"REVIEW_BOT_ENV": str(self.dir / "none.env"), **kw}

    def test_flags_beat_env_beat_dotenv(self):
        dotenv = self.dir / "x.env"
        dotenv.write_text(f"# bot\nexport REVIEW_BOT_APP_ID=file\nREVIEW_BOT_INSTALLATION_ID='file'\n"
                          f"REVIEW_BOT_KEY={self.key}\nREVIEW_BOT_REPO=\"file/repo\"\n")
        env = {"REVIEW_BOT_ENV": str(dotenv), "REVIEW_BOT_APP_ID": "env"}
        args = self.ns()
        args.installation_id = "flag"
        cfg = rb.load_config(args, env)
        self.assertEqual((cfg.app_id, cfg.installation_id, cfg.repo), ("env", "flag", "file/repo"))

    def test_dotenv_inline_comments_and_quotes(self):
        parsed = rb.parse_dotenv("A=1 # app id\nB='x # kept'\n# C=3\nD\n")
        self.assertEqual(parsed, {"A": "1", "B": "x # kept"})

    def test_missing_app_id_is_reported(self):
        env = self.env(REVIEW_BOT_INSTALLATION_ID="1", REVIEW_BOT_KEY=str(self.key))
        with self.assertRaisesRegex(rb.BotError, "REVIEW_BOT_APP_ID"):
            rb.load_config(self.ns(), env)

    def test_group_readable_key_is_refused(self):
        os.chmod(self.key, 0o640)
        env = self.env(REVIEW_BOT_APP_ID="1", REVIEW_BOT_INSTALLATION_ID="1", REVIEW_BOT_KEY=str(self.key),
                       REVIEW_BOT_REPO="o/r")
        with self.assertRaisesRegex(rb.BotError, "chmod 600"):
            rb.load_config(self.ns(), env)


class BotTest(KeyCase):
    def test_token_is_cached_until_near_expiry(self):
        http = FakeHttp()
        self.assertEqual(self.bot(http, cache=True).token(), "ghs_1")
        self.assertEqual(self.bot(http, cache=True).token(), "ghs_1")
        self.assertEqual(http.token_mints, 1)
        cache = self.dir / "cache" / "184.json"
        self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
        data = json.loads(cache.read_text())
        data["expires_epoch"] = NOW + rb.TOKEN_MARGIN - 1
        cache.write_text(json.dumps(data))
        self.assertEqual(self.bot(http, cache=True).token(), "ghs_2")

    def test_review_pins_the_reviewed_commit(self):
        http = FakeHttp(head="abc123def456")
        result = self.bot(http).review(5, "APPROVE", "Looks good.", "abc123d")
        method, url, headers, body = http.calls[-1]
        self.assertEqual((method, url), ("POST", "https://api.github.com/repos/o/r/pulls/5/reviews"))
        self.assertEqual(body, {"event": "APPROVE", "body": "Looks good.", "commit_id": "abc123def456"})
        self.assertTrue(headers["Authorization"].startswith("token ghs_"))
        self.assertEqual(result["state"], "APPROVED")

    def test_review_refused_when_head_moved(self):
        http = FakeHttp(head="fff000")
        with self.assertRaises(rb.HeadMoved):
            self.bot(http).review(5, "APPROVE", "ok", "abc123")
        self.assertFalse(any(url.endswith("/reviews") for _, url, _, _ in http.calls))

    def test_change_request_needs_a_body(self):
        with self.assertRaisesRegex(rb.BotError, "needs a body"):
            self.bot().review(5, "REQUEST_CHANGES", "  ", None)

    def test_comment_and_whoami(self):
        http = FakeHttp()
        self.assertEqual(self.bot(http).comment(5, "hi")["id"], 7)
        me = self.bot(http).whoami()
        self.assertEqual((me["login"], me["repo_accessible"]), ("local-reviewer-agent[bot]", True))

    def test_whoami_reports_unreachable_repo_and_main_fails(self):
        http = FakeHttp()
        http.repo_visible = False
        self.assertFalse(self.bot(http).whoami()["repo_accessible"])
        orig_bot, orig_load = rb.Bot, rb.load_config
        rb.load_config = lambda args: self.cfg
        bot = self.bot(http)  # built before patching rb.Bot
        rb.Bot = lambda cfg: bot
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(rb.main(["whoami"]), 2)
            self.assertIn("cannot access o/r", err.getvalue())
        finally:
            rb.Bot, rb.load_config = orig_bot, orig_load

    def test_revoked_cached_token_is_replaced_once(self):
        http = FakeHttp()
        bot = self.bot(http, cache=True)
        self.assertEqual(bot.token(), "ghs_1")
        http.revoked.add("ghs_1")
        self.assertEqual(bot.comment(5, "hi")["id"], 7)
        self.assertEqual(http.token_mints, 2)
        self.assertEqual(bot.token(), "ghs_2")  # the cache now holds the fresh token

    def test_api_error_is_raised(self):
        with self.assertRaisesRegex(rb.BotError, "HTTP 404"):
            self.bot().api("GET", "nowhere")


if __name__ == "__main__":
    unittest.main()
