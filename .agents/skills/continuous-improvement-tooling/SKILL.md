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

---

## 6. Registered SitePulse Tools

Use these before writing ad-hoc commands (details and examples in [skills.md](file:///skills.md)):

| Tool | Path | Use it for |
| :--- | :--- | :--- |
| `run_tests.py` | `apps/development-time/SitePulse/scripts/run_tests.py` | The full gate run before concluding any change; `--from-dev-container` loads local development DB settings without exposing credentials; `--summary` gives compact, agent-friendly output |
| `test_strategy_scan.py` | `apps/development-time/SitePulse/scripts/test_strategy_scan.py` | Quarterly re-scan for the [test strategy](../../../apps/development-time/SitePulse/docs/testing/TEST_STRATEGY.md): how each test runs in CI, shortcut flags, and scenarios covered only on paper; `--json` summary, `--output` full rows |
| `test_quality_lint.py` | `apps/development-time/SitePulse/scripts/test_quality_lint.py` | Ratchets weak assertions, unwrap-only/weak-only tests, wait-only GUI tests, fixed sleeps, test environment mutations and backend `Utc::now()` reads; tracks tests with more than three scenario claims in `test_quality_baseline.json` (gate `test-quality-lint`) |
| `e2e_shard.py` | `apps/development-time/SitePulse/scripts/e2e_shard.py` | Duration-balanced sharding of the GUI suite on recorded and CI-fed JUnit durations; `plan --shards N` shows expected shard times, `ingest-junit` updates the cacheable duration store, and `gui_e2e.py run --shard I/N` loads the planner as a pytest plugin |
| `ci_e2e_plan.py` | `apps/development-time/SitePulse/scripts/ci_e2e_plan.py` | Computes GitHub Actions E2E lane selection from `feature_traceability.py affected`: docs-only PR skip, targeted smoke/core plus impacted epics, full suite for shared changes and master; supports `--help`, `--json`, and GitHub output |
| `api_system_check.py` | `apps/development-time/SitePulse/scripts/api_system_check.py` | HTTP auth, tenancy, webhook, concurrency, restart, match-all-in-place, payer identity, site purge, per-debtor virman, reversal, scoped webhook claims, receipt issuer snapshot, aging snapshot, ledger drift, session rotation/revocation, transactional audit failure, audit RLS, scoped review, support approval, archived identity reuse without restart, atomic invitation, provider payment, household persistence/rollback and budget checks against a real DB, with ledger invariants checked after each scenario |

| `schema_integrity_check.py` | `apps/development-time/SitePulse/scripts/schema_integrity_check.py` | Migration and seed replay (including repeated loads and archived-identity reuse), constraint tests (incl. the V16 append-only payment ledger and the V17 reversal / webhook-claim / issuer / status rules) and the upgrade test |
| `gui_e2e.py` | `apps/development-time/SitePulse/scripts/gui_e2e.py` | Playwright GUI suite in a real browser against an isolated stack (`serve` mode for writing tests); source/API-origin fingerprint prevents stale bundle reuse and resets preserve append-only audit evidence |
| `testid_lint.py` | `apps/development-time/SitePulse/scripts/testid_lint.py` | Every widget `Key` has a matching GUI `testId` (gate `testid-lint`) |
| `ui_style_lint.py` | `apps/development-time/SitePulse/scripts/ui_style_lint.py` | Design-system rules: 12 px floor, `MoneyFormatter` for amounts, no emoji icons, no popups/partial sheets (`no-popup`); ratchet on literal font sizes and colours (gate `ui-style-lint`) |
| `flutter_reuse_inventory.py` | `apps/development-time/SitePulse/scripts/flutter_reuse_inventory.py` | Flutter reuse inventory (token adoption, shared-widget usage) and guard rules: no raw clipboard writes, `Decimal.tryParse` in UI, JSON Decimal fallbacks, hand-rolled amount normalisation, raw `FilterChip`, hand-built `SpSelectionPage` or direct `SnackBar` (gate `flutter-reuse`). Catalogue: `.agents/skills/flutter-reusable-components/SKILL.md` |
| `gui_traceability.py` | `apps/development-time/SitePulse/scripts/gui_traceability.py` | Story → GUI scenario → test status; refreshes the section in `COMPLETION_STATUS.md` |
| `feature_traceability.py` | `apps/development-time/SitePulse/scripts/feature_traceability.py` | Epic → story → Gherkin scenario (`.specify/features`) → execution status per scenario and step, with the run history and per-task reports under `.specify/executions` (`check` is gate `feature-traceability`, `check --require-run` gate `test-run-recorded`, switched by `.specify/executions/settings.json`; `record`, `task-report`, `runs`, `report`, `history`, `html` dashboard) |
| `ci_test_report.py` | `apps/development-time/SitePulse/scripts/ci_test_report.py` | Merges CI e2e shard artifacts into one report (markdown, HTML dashboard, stats in the job summary); CI uploads it as artifact `e2e-test-report` |
| `cucumber_pilot_report.py` | `apps/development-time/SitePulse/scripts/cucumber_pilot_report.py` | Reconciles the five on-demand Cucumber pilot cases against native JUnit counts, then emits only allowlisted case IDs, static labels, outcomes, durations, comparison markers, and Actions run metadata; raw examples, steps, errors, and JUnit fields are omitted |
| `ci_case_results.py` / `ci_suite_collection.py` | `apps/development-time/SitePulse/scripts/` | Expected SitePulse CI suites, native test-result adapters, attempt-aware artifact selection, count parity checks, and machine-readable per-case collection for `ci_test_report.py`; `unittest_json_runner.py` retains unittest discovery while exporting cases |
| `mutation_scenarios.py` | `apps/development-time/SitePulse/scripts/mutation_scenarios.py` | Hand-designed mutation scenarios (`harness/mutation/scenarios.toml`) that plant one realistic bug each and report whether the suites kill it (`list`, `validate` drift check, `baseline`, `run` with mutation score, `restore`, `--changed` change-aware runs, `--strict` non-zero exit) |
| `ci_mutation_report.py` | `apps/development-time/SitePulse/scripts/ci_mutation_report.py` | Aggregates individual layer mutation reports from scheduled CI into a consolidated Markdown summary for `$GITHUB_STEP_SUMMARY` and JSON artifact |
| `pages_site.py` | `apps/development-time/SitePulse/scripts/pages_site.py` | Stages the reviewed GitHub Pages report archive and checks its routes and deployment identity |
| `product_status.py` | `apps/development-time/SitePulse/scripts/product_status.py` | Product status of the test report: coverage per epic (passing, failing, automated without a CI result, planned), trends of stories/scenarios/automation from git and the published runs, recent additions; the `gh-pages` site's `index.html` |
| `rust_standards_lint.py` | `apps/development-time/SitePulse/scripts/rust_standards_lint.py` | Rust standards §10–16: domain purity, layering, no inline email/Turkish-fold/IBAN rules, static regexes, explicit rounding, no floats, hashing only in `domain::fingerprint`, English identifiers; ratchet on unwrap/expect/String errors/pool branches/unformatted files (gate `rust-standards-lint`) |
| `memory_persistence_lint.py` | `apps/development-time/SitePulse/scripts/memory_persistence_lint.py` | Catching discarded database results |
| `tenant_isolation_lint.py` | `apps/development-time/SitePulse/scripts/tenant_isolation_lint.py` | Multi-tenant guardrails: handlers pin `site_id` through `TenantScope`, path object ids are ownership-checked, no guessed tenants, service transactions call `tx_bind_tenant`, every tenant-keyed table has row-level security (gate `tenant-lint`) |
| `tenant_operation_inventory.py` | `apps/development-time/SitePulse/scripts/tenant_operation_inventory.py` | Validates that generated OpenAPI operations match registered Rust routes and have an explicit tenant-applicability classification. Inventory completeness is separate from runtime authorization evidence. |
| `lock_scope_lint.py` | `apps/development-time/SitePulse/scripts/lock_scope_lint.py` | No guard on the global `AppState` lock held across database/network I/O (gate `lock-lint`) |
| `security_lint.py` | `apps/development-time/SitePulse/scripts/security_lint.py` | Static security guardrails (gate `security-lint`): tracked credential files, hard-coded secrets, workflow permissions and untrusted input, unpinned images, reviewed public routes, guarded development routes, permissive CORS, weak crypto, client token storage, unsafe Python, error-leak ratchet (`security_lint_baseline.json`) |
| `dependency_audit.py` | `apps/development-time/SitePulse/scripts/dependency_audit.py` | Audits `Cargo.lock` and `pubspec.lock` against OSV advisories; allowlist with expiry (`dependency_audit_allowlist.json`); workflow `Security audit` |
| `db_verify.py` | `apps/development-time/SitePulse/scripts/db_verify.py` | Inspecting and auditing a database (parameterised; non-zero exit on issues) |
| `token_guard.py` | `scripts/token_guard.py` | Claude Code hook (`.claude/settings.json`) that denies context-flooding calls (large `cat`/`Read`, `ls -R`, unfiltered `find`, full-size screenshots) and warns on oversized Bash output |
| `issue_claim.py` | `scripts/issue_claim.py` | Claim/release/inspect issues (and `sync` the labels to the delivering PR with `--pr`) with `in progress` + `claim:<harness>/<session-id>` labels so concurrent agent harnesses identify each other |
| `cargo_target_pool.py` | `scripts/cargo_target_pool.py` | Pool of leased Cargo target-dir slots so parallel agent worktrees share bounded, warm build output (`run -- <cmd>`), plus `measure`, `status`, `sweep`, `watchdog` (free-space guard) and `clean-worktree` |
| `cargo_target_benchmark.py` | `scripts/cargo_target_benchmark.py` | Compare SitePulse Cargo profiles, record sampled allocation peaks on leased slots, and verify warm cache reuse across source trees |
| `pr_review_watch.py` | `scripts/pr_review_watch.py` | GitHub webhook or quiet `gh` watcher for reviewer and author sessions. Reviewer uses `--seen` and `--seen-activity`; author uses `--author-pr N --snapshot` and `--after FILE`. Supports `--json` and `--timeout`. |
| `pr_review_queue.py` | `scripts/pr_review_queue.py` | Reviewer's one-shot check: lists open PRs that need a review (not draft, CI finished, no final bot verdict on the current head) with the reason (`new`, `new_head`, `unfinished`); `--json` for all buckets |
| `review_bot.py` | `scripts/review_bot.py` | Post PR reviews (approve / request changes / comment) as the `local-reviewer-agent` GitHub App, pinned to the reviewed head SHA; config from the untracked `.env` (`REVIEW_BOT_*`) |
| `harness_cli.py` | `apps/development-time/SitePulse/harness/harness_cli.py` | Task-scoped verification and evidence (`--record` in CI only) |
| `hash-password` | `apps/development-time/SitePulse/backend/src/bin/hash_password.rs` | argon2id hashes for seeds and resets |


## Registered workspace orchestration tool

`python3 scripts/development_harness.py --help` provides durable run planning/execution (Docker gateway workers or T3 child sessions via `t3-dispatch`/`t3-submit`), candidate-bound evidence, cancellation/recovery and evaluation. Reuse it instead of scratch orchestration scripts. Guide: [apps/development-time/SitePulse/docs/engineering-process/engineering-harness.md](../../../apps/development-time/SitePulse/docs/engineering-process/engineering-harness.md); role workflow: [team-orchestration](../team-orchestration/SKILL.md). Registration and examples: `skills.md` section 6.
