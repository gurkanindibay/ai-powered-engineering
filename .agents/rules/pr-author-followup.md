---
description: After opening a PR, the author agent watches it (no schedule), fixes review notes, merges once approved, closes the issue and cleans up its worktree and branches.
trigger: always_on
---

# PR Author Follow-up Loop (All Agents, including Antigravity)

Operationalizes AGENTS.md rule 15. Applies to the agent that developed a GitHub issue and opened its PR. It extends rules 11 and 12: the task is **not** finished when the PR is green. It is finished when the PR is merged and cleaned up (or closed, see Stop conditions).

Pair rule for reviewers: [pr-reviewer-polling.md](pr-reviewer-polling.md).

## The loop

After opening and labeling the PR, watch it until it is merged or closed. Keep its claim labels in place while waiting. The harness starts the Python watcher as a background process and resumes the author on exit. GitHub I/O and idle waits happen in the process.

1. **CI.** Run `gh pr checks <pr> --watch` as required by rule 12.
2. **Review activity.** Capture a baseline once, and inspect any review or comment already present in it before waiting. Keep the file outside the worktree.

   ```bash
   python3 scripts/pr_review_watch.py --author-pr <pr> --snapshot > "$pr_baseline"
   python3 scripts/pr_review_watch.py --author-pr <pr> --after "$pr_baseline" --json > "$pr_wake"
   ```

   The watcher reports new or edited reviews, conversation comments, inline review comments and changes to the PR's head, state, finished CI, draft status, review decision or confirmed merge conflicts. It filters out the PR author's own comments. A wake-up contains changed fields, links to new activity and a snapshot that can be passed directly to `--after`. After handling the wake-up, advance the baseline to that output and restart the watcher. Keep the handled baseline across pushes and CI waits so that feedback arriving during fixes is picked up on the next call. Use a different output path from the input for every wait. Exit 2 reports a watcher error, and exit 3 ends a bounded wait without new activity.

**Compact before every wake-up.** Carry the PR, issue, branch, worktree, harness and claim session ID, author snapshot path, and fix count for each blocking note. Read linked reviews and comments in GitHub and verify the live head and CI before acting. The snapshot can become stale between the wake-up and an action.

Then act on exactly one of these cases:

1. **Nothing new** (no review or comment since your last push or last wake-up): do nothing and go back to watching.
2. **Review notes to fix** (a `CHANGES_REQUESTED` review, or a comment or review body that lists problems): fix every note in your own worktree and branch, run the relevant local suite (rule 3), push, reply on the PR with what changed (one comment, citing the commit), wait for CI to go green (rule 12), then resume from the last handled baseline. The reviewer's watcher wakes it for the new head once CI finishes.
   - If you disagree with a note, do not silently skip it: reply with the reasoning and let the reviewer decide.
   - If you delegate fixing review notes to a subagent, run it on Sonnet 5.5 (`claude-sonnet-5-5`; `model: "sonnet"`), set explicitly.
3. **Approved with no notes**: go to Merge.
4. **Approved with minor notes**: fix the notes, push, wait for CI to go green, then Merge. Do not wait for a second approval of the fix commits.
5. **Merge conflict or `master` moved in a way that breaks CI**: merge or rebase `origin/master` into your branch, rerun the suite, push, wait for CI, go back to watching.

## How to check approval (agents and subagents)

Query GitHub **at the moment you report or act on a PR's approval state**: on every wake-up, whenever the user asks about the PR or its checks, right after a re-run or pending check turns green, and before saying that a PR "still needs approval". This applies to the author, to any subagent or side session it delegates to, and to an agent reporting on another agent's PR.

```bash
gh pr view <pr> --json state,headRefOid,reviewDecision,mergeable
gh api --paginate repos/{owner}/{repo}/pulls/<pr>/reviews --jq '.[] | [.submitted_at, .user.login, .state, .commit_id] | @tsv'
gh api --paginate repos/{owner}/{repo}/issues/<pr>/comments --jq '.[] | select(.user.login == "local-reviewer-agent[bot]" and (.body | startswith("APPROVED"))) | [.created_at, .user.login] | @tsv'
gh pr checks <pr>
```

