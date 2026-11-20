#!/usr/bin/env python3
"""Act on GitHub as the review bot (a GitHub App), not as a person.

Agents that review pull requests post their reviews, approvals and comments
through a GitHub App installation, so the review is attributed to the bot
(`<app-slug>[bot]`) and is a real review: a person cannot approve their own
PR, but the bot can. See AGENTS.md rule 14 and .agents/rules/pr-review-bot.md.

Usage:
    python3 scripts/review_bot.py whoami [--json]
    python3 scripts/review_bot.py token                    # installation token on stdout
    python3 scripts/review_bot.py review 123 --event APPROVE --body-file r.md --commit <head-sha>
    python3 scripts/review_bot.py review 123 --event REQUEST_CHANGES --body-file r.md --commit <sha>
    python3 scripts/review_bot.py comment 123 --body-file c.md
    python3 scripts/review_bot.py gh -- api repos/{owner}/{repo}/pulls   # any gh call as the bot

Configuration (never commit the key; the ids are per installation):
    --app-id / $REVIEW_BOT_APP_ID                 GitHub App id (or client id)
    --installation-id / $REVIEW_BOT_INSTALLATION_ID
    --key / $REVIEW_BOT_KEY                       private key (.pem), mode 600
    --repo / $REVIEW_BOT_REPO                     owner/name (default: origin remote)
    Missing values are read from the repository's untracked `.env` (the
    worktree's own, then the main checkout's); $REVIEW_BOT_ENV names another
    file. Flags win over the environment, which wins over `.env`.

`review --commit <sha>` refuses to post when the PR head has moved past the
commit you reviewed. Tokens are cached in ~/.cache/review-bot/ (mode 600)
until five minutes before they expire. JWTs are signed with `openssl`, so no
third-party Python package is needed.

Exit codes: 0 ok, 1 refused (head moved), 2 usage/config/API error
(including `whoami` when the installation cannot access the repo).
"""

from __future__ import annotations

import argparse
import base64
import calendar
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

API = "https://api.github.com"
CACHE_DIR = Path.home() / ".cache" / "review-bot"
EVENTS = ("APPROVE", "REQUEST_CHANGES", "COMMENT")
TOKEN_MARGIN = 300  # seconds before expiry when a cached token is renewed

Signer = Callable[[bytes, Path], bytes]
Http = Callable[[str, str, dict[str, str], bytes | None], tuple[int, Any]]


class BotError(Exception):
    """Usage, configuration or API failure (exit code 2)."""


class HeadMoved(Exception):
    """The PR head is not the commit the review was written for (exit code 1)."""


@dataclass(frozen=True)
class Config:
    app_id: str
    installation_id: str
    key_path: Path
    repo: str


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def openssl_sign(message: bytes, key_path: Path) -> bytes:
    """RS256 signature of `message` with the PEM key, via openssl."""
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=message,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise BotError(f"openssl could not sign with {key_path}: {proc.stderr.decode().strip()}")
    return proc.stdout


def build_jwt(app_id: str, key_path: Path, now: int | None = None, signer: Signer = openssl_sign) -> str:
    """App JWT: issued 60 s in the past (clock drift), valid for 9 minutes."""
    now = int(time.time()) if now is None else now
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = _b64url(
        json.dumps({"iat": now - 60, "exp": now + 540, "iss": app_id}, separators=(",", ":")).encode()
    )
    signing_input = f"{header}.{payload}".encode()
    return f"{header}.{payload}.{_b64url(signer(signing_input, key_path))}"


def urllib_http(method: str, url: str, headers: dict[str, str], body: bytes | None) -> tuple[int, Any]:
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            return err.code, json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return err.code, {"message": raw.decode(errors="replace")}


def _headers(auth: str) -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": auth,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "review-bot",
        "Content-Type": "application/json",
    }


def _check(status: int, data: Any, what: str) -> Any:
    if status >= 400:
        message = data.get("message") if isinstance(data, dict) else data
        raise BotError(f"{what} failed (HTTP {status}): {message}")
    return data


def _origin_repo() -> str:
    proc = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, check=False)
    match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", proc.stdout.strip())
    if not match:
        raise BotError("cannot infer owner/repo from the origin remote; pass --repo")
    return match.group(1)


