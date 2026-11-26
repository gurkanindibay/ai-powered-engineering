---
description: Always claim an issue and its PR with `scripts/issue_claim.py`; a bare `in progress` label is not enough.
trigger: always_on
---

# Issue and PR Claim Labels (All Agents, including Antigravity)

Operationalizes AGENTS.md rule 10. Applies the moment you pick an issue, before any other work.

## Your agent name

The user tells agents apart by name, not by session id. Each model has one fixed name (`python3 scripts/agent_names.py roster`; roster in `config/agent-names.json`); a second agent on the same model is numbered (`Alparslan 2`). **Never choose or type a name yourself**: the tools assign it.

- **Working on an issue**: `claim` (step 2) reserves the name, adds the `agent:<name>` label and prints the session title.
- **Any other task** (review, investigation, work with no issue): reserve one before you start:

  ```bash
  python3 scripts/agent_names.py reserve --harness claude --session <your-session-id> --model <your-model-id>
  ```

  When you finish: `python3 scripts/agent_names.py release --harness claude --session <your-session-id>`.
- **Show it in the harness.** The session title must start with `[<name>]`, followed by the issue and a short summary, e.g. `[Alparslan] #123 Show held advance`. If your harness has a rename tool (Claude Code desktop: `set_session_title`), use it right after reserving. If it has none, begin your first reply with that line (harnesses build the session summary from it). Either way, begin every final report and task summary with `[<name>]`.
- **Delegated subagents** that claim an issue pass their own model id and claim id, so they get their own name.
- Pass the model you are actually running on. If it changes mid-task, claim again with the new model.

`python3 scripts/agent_names.py list` shows who holds each name, with model, harness, session and issues. Reservations are local and never committed (`.agents/local/` in the main checkout, shared by all worktrees).

## Claiming

1. Check the issue is free: `python3 scripts/issue_claim.py status <issue> --json` (`in_progress` must be false).
2. Claim it. Do **not** add `in progress` by hand (`gh issue edit` or the web UI): that leaves an unidentified claim other harnesses cannot attribute.

   ```bash
   python3 scripts/issue_claim.py claim <issue> --harness antigravity --session <your-session-id> --model <your-model-id>
   ```

   Use your own harness name (`codex`, `claude`, `antigravity`). Use your session or conversation id; if you have none, keep the id the tool prints, `release` needs it.
3. When you open the PR, label it the same way:

   ```bash
   python3 scripts/issue_claim.py sync <issue> --pr <pr>
   ```

4. When the PR is merged or you set the work aside, release both:

   ```bash
   python3 scripts/issue_claim.py release <issue> --harness antigravity --session <id> --pr <pr>
   ```

An exit code of 1 means someone else owns it: pick another issue. Never use `--force` unless the user says so.
