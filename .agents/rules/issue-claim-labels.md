---
description: Always claim an issue and its PR with `scripts/issue_claim.py`; a bare `in progress` label is not enough.
trigger: always_on
---

# Issue and PR Claim Labels (All Agents, including Antigravity)

Operationalizes AGENTS.md rule 10. Applies the moment you pick an issue, before any other work.

1. Check the issue is free: `python3 scripts/issue_claim.py status <issue> --json` (`in_progress` must be false).
2. Claim it. Do **not** add `in progress` by hand (`gh issue edit` or the web UI): that leaves an unidentified claim other harnesses cannot attribute.

   ```bash
   python3 scripts/issue_claim.py claim <issue> --harness antigravity --session <your-session-id>
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