def parse_dotenv(text: str) -> dict[str, str]:
    """KEY=VALUE lines; blank lines, comments and `export ` prefixes allowed."""
    values: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.removeprefix("export ").split("=", 1)
        value = value.strip()
        if value[:1] not in ("'", '"'):
            value = value.split(" #", 1)[0].strip()  # inline comment
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def _git(*args: str) -> str:
    proc = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def dotenv_files(env: dict[str, str]) -> list[Path]:
    """$REVIEW_BOT_ENV, else this worktree's .env, then the main checkout's."""
    if env.get("REVIEW_BOT_ENV"):
        return [Path(env["REVIEW_BOT_ENV"]).expanduser()]
    files: list[Path] = []
    top = _git("rev-parse", "--show-toplevel")
    common = _git("rev-parse", "--path-format=absolute", "--git-common-dir")
    for root in (top, str(Path(common).parent) if common else ""):
        if root and (Path(root) / ".env") not in files:
            files.append(Path(root) / ".env")
    return files


def load_config(args: argparse.Namespace, env: dict[str, str] | None = None) -> Config:
    """Flags, then environment, then `.env`."""
    env = dict(os.environ) if env is None else env
    files = dotenv_files(env)
    dotenv: dict[str, str] = {}
    for path in reversed(files):  # earlier files win
        if path.is_file():
            dotenv.update(parse_dotenv(path.read_text()))

    def pick(flag: str | None, var: str) -> str | None:
        value = flag or env.get(var) or dotenv.get(var)
        return value or None

    app_id = pick(getattr(args, "app_id", None), "REVIEW_BOT_APP_ID")
    installation_id = pick(getattr(args, "installation_id", None), "REVIEW_BOT_INSTALLATION_ID")
    key = pick(getattr(args, "key", None), "REVIEW_BOT_KEY")
    missing = [n for n, v in (("REVIEW_BOT_APP_ID", app_id), ("REVIEW_BOT_INSTALLATION_ID", installation_id),
                              ("REVIEW_BOT_KEY", key)) if not v]
    if missing:
        where = ", ".join(str(f) for f in files) or ".env"
        raise BotError(f"missing {', '.join(missing)}: set the flags, the environment or {where}")
    key_path = Path(key).expanduser()  # type: ignore[arg-type]
    if not key_path.is_file():
        raise BotError(f"private key not found: {key_path}")
    if key_path.stat().st_mode & 0o077:
        raise BotError(f"private key {key_path} is readable by others; run chmod 600 on it")
    repo = pick(getattr(args, "repo", None), "REVIEW_BOT_REPO") or _origin_repo()
    return Config(app_id, installation_id, key_path, repo)  # type: ignore[arg-type]


