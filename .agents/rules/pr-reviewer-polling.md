---
description: The reviewer agent acts as local-reviewer-agent, polls every 30 minutes for open PRs, re-reviews only changed heads, and approves formally when the changes are OK.
trigger: always_on
---

# PR Reviewer Polling Loop (All Agents, including Antigravity)

Operationalizes AGENTS.md rule 16. Applies to an agent running as the reviewer. Builds on rule 14 and [pr-review-bot.md](pr-review-bot.md): every write goes through `python3 scripts/review_bot.py` as **`local-reviewer-agent[bot]`**, never as `gurkanindibay`. If `python3 scripts/review_bot.py whoami` fails, stop and tell the user.

Pair rule for authors: [pr-author-followup.md](pr-author-followup.md), which polls for your review and merges after your approval.

## The loop

Every **30 minutes** (use your harness's scheduler, for example `ScheduleWakeup` with `delaySeconds=1800`, or a cron job), list the open PRs and review the ones that changed:

```bash
gh pr list --state open --json number,title,isDraft,headRefOid,author \
  --jq '.[]|select(.isDraft|not)|[.number,.headRefOid[0:12],.author.login,.title]|@tsv'
```

For each non-draft PR, decide from the bot's own review history, which is the state (no local file to lose):

```bash
gh api repos/{owner}/{repo}/pulls/<n>/reviews --paginate \
  --jq '[.[]|select(.user.login=="local-reviewer-agent[bot]")]|last|{state,commit_id}'
```

- **No bot review yet**: review the PR.
- **Bot reviewed a commit that is not the current head**: the author pushed since. Re-review, looking first at what changed since that commit (`git diff <reviewed-sha>..<head>`), then at the whole PR if the change is wide.
- **Bot reviewed the current head**: skip it, even if comments exist. If the author replied with a disagreement on the same head, answer it once with a comment, do not repeat the review.
- **Draft PRs and PRs you authored**: skip.

When nothing changed anywhere, end the cycle silently with one line. Do not re-read diffs you already reviewed (AGENTS.md rule 9).

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
6. Do not approve while CI is failing or still running on the head. Post `COMMENT` saying you are waiting on CI, and look again next cycle.

## Limits

- **The reviewer never merges, pushes code or edits the branch.** The author merges after approval (rule 15). The reviewer does not offer to merge either.
- Do not post duplicate reviews for the same head, and do not flip between verdicts without a new commit or new evidence.
- The author's claim labels (`in progress`, `claim:...`) on the PR belong to the author. A reviewer does not need to claim a PR to review it, and does not remove the author's labels.
- Never paste tokens, keys or `.env` values into a review.