- **An empty `reviewDecision` does not mean "not approved".** GitHub can leave it empty although an `APPROVED` review exists (seen on PR 412), so always read the reviews list. The second and third commands are the evidence for the rules in [What counts as approved](#what-counts-as-approved). If the user named another reviewer for this PR, add that login to the third command's filter.
- For each reviewer, take their newest `APPROVED`, `CHANGES_REQUESTED` or `DISMISSED` review. A later `COMMENTED` review does not cancel an approval. Compare its `commit_id` with `headRefOid`.
- **Do not infer the state from older text or other signals.** A review saying "I'll approve once CI is green" describes what the reviewer intended then; the approval may have arrived since. Green checks, an earlier report, a CI event or a subagent's summary say nothing about the current reviews.
- A host's PR monitor (for example Auto-fix, which reports CI failures, merge conflicts and review comments) does not replace the `--author-pr` watcher in [The loop](#the-loop): do not rely on it to wake you for an approval.
- **Delegating:** put these commands, or a link to this section, in the subagent's brief, and ask it to return the matching review line (time, reviewer, state, commit) and the current head, not just "approved" or "waiting". Re-run the queries yourself before merging.

## What counts as approved

Any of these on the PR's current head, or on an earlier head when every commit after it only addresses that review's minor notes:

- `reviewDecision` is `APPROVED`, or the latest review by `local-reviewer-agent[bot]` (or another reviewer) is `APPROVED`.
- A review or conversation comment that starts with `APPROVED` **and** is authored by `local-reviewer-agent[bot]` or by a reviewer the user named for this PR (the fallback used when GitHub refuses a formal approval). A comment from anyone else, however worded, never counts.

A `CHANGES_REQUESTED` review that is newer than the latest approval cancels the approval. An approval from the PR's own author does not count. Notes that the reviewer calls blocking are never "minor", fix them and treat the PR as case 2.

## Merge

Merge only your own PR, and only when **all** hold: approved (above), every check passed (or none ran), no unresolved `CHANGES_REQUESTED`, `mergeable` is not `CONFLICTING`.

```bash
gh pr merge <pr> --squash --delete-branch
```

Use the repository's merge style (squash). Never use `--admin`, never bypass branch protection, never merge with a failing or pending check. If `--delete-branch` leaves the remote branch behind, delete it explicitly (`git push origin --delete <branch>`).

## Close and clean up (all of it, in this order)

1. **Stop the watchers first**, so nothing fires mid-cleanup or after the worktree is gone: kill the background `gh pr checks --watch` and the Python watcher you started using their background task handles and confirm none is left running. Do this on every exit from the loop, not only after a merge: PR closed unmerged, user says stop, or you hand the PR to the user. If your harness also gave you a timer, cancel that too.
2. **Close the issue**: confirm it is closed (the PR body should say `Closes #<n>`); if not, `gh issue close <issue> --comment "Delivered in #<pr>"`.
3. **Release the claims** on the issue and the PR: `python3 scripts/issue_claim.py release <issue> --harness <name> --session <id> --pr <pr>`.
4. **Remove your worktree** (rule 11): confirm it is clean and pushed, delete any Cargo build output in it (`python3 scripts/cargo_target_pool.py clean-worktree <worktree-path>`), then `git -C <main-checkout> worktree remove <worktree-path>`. If your host manages the worktree and you cannot remove it from inside, use the host's cleanup, or report the path and branch as ready to delete.
5. **Delete the local branch**: `git -C <main-checkout> branch -D <branch>` (it is merged by squash, so `-d` will refuse).
6. **Delete the remote branch** if still present: `git ls-remote --exit-code --heads origin <branch>` then `git push origin --delete <branch>`.
7. **Prune**: `git worktree prune` and `git fetch --prune origin`.
8. Report the merge commit, the closed issue and what was cleaned.

Never force-remove a dirty worktree, and never touch a worktree or branch that belongs to another agent or task.

## Stop conditions

- **PR closed without merging**: stop watching (kill the watchers), release the claims, report it, and leave cleanup decisions to the user.
- **Failure unrelated to your change** (also red on `master`, infra outage): report it with the check name and log excerpt, keep watching only if the user has not said otherwise.
- **The same note comes back after you fixed it twice**, or the reviewer and you disagree on a blocking point: stop and ask the user instead of looping.
- **The user says stop**, or asks you to merge or not merge a specific PR: the user wins.

Every wake-up that finds nothing new should cost almost nothing: no long output, no re-reading the diff (AGENTS.md rule 9).