class Bot:
    def __init__(self, cfg: Config, http: Http = urllib_http, signer: Signer = openssl_sign,
                 cache_dir: Path | None = CACHE_DIR, now: Callable[[], float] = time.time):
        self.cfg, self.http, self.signer, self.cache_dir, self.now = cfg, http, signer, cache_dir, now

    # -- authentication -------------------------------------------------
    def app_jwt(self) -> str:
        return build_jwt(self.cfg.app_id, self.cfg.key_path, int(self.now()), self.signer)

    def _cache_file(self) -> Path | None:
        return None if self.cache_dir is None else self.cache_dir / f"{self.cfg.installation_id}.json"

    def token(self, fresh: bool = False) -> str:
        """Installation token; `fresh` skips the cache (after a 401)."""
        cache = self._cache_file()
        if cache and cache.is_file() and not fresh:
            try:
                cached = json.loads(cache.read_text())
                if cached["expires_epoch"] - TOKEN_MARGIN > self.now():
                    return cached["token"]
            except (json.JSONDecodeError, KeyError, TypeError):
                pass
        status, data = self.http(
            "POST", f"{API}/app/installations/{self.cfg.installation_id}/access_tokens",
            _headers(f"Bearer {self.app_jwt()}"), None,
        )
        data = _check(status, data, "minting an installation token")
        expires = calendar.timegm(time.strptime(data["expires_at"], "%Y-%m-%dT%H:%M:%SZ"))
        if cache:
            cache.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd = os.open(cache, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as fh:
                json.dump({"token": data["token"], "expires_epoch": expires}, fh)
        return data["token"]

    def request(self, method: str, path: str, body: dict[str, Any] | None = None) -> tuple[int, Any]:
        """One call with the installation token; on 401 (a revoked cached
        token) mint a fresh one and retry once."""
        payload = json.dumps(body).encode() if body is not None else None
        url = f"{API}/{path.lstrip('/')}"
        status, data = self.http(method, url, _headers(f"token {self.token()}"), payload)
        if status == 401:
            status, data = self.http(method, url, _headers(f"token {self.token(fresh=True)}"), payload)
        return status, data

    def api(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        return _check(*self.request(method, path, body), f"{method} {path}")

    # -- actions ----------------------------------------------------------
    def whoami(self) -> dict[str, Any]:
        status, app = self.http("GET", f"{API}/app", _headers(f"Bearer {self.app_jwt()}"), None)
        app = _check(status, app, "reading the app")
        status, repo = self.request("GET", f"repos/{self.cfg.repo}")
        if status not in (200, 404):
            _check(status, repo, f"reading {self.cfg.repo}")
        return {
            "app": app.get("slug"),
            "login": f"{app.get('slug')}[bot]",
            "app_id": app.get("id"),
            "installation_id": self.cfg.installation_id,
            "repo": self.cfg.repo,
            "repo_accessible": status == 200,
            "permissions": app.get("permissions", {}),
        }

    def head_sha(self, pr: int) -> str:
        return self.api("GET", f"repos/{self.cfg.repo}/pulls/{pr}")["head"]["sha"]

    def review(self, pr: int, event: str, body: str, commit: str | None) -> dict[str, Any]:
        if event not in EVENTS:
            raise BotError(f"--event must be one of {', '.join(EVENTS)}")
        if event == "REQUEST_CHANGES" and not body.strip():
            raise BotError("a change request needs a body")
        payload: dict[str, Any] = {"event": event, "body": body}
        if commit:
            head = self.head_sha(pr)
            if not head.startswith(commit):
                raise HeadMoved(f"PR #{pr} head is {head[:12]}, not the reviewed {commit[:12]}; re-review it")
            payload["commit_id"] = head
        data = self.api("POST", f"repos/{self.cfg.repo}/pulls/{pr}/reviews", payload)
        return {"id": data.get("id"), "state": data.get("state"), "url": data.get("html_url")}

    def comment(self, pr: int, body: str) -> dict[str, Any]:
        data = self.api("POST", f"repos/{self.cfg.repo}/issues/{pr}/comments", {"body": body})
        return {"id": data.get("id"), "url": data.get("html_url")}


def _read_body(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    try:
        return Path(path).read_text()
    except OSError as err:
        raise BotError(f"cannot read {path}: {err}") from err


def _emit(result: Any, as_json: bool) -> None:
    if as_json or not isinstance(result, dict):
        print(json.dumps(result, indent=2) if as_json else result)
    else:
        for key, value in result.items():
            print(f"{key}: {value}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--app-id", default=argparse.SUPPRESS)
    common.add_argument("--installation-id", default=argparse.SUPPRESS)
    common.add_argument("--key", default=argparse.SUPPRESS, help="path to the app's private key (.pem)")
    common.add_argument("--repo", default=argparse.SUPPRESS, help="owner/name (default: origin remote)")
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine-readable output")
    parser.add_argument("--app-id")
    parser.add_argument("--installation-id")
    parser.add_argument("--key", help="path to the app's private key (.pem)")
    parser.add_argument("--repo", help="owner/name (default: origin remote)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("whoami", parents=[common], help="show the bot identity and whether it can reach the repo")
    sub.add_parser("token", parents=[common], help="print an installation access token")
    rev = sub.add_parser("review", parents=[common], help="submit a PR review as the bot")
    rev.add_argument("pr", type=int)
    rev.add_argument("--event", required=True, choices=EVENTS)
    rev.add_argument("--body-file", required=True, help="markdown body ('-' for stdin)")
    rev.add_argument("--commit", help="head SHA you reviewed; refuse if the PR has moved")
    com = sub.add_parser("comment", parents=[common], help="post a PR conversation comment as the bot")
    com.add_argument("pr", type=int)
    com.add_argument("--body-file", required=True, help="markdown body ('-' for stdin)")
    ghp = sub.add_parser("gh", help="run a gh command authenticated as the bot")
    ghp.add_argument("gh_args", nargs=argparse.REMAINDER)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        bot = Bot(load_config(args))
        if args.command == "token":
            print(bot.token())
        elif args.command == "whoami":
            me = bot.whoami()
            _emit(me, args.json)
            if not me["repo_accessible"]:
                print(f"error: the app installation cannot access {bot.cfg.repo}", file=sys.stderr)
                return 2
        elif args.command == "review":
            _emit(bot.review(args.pr, args.event, _read_body(args.body_file), args.commit), args.json)
        elif args.command == "comment":
            _emit(bot.comment(args.pr, _read_body(args.body_file)), args.json)
        elif args.command == "gh":
            gh_args = args.gh_args[1:] if args.gh_args[:1] == ["--"] else args.gh_args
            env = {**os.environ, "GH_TOKEN": bot.token(), "GH_REPO": bot.cfg.repo}
            return subprocess.run(["gh", *gh_args], env=env, check=False).returncode
    except HeadMoved as err:
        print(f"refused: {err}", file=sys.stderr)
        return 1
    except BotError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
