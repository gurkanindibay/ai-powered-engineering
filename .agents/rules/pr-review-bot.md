---
description: Post PR reviews, approvals and review comments as the review bot GitHub App (`scripts/review_bot.py`), never as the repository owner's account.
trigger: always_on
---

# PR Reviews Through the Review Bot (All Agents, including Antigravity)

Operationalizes AGENTS.md rule 14. Applies whenever an agent reviews a pull request.

An agent that reviews PRs acts as the GitHub App **`local-reviewer-agent`**, so every review it posts shows as `local-reviewer-agent[bot]`. It never posts as the owner's personal account (`gurkanindibay`). The bot is a separate identity, so:

- Its reviews are real GitHub reviews (`APPROVE` / `REQUEST_CHANGES`). They show in the PR's review status and count toward branch protection. Don't post "approved by comment" workarounds.
- A reader can tell an agent's review apart from the owner's own decisions.

## Setup (once per machine)

The ids and the key path live in the repository's **untracked** `.env` (`*.env` is gitignored). Never commit them, and never copy the key into the repository:

```bash
REVIEW_BOT_APP_ID=<app id>
REVIEW_BOT_INSTALLATION_ID=<installation id>
REVIEW_BOT_KEY=~/.config/github-apps/local-reviewer-agent.pem   # chmod 600
REVIEW_BOT_REPO=gurkanindibay/ai-powered-engineering
```

The tool reads the worktree's own `.env` first, then the main checkout's, so worktrees need no copy. Check the setup with:

```bash
python3 scripts/review_bot.py whoami      # login: local-reviewer-agent[bot], repo_accessible: True
```

If `whoami` fails because the key or `.env` is missing, stop and tell the user. Do **not** fall back to posting as `gurkanindibay`.

## Review workflow

1. **Claim the PR** before reviewing (rule 10): add `in progress` plus the claim label, and skip PRs already claimed by someone else.
2. **Read with any identity.** Reading the diff and CI with your normal `gh` login is fine. Only writes have to go through the bot.
3. **Write the review body** to a file and note the head SHA you reviewed (`gh pr view <n> --json headRefOid`).
4. **Post it as the bot**, pinned to that SHA. The tool refuses (exit 1) when the head has moved since, in which case you re-review the new head:

   ```bash
   python3 scripts/review_bot.py review <n> --event APPROVE         --body-file review.md --commit <sha>
   python3 scripts/review_bot.py review <n> --event REQUEST_CHANGES --body-file review.md --commit <sha>
   python3 scripts/review_bot.py review <n> --event COMMENT         --body-file review.md --commit <sha>
   python3 scripts/review_bot.py comment <n> --body-file note.md    # plain conversation comment
   ```

   For any other write (for example an inline review comment), run `gh` as the bot: `python3 scripts/review_bot.py gh -- api -X POST repos/{owner}/{repo}/pulls/<n>/comments ...`.
5. **Release the claim** when the review is posted.

## Limits

- **The bot reviews, it does not merge.** Authors merge their own PRs once approved. An agent merges only when the user explicitly asks for that PR.
- **Writes only.** The app has `pull_requests: write` and `contents: read`. It can't push code, so fixes stay with the author.
- **Tokens:** installation tokens last one hour. The tool caches them in `~/.cache/review-bot/` (mode 600). Never paste a token into a PR, an issue, a commit or a log.
