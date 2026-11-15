# Antigravity Workspace Directives: AI-Powered Engineering

Welcome Antigravity Agent. This workspace implements advanced agentic software engineering paradigms to mitigate the stochasticity of Large Language Models.

The workspace centers on **SitePulse**, a residential site platform built using Spec-Driven Development (`.specify`), Task DAG dependency graphs, and a closed-loop Maker-Checker verification harness under `apps/development-time/SitePulse/`.

---

## Workspace Rules & Operational Constraints

1. **Context Boundary Awareness**:
   - When modifying files under `apps/development-time/`, apply the rules defined in [.agents/rules/development-time-inference.md](file:///.agents/rules/development-time-inference.md).
   - When a task changes SitePulse behaviour (backend, Flutter, e2e tests or `.specify/features`), apply the rules defined in [.agents/rules/test-execution-records.md](file:///.agents/rules/test-execution-records.md): record the test run that verifies the task (rule 13).
   - When modifying Flutter/Dart code under `apps/development-time/SitePulse/flutter/`, apply the rules defined in [.agents/rules/flutter-components.md](file:///.agents/rules/flutter-components.md) and use the shared components catalogued in [flutter-reusable-components](file:///.agents/skills/flutter-reusable-components/SKILL.md) (design-system widgets, `SpMoneyFormField`/`MoneyInput`, `sp_clipboard.dart`, `showSpSelection`, `readDecimal`, resident directory). Reuse or extend a shared component before writing a local one; `scripts/flutter_reuse_inventory.py --check` (gate `flutter-reuse`) must pass.
   - When modifying Rust components (`*.rs`, `Cargo.toml`), apply the rules defined in [.agents/rules/rust-standards.md](file:///.agents/rules/rust-standards.md) and [apps/development-time/SitePulse/docs/standards/RUST_STANDARDS.md](file:///apps/development-time/SitePulse/docs/standards/RUST_STANDARDS.md) (operationalizing [rust-skills](file:///.agents/skills/rust-skills/SKILL.md)). Architect and Developer agents are strictly bound to Clean Architecture, zero Clippy warnings (`-D warnings`), zero panics, persistence safety, and `rust_decimal` precision. For the SitePulse backend, follow the [sitepulse-rust-backend](file:///.agents/skills/sitepulse-rust-backend/SKILL.md) workflow and pass `scripts/rust_standards_lint.py`.

2. **Invariants & Decimal Precision**:
   - Monetary or calculation fields MUST use high-precision decimals (`decimal` in C#, `rust_decimal::Decimal` in Rust, `Decimal` in Dart/Python, `BigDecimal` in Java, `NUMERIC(15,2)` in SQL). Never introduce floating-point arithmetic in financial domains.

3. **Verification Before Delivery**:
   - Always run the relevant automated test suite before concluding any code modification:
     - SitePulse harness tests: `python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests`
     - SitePulse full gate run (build, clippy, Rust/Flutter tests, money fixtures, schema and API system checks): `DB_PASS=... python3 apps/development-time/SitePulse/scripts/run_tests.py` (`--skip-db` without PostgreSQL; skipped gates are reported, never counted as passed)

4. **English-Only Development Language**:
   - All source code, identifiers, types, schemas, tables, columns, variable names, function names, API route paths, tests, and code comments MUST be authored strictly in English. Non-English identifiers in source code are strictly prohibited.

5. **Tooling & Automation Language Preference (Python Over Bash)**:
   - Prefer Python for developer tools, verification scripts, harness utilities, data inspectors, and automation scripts over Bash. Python provides structured typing, native JSON/data parsing, cross-platform stability, and testability.

6. **Tool Crystallization & Continuous Improvement**:
   - When developing features, fixing bugs, or executing complex verification tasks, evaluate whether a custom script, diagnostic query, or verification procedure has recurring value across future development iterations.
   - If so, do not leave it as an ephemeral scratch script; crystallize it into a permanent, production-grade Python tool under `scripts/`, support `--help` and `--json`, document it in [skills.md](file:///skills.md), and register it in [.agents/skills/continuous-improvement-tooling](file:///.agents/skills/continuous-improvement-tooling/SKILL.md) so subsequent iterations can immediately leverage it.

7. **Graphify Knowledge Graph Navigation & Maintenance**:
   - This workspace uses a Graphify knowledge graph under `graphify-out/` to map architecture, code relationships, and cross-file dependencies.
   - **Querying the Graph**:
     - For broad context and architecture questions, consult the graph before heavy grepping: `graphify query "<question>"`
     - To trace shortest paths and component interactions: `graphify path "<ComponentA>" "<ComponentB>"`
     - To explain a specific module, node, or concept: `graphify explain "<Concept>"`
     - For high-level architecture overviews, consult [graphify-out/GRAPH_REPORT.md](file:///graphify-out/GRAPH_REPORT.md) or navigate `graphify-out/wiki/index.md` (if generated).
   - **Maintenance & Updates**:
     - After completing code modifications, keep the graph synchronized with: `graphify update .` (local Tree-sitter AST, zero LLM cost).
     - To re-index the full repository with docs and images, ensure `GEMINI_API_KEY` is loaded (e.g. from `.env`) or run `graphify . --code-only` for fast, keyless local AST extraction.

8. **Standardized Logging & Correlation Directives**:
   - All logging must comply with [apps/development-time/SitePulse/docs/standards/LOGGING_STANDARDS.md](file:///apps/development-time/SitePulse/docs/standards/LOGGING_STANDARDS.md) and [.agents/rules/logging-standards.md](file:///.agents/rules/logging-standards.md).
   - In backend Rust code: use `tracing::` structured macros (`info!`, `warn!`, `error!`); raw `println!`, `eprintln!`, `dbg!` are strictly forbidden in production modules.
   - In frontend Flutter code: use `AppLogger` (`lib/domain/logging/app_logger.dart`); raw `print()` is forbidden, and ad-hoc `debugPrint` is restricted and ratcheted toward zero.
   - Correlate requests end-to-end via `x-request-id` headers and `trace_id` fields in error envelopes. Never log sensitive credentials or raw PII.
   - Harness verification gate `logging-standards-lint` (`scripts/logging_standards_lint.py`) must pass on every check.


9. **Token Budget Discipline**:
   - Every tool result stays in context and is re-sent on every later step; keep results small.
   - Locate before reading: `graphify query`/`explain`, `rg -l`, or `grep -n ... | head -30`; then read only the needed range (`sed -n 'A,Bp'`, Read with offset/limit). Never `cat` whole large files, `ls -R`, or unbounded `find`.
   - Run gates in compact form: `run_tests.py --summary` (or `--json --summary`); pipe other build/test output through `tail -40` or a failure filter.
   - Browser checks: prefer `get_page_text`/`read_page`; screenshots only when visual layout matters, with `scale` ≤ 0.5.
   - One task per session; `/compact` or start fresh once context passes ~200K tokens. Use Sonnet for routine edits, test runs and exploration; reserve Opus for design-heavy work.
   - The `.claude/settings.json` hook (`scripts/token_guard.py`) denies known-wasteful calls and warns on oversized output; follow its suggestion rather than working around it.

10. **Issue Selection & Concurrent Agent Work**:
   - When choosing an issue to work on, select only issues without the `in progress` label. An issue with this label may already be under active work by another agent.
   - Recheck the issue's current labels immediately before starting work. If it is labeled `in progress`, skip it and choose another eligible issue.

11. **Worktree Lifecycle (Start From Latest Master, Clean Up After the PR)**:
   - **Before starting each task**, pull the latest `master` and create a new worktree on it, with a new branch for that task:
     - `git fetch origin master`
     - `git worktree add -b <branch> <worktree-path> origin/master`
     - Never start a new task in a worktree left over from earlier work, and never stack unrelated work on another task's branch or PR.
   - **After the task's PR is green (see rule 12), you MUST remove your worktree.** Cleanup is part of the task, not optional, and this rule is the permission to do it:
     - "Green" means every PR check passed, or no check ran for the PR (for example, a docs-only change that no workflow triggers on). It does not mean "checks still pending".
     - "Your worktree" is the worktree your task's work was done in, whether you created it or your host (Claude Code app, IDE, harness) created it for your session. Never remove a worktree used by another agent or task.
     - Before removing, verify that every change is committed, the branch is pushed (`git status` is clean and the branch has no unpushed commits), and the PR exists.
     - Remove it with `git -C <main-checkout> worktree remove <worktree-path>` (run from the main checkout, or any directory outside the worktree). The branch and the PR remain. If review feedback arrives later, recreate a worktree from the PR branch (`git worktree add <worktree-path> <branch>`).
     - If your session runs inside the worktree and your host manages it (so you cannot remove it from where you are), use the host's worktree cleanup if one is available; otherwise state in your final report that the worktree is ready to delete, with its path and branch. Do not report "not allowed by rule 11".
   - **After a merge into `master`**, remove any worktree that still exists for that branch in the same way, and run `git worktree prune` to drop stale entries.
   - Never force-remove a dirty worktree. Preserve any uncommitted or untracked work by committing and pushing it, or by resolving it, before cleanup.

12. **Wait for PR Test Results Before Completing a Task (All Agents)**:
   - Applies to every agent (Claude, Antigravity/Gemini, Codex, Copilot, or any other) working in this repository.
   - **Every task is finalized by opening a PR against `master`.** Never leave finished or partial work only on a local or pushed branch; work that is not in a PR is not delivered. If the task cannot be finished, still push and open a draft PR (`gh pr create --draft`) that states what is done and what remains.
   - Opening a PR does not complete the task on its own. After pushing, wait for the PR's CI checks (`.github/workflows/`) to finish: `gh pr checks <pr> --watch` (or `gh pr checks <pr>` until no check is pending).
   - **If any check fails**, the task is still yours: read the failing log (`gh run view <run-id> --log-failed | tail -80`), fix the cause in the same worktree and branch, run the relevant local suite (rule 3), push, and wait for the checks again. Repeat until every check passes.
   - Never report a task as complete, and never remove its worktree, while a check is failing or still running. Do not skip, disable, or weaken tests or workflows to make a check pass.
   - If a failure is unrelated to your change (for example, also failing on `master`, or an infrastructure outage), do not paper over it: report it with the failing check name and log excerpt, and leave the task open for the user to decide.
   - Once every check passes (or no check ran for the PR), the task is complete and you must remove your own worktree as described in rule 11.

13. **Test Runs and the Test Report (All Agents)**:
   - Applies to every agent, for every task that changes SitePulse behaviour (backend, Flutter, e2e, or `.specify/features`). Docs-only tasks are exempt. Full procedure: [.agents/rules/test-execution-records.md](file:///.agents/rules/test-execution-records.md).
   - Acceptance criteria live as Gherkin scenarios under `apps/development-time/SitePulse/.specify/features/EPIC-xx/` (conventions: [.specify/features/README.md](file:///apps/development-time/SitePulse/.specify/features/README.md)). When a task adds or changes behaviour of a migrated epic, add or update the scenario (`@SC-xx-yy-nn`) in the same change; a scenario you cannot automate yet is tagged `@pending`, never omitted.
   - **GitHub CI is the test report.** `sitepulse-ci.yml` runs the suite on every PR; job `test-report` (`scripts/ci_test_report.py`) puts the stats on its job summary and uploads artifact `e2e-test-report` (markdown report, HTML dashboard, merged execution records); each e2e shard also uploads `e2e-shard-N` (junit, traces, logs). In the PR's `## Test report` section, link the CI run. A failing test fails the required `verify` check, so rule 12 covers it.
   - **Committing a recorded run per task is a switch, currently off**: `require_recorded_run` in `apps/development-time/SitePulse/.specify/executions/settings.json` (`$SITEPULSE_REQUIRE_RECORDED_RUN=1|0` overrides it). While off, gate `test-run-recorded` (`feature_traceability.py check --require-run`) passes with a "switched off" note. When switched on, before opening the PR run and record `python3 apps/development-time/SitePulse/scripts/gui_e2e.py run --affected --record --task "<task>"`, commit the new `.specify/executions/runs|reports` files, paste `feature_traceability.py task-report` into the PR, and the gate fails a behaviour branch without a passing recorded run. Never edit or delete recorded runs.
   - In the durable engineering harness, workers never write run records: the tester role may write `.specify/features` and `e2e/steps|tests`, the `sitepulse-full` gate records the run, and the operator exports it with `development_harness.py captures <run> --output <repository>`.

## Durable engineering harness

For persistent multi-role development runs, use `python3 scripts/development_harness.py --help` and the [team-orchestration skill](.agents/skills/team-orchestration/SKILL.md). Setup, execution boundaries and recovery are in [apps/development-time/SitePulse/docs/engineering-process/engineering-harness.md](apps/development-time/SitePulse/docs/engineering-process/engineering-harness.md). Preserve user changes; create runs from an explicit committed revision. Model targets require live capabilities and configured eligibility; a plan alone does not execute agents.
