---
description: PR reviews run in rounds. The author sends the PR with GitHub's "Ready for review" button, any submitted review ends the round, and only the next submission wakes the reviewer. Works when the author and the repository owner are the same single account.
trigger: always_on
---

# PR Review Rounds (All Agents, including Antigravity)

Operationalizes AGENTS.md rules 15 and 16. It defines **when** the reviewer wakes. [pr-reviewer-polling.md](pr-reviewer-polling.md) and [pr-author-followup.md](pr-author-followup.md) define what each side does once awake.

The goal is one reviewer wake-up per round. Pushes, CI runs and comments between rounds cost the reviewer no model tokens.

## The two lifecycle signals

| Direction | Signal | Meaning |
|---|---|---|
| Author → reviewer | **Ready for review** (`gh pr ready <pr>`), timeline event `ready_for_review` | "Review this head now" |
| Reviewer → author | **Submit review**: Comment, Approve or Request changes | "This round is over" |

## No second user is needed

The reviewer is the GitHub App `local-reviewer-agent` (rule 14), a separate identity from the author, so it can submit Approve and Request changes on the owner's PRs. For the author's side, GitHub's reviewer request does not fit this setup: authors cannot request themselves, and requested reviewers are users and teams, not App bots. Do not depend on the "Request review" or "Re-request review" buttons. The author uses **Ready for review**, which the PR author can press with their own account, either in the web UI or with `gh pr ready`.

The queue also counts a `review_requested` timeline event that names the bot, so a request button works without a rule change if GitHub records one for the App.

## Author: one round

1. **Open the PR as a draft** (`gh pr create --draft`). A draft never wakes the reviewer.
2. Finish the work in the draft: run the local suite, push, and wait until every CI check passes (rule 12).
3. **Send it to review**: `gh pr ready <pr>`. Then watch for the verdict (rule 15). Marking the PR ready changes its `draft` field, so take the author baseline after this command.
4. After **Request changes**, or a **Comment** that needs an answer or a fix:
   1. `gh pr ready <pr> --undo` (Convert to draft) first.
   2. Fix the notes, push as often as needed, reply once with what changed, and wait for green CI.
   3. `gh pr ready <pr>` to send the next round.
5. **To answer without new commits** (a disagreement or a clarification): reply in a comment, then run `gh pr ready <pr> --undo` and `gh pr ready <pr>`. A comment alone does not wake the reviewer.
6. After **Approve**, do not send it again. Minor notes are fixed, pushed, checked by CI and merged without another round.

Send only when the round is complete, and do not send again while the reviewer has not answered. A PR that is not finished stays a draft (rule 12). If the user wants to send a round by hand, they press **Ready for review** in the PR's merge box; the agent then does not press it for them.

## Reviewer: one round

1. Wait with `python3 scripts/pr_review_watch.py --json`. It wakes only for a PR that is not a draft, has finished CI and has a submission the bot has not answered.
2. Collect every finding, then **submit exactly one review** with `scripts/review_bot.py review` and one of:

   | Event | Use when | Author's next step |
   |---|---|---|
   | `REQUEST_CHANGES` | There are blocking notes | Draft, fix, send again |
   | `APPROVE` | The changes are OK (minor notes allowed) | Fix minor notes, merge |
   | `COMMENT` | No verdict yet: you need an answer from the author | Answer, send again |

3. All three events end the round. Put line notes in that one review, not in separate comments before it.
4. **While CI is red, post nothing**: a `COMMENT` would end the round, and a green rerun would no longer wake you. Restart the watcher with `--seen N@SHA:failed`. The author who has to push a fix converts to draft and sends again.
5. Restart the watcher and stay idle. Do not read comments or pushes between rounds.

## Reasons the queue reports

- `new`: never reviewed by the bot (opened ready, or a draft sent for the first time).
- `new_head`: sent again with new commits.
- `requested`: sent again on the same commit. Read the author's reply first.
- `unfinished`: the bot's last review of this head was dismissed.
- Skipped as `not_submitted`: new commits since the last review, but the author has not sent them.

A PR opened without a draft counts as sent once. Later rounds still need the button. If an author does not follow this rule (an outside contributor, an older session), run the watcher or queue with `--any-change`, which wakes for every new head and new comment.
