---
description: The reviewer agent acts as local-reviewer-agent, watches for PR events (no timer) and wakes for ready PRs and new feedback, re-reviews changed heads, and approves formally when the changes are OK.
trigger: always_on
---

# PR Reviewer Watch Loop (All Agents, including Antigravity)

Operationalizes AGENTS.md rule 16. Applies to an agent running as the reviewer. Builds on rule 14 and [pr-review-bot.md](pr-review-bot.md): every write goes through `python3 scripts/review_bot.py` as **`local-reviewer-agent[bot]`**, never as `gurkanindibay`. If `python3 scripts/review_bot.py whoami` fails, stop and tell the user.

Pair rule for authors: [pr-author-followup.md](pr-author-followup.md), which polls for your review and merges after your approval.

## The loop

The harness starts the Python watcher as a background process and resumes the reviewer on exit. The process holds the GitHub connection or polls GitHub while the model is idle:

```bash
python3 scripts/pr_review_watch.py --json                      # blocks; exits 0 with the ready PRs
python3 scripts/pr_review_watch.py --json --seen 257@ab12cd34ef56:failed   # ignore a PR you left without a verdict on red CI, until its head or CI state changes
```

It waits on GitHub events and costs no model tokens while it waits:

- **Webhook (preferred).** With the `cli/gh-webhook` extension installed (`gh extension install cli/gh-webhook`, needs admin on the repository), `gh webhook forward` relays PR, submitted review, inline review comment, conversation comment and CI events to a listener on 127.0.0.1. An event only triggers a recheck of the queue through the GitHub API; the payload is never trusted.
- **Poll fallback.** Without the extension, or if the forwarder dies (for example another forwarder already holds the repository's hook), it checks with `gh` every `--interval` seconds (default 60) and runs the per-PR review lookups only when the open-PR list (heads, drafts, CI state, update times) changed. That is still polling, but by a script, not by the model.
- Right after a push GitHub briefly shows no checks for the new head; the watcher holds such a head for `--ci-grace` seconds (default 300) so it never wakes you before CI has even started. A PR that really runs no CI is released after the grace period.
- A full refresh of the bot's review history runs on every webhook event and, whatever the source, every `--recheck` seconds (default 900) on its own deadline, so a lost event or a review-only change (for example a dismissed review) delays a review but never loses it.
- `--repo owner/name` scopes the listener, the PR listing and the review history to one repository.

Do not use a model-driven timer, `ScheduleWakeup`, a 30-minute cron or `/loop` for the reviewer. When the watcher exits, handle the wake-up below, then start it again. Pass `--seen N@SHA:<ci>` for each ready PR you deliberately left without a final verdict on that head, with `<ci>` taken from the wake-up you handled (usually `:failed`, when you are waiting on red CI). The suppression lasts while the head *and* its CI state are unchanged, so a same-commit rerun from red to green wakes you, even if the rerun is already pending when the watcher starts. A bare `N@SHA` also works: it binds to the first state the watcher sees, or to `absent` if the PR is not ready at that moment (for example a `COMMENT` saying you wait for CI to be fixed), otherwise the watcher wakes you again at once. Stop the watcher when you stop reviewing.

**Compact before every wake-up.** Before acting on a wake-up, compact your context (`/compact` in Claude Code, or your harness's equivalent; if none exists, continue in a fresh session). Nothing needs carrying over except the repo, the bot identity check, the watcher command and its `--seen` and `--seen-activity` arguments. The bot's review history supplies the last verdict for each PR. Drop diffs and review drafts from earlier wake-ups.

A watcher entry with `reason: feedback` means someone posted or edited a conversation or inline comment after the bot's final review of the current head. Read the activity links and respond to actionable feedback via the review bot. Acknowledge each handled item by passing its `cursor` as a `--seen-activity` argument on the next invocation. Save those arguments with the session so a restart does not replay handled feedback. Acknowledgement applies to that version of the comment, so an edit can wake the reviewer again. Responding to a clarification can use a conversation comment. Keep the existing verdict unless new evidence warrants changing it.

For a fresh verdict, the one-shot queue tool shows which PRs need a review. It reads the bot's own review history as the state (no local file to lose), so one short call replaces the manual listing:

```bash
python3 scripts/pr_review_queue.py            # ready PRs: number, reason, CI, head, title
python3 scripts/pr_review_queue.py --json     # ready, waiting_ci and skipped, with reasons
python3 scripts/pr_review_queue.py --all      # also show PRs waiting on CI and skipped ones
```

A PR is **ready** when it is not a draft, all its CI checks have finished (passed or failed), and the bot has no final verdict on the current head. The `reason` tells you where to start:

- `new`: the bot never reviewed it (a new PR, or a draft just marked ready). Review the whole PR.
- `new_head`: commits arrived after the bot's last review. Look first at what changed (`git diff <last_reviewed>..<head>`; the `--json` output has both SHAs), then at the whole PR if the change is wide.
- `unfinished`: the bot's last review of this head is a `COMMENT` (or was dismissed), so no verdict exists yet. Finish it with `APPROVE` or `REQUEST_CHANGES`.
- `feedback` (watcher only): a conversation or inline comment was posted or edited after the bot's final review. Read the linked comment and acknowledge its cursor after handling it.

PRs under `waiting_ci` need a review but CI is still running: the watcher wakes you when their CI finishes (or block on `gh pr checks <n> --watch` if you want that one now). `skipped` covers drafts, PRs you authored (`--skip-author <login>`) and heads the bot already gave a final verdict, even if comments exist; if the author replied with a disagreement on such a head, answer it once with a comment and do not repeat the review.

If a wake-up turns out to need nothing (the PR changed again meanwhile), restart the watcher with one line. Do not re-read diffs you already reviewed (AGENTS.md rule 9).

## Reviewing

1. Review against the linked issue's acceptance criteria, the AGENTS.md rules that apply to the files touched, and the PR's CI status. Reading uses your normal `gh` login; only writes use the bot.
2. Write the body to a file, pin the review to the head SHA you read (`--commit <sha>`; the tool refuses if the head moved, then re-review).
3. Put the review **on the PR** (and, for a first-time block or final approval, a one-line pointer on the linked issue via `review_bot.py comment`). Findings need file and line, what is wrong and what to change.
4. Pick the event:

   | Result | Event |
   |---|---|
   | Blocking problems (wrong behaviour, failing or missing tests, rule violations) | `REQUEST_CHANGES`, list each blocking note |
   | Fine, with small non-blocking notes (naming, comment wording, nits) | `APPROVE`, list the notes under "Minor notes". The author fixes them and merges without another round |
   | Fine | `APPROVE` with a short "Approved" body naming what was verified |

   ```bash
   python3 scripts/review_bot.py review <n> --event APPROVE --body-file review.md --commit <sha>
   ```

5. **Approval is a real GitHub approval** whenever it is available. Only if GitHub refuses the formal review, fall back to a conversation comment that starts with `APPROVED` (`review_bot.py comment`), so the author's loop still recognises it.
6. Do not approve while CI is failing or still running on the head. Post nothing (or at most one `COMMENT` saying you are waiting on CI; a `COMMENT` is never a final verdict, see the loop above) and restart the watcher; it wakes you when CI finishes or a new head arrives.

## Limits

- **The reviewer never merges, pushes code or edits the branch.** The author merges after approval (rule 15). The reviewer does not offer to merge either.
- Do not post duplicate reviews for the same head, and do not flip between verdicts without a new commit or new evidence.
- The author's claim labels (`in progress`, `claim:...`) on the PR belong to the author. A reviewer does not need to claim a PR to review it, and does not remove the author's labels.
- Never paste tokens, keys or `.env` values into a review.
