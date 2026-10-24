---
name: continuous-improvement-tooling
description: >
  Evaluates, crystallizes, and registers reusable developer tools, inspection utilities, and
  verification scripts created during feature development or debugging so they can be reused
  across subsequent development iterations.
license: MIT
metadata:
  author: Antigravity
  version: "1.0.0"
---

# Continuous Improvement Tooling & Script Crystallization Skill

This skill governs the autonomous identification, packaging, and persistence of developer tools created during feature development, debugging, and verification.

---

## 1. Core Principle: The Tool Crystallization Imperative

During software engineering tasks, agents and engineers constantly create bespoke code snippets, database queries, API inspection routines, verification scripts, and multi-step diagnostic pipelines. 

**Rule of Thumb:**
If a custom script or diagnostic sequence took non-trivial effort to write, requires domain knowledge to execute, or will likely be needed again in subsequent iterations (for regression testing, state verification, or operational maintenance), **do not discard it as an ephemeral scratch script.** 

**Crystallize it into a reusable workspace tool.**

---

## 2. When to Crystallize a Script

Evaluate whether a script meets any of the following reusability triggers:

| Trigger | Example Use Case | Action Required |
| :--- | :--- | :--- |
| **State Inspection** | Checking active residents, occupancy status, dual-ledger dues, or database tables | Package into a query/inspect CLI (e.g. `db_verify.py`) |
| **Data Verification** | Asserting data integrity, orphan foreign keys, balance invariants | Build into a `--verify` integrity command |
| **API Workflow Automation** | Multi-step REST sequence (e.g., login -> accrual -> reconciliation -> receipt) | Script into an automation CLI with curl/requests |
| **Harness & Mock Seeding** | Generating deterministic test fixtures or resetting demo environments | Create a dedicated seed/reset script |
| **Log / Event Diagnostics** | Parsing container event logs, error traces, or memory metrics | Create a diagnostic collector tool |

---

## 3. Tool Quality & Architecture Standards

Every crystallized tool must satisfy the following architectural criteria:

1. **Python Over Bash (Workspace Rule #5):**
   - Author tools in Python (`python3`).
   - Use standard library modules (`argparse`, `json`, `subprocess`, `sys`, `pathlib`) or pre-approved workspace libraries to eliminate unneeded external dependencies.

2. **Standard CLI Interface (`argparse`):**
   - Implement clear positional commands and optional flags.
   - Always support `--help` (`-h`) describing usage and subcommands.

3. **Dual Output Modes (Human & Machine Readable):**
   - **Default:** Clean, human-readable tabular or formatted output for developer/agent chat inspection.
   - **`--json` / `query-json`:** Machine-readable JSON output for automated test assertions, piping, or tool chaining.

4. **Robust Exit Codes & Error Handling:**
   - Exit `0` on success.
   - Exit non-zero on failure with concise, actionable error messages sent to `stderr`.
   - Never print raw stack traces unless `--debug` is explicitly passed.

5. **Cross-Platform & Container Compatibility:**
   - Detect running container engines (`docker`, `sudo docker`, or local fallback).
   - Read connection parameters from environment variables with sensible local defaults.

---

## 4. Packaging & Discovery Workflow

When creating a new reusable tool:

1. **Place in Project Tooling Directory:**
   - Put project-specific tools in `apps/<paradigm>/<Project>/scripts/` (e.g., `apps/development-time/SitePulse/scripts/db_verify.py`).
   - Create a root-level symlink in `scripts/` if it serves the general development workflow (e.g., `scripts/db_verify.py -> apps/...`).
   - Ensure execution permissions: `chmod +x <path_to_script>`.

2. **Register in `skills.md` (Workspace Root):**
   - Add the tool's name, purpose, command syntax, and sample usage to [skills.md](file:///skills.md).

3. **Create or Update Skill Definition:**
   - If the tool addresses a distinct functional domain (e.g., database verification, bank file testing), create or update its dedicated skill in `.agents/skills/<skill-name>/SKILL.md`.

4. **Reference in Workspace Directives (`AGENTS.md`):**
   - Ensure the workspace rules reference the capability so subsequent agent turns prioritize using the tool rather than reinventing the wheel.

---

## 5. Continuous Improvement Execution Checklist

When developing any feature:

- [ ] **Step 1 - Notice Repetitive Need:** Did I write a 3+ line bash command or ad-hoc query more than once?
- [ ] **Step 2 - Crystallize:** Extract the logic into a structured Python script under `scripts/`.
- [ ] **Step 3 - Add CLI Flags:** Support subcommand dispatch, `--help`, and `--json`.
- [ ] **Step 4 - Test Execution:** Run the script locally and verify both table and JSON outputs.
- [ ] **Step 5 - Register Skill:** Update `skills.md` and create/update `.agents/skills/<skill-name>/SKILL.md`.
- [ ] **Step 6 - Reuse in Subsequent Tasks:** Call the tool in subsequent testing and verification steps.
