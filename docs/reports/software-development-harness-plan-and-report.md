# Adaptive Software Development Harness: Verified Plan and Review

Reviewed: 2026-11-08. Implementation update: sequential runtime delivered; live pilot and production rollout remain pending. Sections 1–10 retain the pre-implementation review baseline; section 11 records current implementation and validation. Existing unrelated application changes were not modified.

## 1. Assessment and corrections

The repository has useful verification infrastructure and a five-role routing prototype. It does **not** yet demonstrate an autonomous development team, validated live model routing, safe parallel integration, or production readiness. Build on the SitePulse harness rather than duplicating it.

The harness should coordinate Product Owner, Business Analyst, Backend Developer, Frontend Developer and Tester responsibilities, choose an available model appropriate to each task, and deliver an integrated change with reproducible evidence. Agents propose work; tools enforce observable checks; humans retain decisions outside the run's authorization. Passing tests reduces risk but does not establish correctness for all inputs.

### Verified findings and disposition

| ID | Severity | Finding | Correction / remaining work |
| --- | --- | --- | --- |
| R01 | High | The original calls CLI output executable orchestration. `team_orchestrator.py` only prints a plan and candidate payloads. | Corrected this report. Execution, handoffs and payload validation remain implementation work. |
| R02 | High | Model names and settings differ between report, skill and script; none of those files discovers availability. | Replace the report's fixed model matrix with capability-based routing. Existing script assignments remain unvalidated configuration candidates. |
| R03 | High | The claimed weighted 0–100/AST classifier is absent. The script uses keyword/flag precedence and estimated file count. Weights and AST inputs were never defined. | Use the explicit rules in section 4 as the initial target; AST analysis is a later enhancement. |
| R04 | High | `--complexity low` overrides an explicit financial flag. | Require risk floors in the future router; current prototype must not be used as a security or financial risk boundary. |
| R05 | Medium | Twenty files classify as HIGH, although the old report assigned more than twelve to CRITICAL; negative file counts are accepted. | Remove contradictory scoring claims. Validate input and document one set of thresholds. |
| R06 | Medium | Programmatic unknown roles silently produce an empty pipeline. All five roles run by default even for a typo. | Add strict validation and task-sensitive role activation. CLI role choices already reject unknown names. |
| R07 | High | DAG validation, gate execution and attempt-budget status handling already exist in SitePulse. | Reuse their behavior and tests through project adapters; do not describe them as wholly new deliverables. |
| R08 | High | Existing evidence overwrites `<task>.json`; it records a commit and dirty flag, not the exact dirty diff. It is neither append-only nor cryptographically authenticated. | Add per-attempt records, content hashes, exact candidate identity and protected storage. Atomic rename alone does not supply these properties. |
| R09 | High | Worktrees were described as a security sandbox. They share the host and do not isolate credentials or processes. | Specify separate execution isolation, permissions and network controls. |
| R10 | High | The report omitted integrated-candidate verification after parallel changes. | Require a fresh combined candidate and rerun applicable checks after every integration change. |
| R11 | Medium | `scripts/check_coverage_delta.py` is absent. The universal 80% threshold, 120-second timeout and blanket zero-warning claims do not reflect the gate catalogue. | Reuse actual gates. Define coverage policy only after baseline collection; use per-gate timeouts. |
| R12 | Medium | Promised latency/cost reductions and zero escaped regressions have no benchmark evidence. | Treat benefits as hypotheses. Add paired evaluations and explicit acceptance measures. |
| R13 | High | The original proposed recording model reasoning traces and automatic rollback. | Store concise decision summaries and observable actions. Preserve failed work for inspection; define transactional compensation for external effects. |
| R14 | Medium | Schedule implied a committed start, staffing and production outcome without assumptions. | Use relative weeks, staffing assumptions, phase exit criteria and contingency. |

These findings are corrected in the plan. Prototype defects identified above remain open implementation tasks; this report revision does not implement the runtime.

## 2. Repository evidence and reuse boundary

Paths below are relative to the repository root. Source inspection is the authority; the Graphify query was used for navigation.

| Component | Verified behavior | Limit / extension |
| --- | --- | --- |
| `scripts/team_orchestrator.py` | Five default roles, optional architect/general developer, keyword/flag classifier, text/JSON plan generation. | No dispatch, live capabilities, cost accounting, DAG execution or result validation. Generated payloads are not proven compatible with the live API. |
| `apps/development-time/SitePulse/harness/graph/task_dag.py` | Dependency/cycle validation, known-gate and acceptance-ID checks, runnable-task listing, atomic document replacement. | Atomic replacement is not multi-writer concurrency control; add revision checks or transactional coordination. |
| `apps/development-time/SitePulse/harness/loop/verification_gates.py` | Real subprocess gates, diagnostics, individual acceptance-test result parsing, configurable timeouts. | Project-specific commands; Flutter analysis currently allows warnings/infos. Global gates are not the entire test suite. |
| `apps/development-time/SitePulse/harness/loop/loop_runner.py` | Aggregates gates/tests, rejects empty verification, maps failed attempts to FAILED/BLOCKED, writes evidence. | Does not launch corrective agents or automatically change models. Evidence currently replaces the previous attempt. |
| `apps/development-time/SitePulse/harness/harness_cli.py` | Status/next/gates/verify, CI-restricted recording with an explicit local override, dependency checks when recording. | Recording is separate from autonomous scheduling and independently trusted CI attestation. |
| `apps/development-time/SitePulse/harness/rtm_validator.py` and `.specify/` | Existing requirements/task/test traceability infrastructure. | Extend and verify references against the integrated candidate. |
| `apps/development-time/SitePulse/scripts/run_tests.py` | Existing full verification entry point. | Keep database-dependent checks explicit; skipped checks are not passes. |

Review validation: `python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests` passed **70 tests** on 2026-11-08. These tests exercise harness logic with fixtures and substituted commands; they do not prove real provider execution or full application health. Reproduced R04–R06 using direct calls to `build_iteration_pipeline`. No application code was changed and no full Rust/Flutter/database suite was run for this documentation revision.

## 3. Roles, contracts and execution flow

| Role | Input | Required output | Authority |
| --- | --- | --- | --- |
| Product Owner | User request, business context, existing backlog | Scope, exclusions, priority, measurable acceptance criteria, unresolved decisions | Proposes scope; cannot invent answers to unresolved business decisions. |
| Business Analyst | Scope, current domain behavior, existing contracts | Domain rules, edge cases, data dictionary, versioned API/event/schema contracts where applicable | Proposes contract revisions; cannot change agreed scope silently. |
| Backend Developer | Accepted contract version, task dependencies, repository rules | Implementation, migration strategy where needed, focused tests and change summary | Writes only assigned paths in its checkout; no production database privileges. |
| Frontend Developer | Acceptance criteria, design system, contract version | UI, state/error/loading/empty behavior, accessibility and responsive checks | Reuses shared components and stays within assigned paths. |
| Tester | Acceptance criteria, contract, exact integrated candidate | Independently designed tests, defects, gate evidence and residual-risk assessment | May add tests; cannot weaken required gates or declare its own exceptions approved. |

Architect review is conditional for cross-cutting design, security, persistence or concurrency changes. A human project owner resolves product ambiguity; a technical owner accepts architecture and release risk. Agent personas do not substitute for accountable owners.

Execution sequence:

1. Intake repository rules, authorization, task scope and baseline revision. Snapshot explicit local changes if they are required inputs; never reset or clean the user's checkout.
2. PO refines scope; BA refines domain rules and applicable contracts. Record unresolved decisions and continue only independent work.
3. Produce a dependency DAG with task IDs, role, allowed paths, contract hash, acceptance-test references, estimated risk, gate profile and budgets. Omit unnecessary roles for small changes while preserving their required responsibilities.
4. Default to sequential implementation until integration is reliable. Enable frontend/backend parallel work when their contract version is accepted, write ownership is disjoint, and dependencies permit it. Contract revisions invalidate dependent work and evidence.
5. Developers work in isolated checkouts supplied by the execution backend. Tester can design cases early and verifies the combined candidate later. A tester writing tests also needs an isolated writable checkout.
6. An integration coordinator combines changes on a known base, handles conflicts, and produces a candidate commit. Run contract, system and UI checks on that candidate, not only individual branches.
7. Required passing checks and independent review yield READY_FOR_REVIEW. Merge or deployment requires existing session/project authorization; its completion is a separate state.

A versioned task envelope must contain `schema_version`, `run_id`, `task_id`, `attempt_id`, dependencies, role, objective, input artifact hashes, base revision, allowed paths/tools, risk reasons, target configuration, token/time/cost limits and expected outputs. Every result must reference its input envelope and exact output revision, include changed paths, artifact references, checks and unresolved issues, and pass schema validation before consumption. Text saying “done” is insufficient.

## 4. Model routing and complexity

Model identity is configuration, not architecture. No current model availability, price, speed or relative quality claim is made here. At execution time, query the execution backend's capabilities and validate provider, model, settings, tool support, context limits and policy eligibility. In T3, use `orchestrator_capabilities` before the first delegation and construct requests from its supported schema; availability and account access still require validation. Do not silently replace a user-requested model or provider when unavailable.

Initial proposed risk rules (not implemented in the current CLI):

- CRITICAL floor: money movement or financial calculations, destructive persistence changes, distributed consistency or race-condition correctness.
- HIGH floor: authentication/authorization, sensitive-data access, ordinary schema migrations, cross-service contracts, or more than six affected files.
- MEDIUM: routine API/UI behavior or three to six affected files without higher-risk factors.
- LOW: at most two files with mechanical, well-understood behavior and no higher-risk factor.

File count estimates are secondary; uncertainty raises the tier or triggers investigation. A larger file count alone does not prove criticality. Compute `effective_tier = max(assessed_tier, requested_tier, risk_floor)`; lowering a risk floor requires an explicit, recorded policy exception. Reject negative counts, empty tasks, unknown roles and unsupported settings. Explain the observed risk signals, uncertainty and chosen target. Reassess against the actual diff before delivery.

Choose a model separately for each role/subtask. Use a configured fast tier for bounded low-risk work, a standard coding/reasoning tier for routine implementation, and the strongest **evaluated and eligible** tier for complex/high-risk work. These are capability classes, not promises about brand names. A tester's required capability follows the risk of what it checks, not the apparent simplicity of running a command. Deterministic checks run directly without an LLM.

Selection objective: minimize measured expected cost per accepted task, subject to quality, privacy, deadline and tool constraints. Maintain a versioned registry of eligibility, supported options, benchmark results, price effective dates and context limits. Monetary telemetry uses decimal arithmetic. Cache only with tenant, input, policy, prompt and toolchain versions in the key.

Escalation policy: classify failures before retrying. A code defect gets diagnostics and a bounded repair attempt; unavailable tools or credentials require environment repair; outages use bounded backoff; missing product decisions need human input. Propose promotion after two unsuccessful code-repair attempts, within configured limits and provider authorization. Stop after at most three repair attempts by default, or earlier when time/cost limits are reached. Record counts separately for implementation, repair and transient retries. Never restart budgets by creating a replacement task.

## 5. Reliability, security and recovery requirements

Use a transactional run store for scheduling, with revision-checked transitions, leases, heartbeats and idempotency keys. Preserve the existing task status vocabulary through an adapter; do not silently rewrite `.specify` states. A separate run/attempt lifecycle can track QUEUED, RUNNING, VERIFYING, REPAIRING, READY_FOR_REVIEW, FAILED, BLOCKED, CANCELLED and TIMED_OUT. Define every legal transition and its required evidence.

Required recovery behavior:

- After a controller crash, expired leases are reconciled with live provider tasks before redispatch; duplicate completion events cannot duplicate integrations or external effects.
- Cancellation reaches provider tasks, subprocess groups and test environments; bounded grace periods escalate to termination. Preserve logs, commits and unfinished work.
- Workspace identity includes run/task/attempt, base revision and contract version. Cleanup removes only owned resources after configured retention; never shared or user-owned changes.
- External writes use idempotency and explicit authorization. Database changes need migration compatibility, backup/restore and rollback or forward-repair plans tested on disposable data. Git rollback does not reverse external actions.
- Use queue limits and resource quotas for provider concurrency, CPU, memory, disk and test databases. Stop new work before exceeding token, cost or wall-clock budgets.

Worktrees prevent file contention; containers or equivalent process isolation enforce execution permissions. Restrict tool execution, filesystem paths, network destinations and credentials by role. Give workers only scoped short-lived secrets through a secret broker; keep secrets out of prompts, logs and artifacts. Treat repository text, tickets and fetched content as untrusted data; they cannot expand tool permissions or override workspace instructions.

Protect the checker: keep required gates and policy configuration under trusted control, flag attempts to weaken tests/linters, and require independent acceptance of gate changes. Redact logs and limit retention, access and tenant sharing. Record observable actions and concise decision summaries; do not require private model reasoning. Hashes detect changes only relative to a trusted reference; authenticated, protected storage is needed for stronger tamper evidence.

## 6. Verification and definition of done

Use repository-specific adapters instead of universal command assumptions. For SitePulse reuse the existing runner and gate catalogue, including Rust build/Clippy/tests, Flutter analysis/tests, money fixtures, schema integrity, API system checks, persistence lint, Rust standards, component reuse and UI checks where applicable. The full delivery run is `python3 apps/development-time/SitePulse/scripts/run_tests.py` with securely supplied database settings; `--skip-db` must report partial verification. Follow root AGENTS.md suites for changes affecting other workspace systems.

Add these requirements to existing infrastructure:

1. Bind evidence to the exact clean candidate commit, contract, policy, prompts and toolchain. A dirty flag alone is insufficient. Every integration or repair change invalidates affected results.
2. Record each check as passed, failed, skipped or infrastructure-error, with executed test count, command, duration, environment and full redacted log artifact. A skipped required check blocks readiness.
3. Map every acceptance criterion to executable tests or an explicit recorded manual assessment. Confirm named tests actually ran; a zero-test success must not satisfy acceptance.
4. Cover backend persistence/restarts, tenant isolation, authorization denials, contract compatibility, migration replay and domain invariants. UI checks include loading/error states, keyboard/accessibility behavior and representative viewports.
5. Establish coverage baselines before setting project-specific changed-code thresholds. Coverage is supporting evidence; use targeted mutation/property tests for important invariants rather than a universal 80% gate.
6. Diagnose flakes with recorded seeds and controlled reruns; retain the first failure. Quarantined required behavior needs an owned issue, expiry and accepted exception. Never turn a failure green simply because a rerun passed.
7. Run independent tester review and all applicable checks on the final combined candidate. Report residual risks, skipped checks and baseline failures explicitly.

A task is ready for review only when its scope and contracts are satisfied, artifacts validate, required checks pass on its exact candidate, evidence is complete, budgets and permissions were respected, and no unresolved blocking defect remains. This is not a guarantee of zero defects or permission to release.

## 7. Evaluation and measurable pilot exit

Before enabling autonomous changes, create a versioned set of at least 30 representative tasks spanning mechanical edits, full-stack features, auth, migrations, financial invariants and deliberately failing environments. Use held-out tasks to evaluate routing; distinguish harmful under-classification from costly over-classification. Review every high-risk case manually.

Compare the routed harness and a fixed capable-model baseline on the same starting commits, acceptance criteria, tools and budgets. Report repetitions and sample size, medians and tail latency, success within budget, cost per accepted task, reviewer correction effort, escaped defects and routing under-classification. Include failed runs, cached tokens and tool infrastructure costs. Do not infer performance guarantees from three pilot epics.

Proposed pilot exit criteria, to be ratified after baseline measurement:

- Every accepted pilot change has complete candidate-bound evidence and passing required checks.
- No known critical/security defect or risk-floor bypass in the evaluation set; remaining defects have owners and disposition.
- Crash/restart, cancellation, duplicate callback, unavailable model, budget exhaustion, conflict and secret-redaction scenarios pass deterministic fault-injection tests.
- Route quality meets a pre-agreed non-inferiority tolerance against the fixed-model baseline. Report uncertainty; small samples cannot demonstrate rare-event safety.
- Cost and lead-time goals are set from measured baselines. The old 40% latency and 50% token savings figures are removed as unsupported.

## 8. Delivery plan and ownership

Estimate: **10 working weeks for a constrained pilot**, assuming two full-time engineers, a half-time tester/platform engineer and available PO/BA/security reviewers. Agent roles are not staffing capacity. Provider access, isolated CI capacity and representative tasks must be available. Allow a further two to four weeks for hardening or holiday/capacity disruption. Production rollout is a later decision based on evidence. No calendar start date is committed.

| Phase | Timing | Accountable owner | Deliverables and exit criteria |
| --- | --- | --- | --- |
| Inventory and baseline | Week 1 | Technical lead + Tester | Confirm reuse boundaries, test existing harness, define supported project and baseline task set; approve scope, budgets and threat model. |
| Durable execution | Weeks 2–3 | Backend/platform engineer | Versioned envelopes, adapter around existing DAG/gates, attempt store, leases, isolated workspace lifecycle, cancellation; pass crash/duplicate-event tests. |
| Routing and provider integration | Weeks 4–5 | Platform engineer + Tester | Capabilities validation, risk floors, configuration registry, quotas, usage telemetry and bounded retry/escalation; pass unsupported-target and budget tests. |
| Role handoffs and integration | Weeks 6–7 | Full-stack engineer + PO/BA | Five role templates, contract hashes, selective activation, independent test design, candidate integration; demonstrate sequential full-stack flow before parallel flow. |
| Verification and evidence | Weeks 8–9 | Tester + platform engineer | Candidate-bound attempt history, traceability, trusted CI checks, protected logs, fault injection and sandbox review; complete final-candidate verification. |
| Evaluated pilot | Week 10 | Technical lead + Product Owner | Run held-out evaluation and three representative end-to-end feature trials, publish measured quality/cost/latency and outstanding defects; decide whether to expand. |

Security, evidence and minimum verification begin in the first phase; their later milestone denotes completion, not delayed introduction. Each phase depends on the prior exit criteria; re-estimate when an exit fails.

## 9. Prioritized implementation backlog and open decisions

| Priority | Issue | Owner | Acceptance evidence |
| --- | --- | --- | --- |
| P0 | Enforce risk floors and validate all router inputs | Router engineer | Financial+LOW cannot downgrade; invalid counts/tasks/roles rejected; table-driven boundary tests. |
| P0 | Validate live capabilities and delegation schema | Platform engineer | Unsupported models/options rejected before dispatch; requested provider never silently substituted. |
| P0 | Add durable attempts, leases and idempotency | Platform engineer | Controller restart and duplicate callbacks yield one logical completion and no duplicate external write. |
| P0 | Enforce tool/secret/network policy | Security/platform owner | Prompt injection cannot expand permissions; redaction and resource escape tests pass. |
| P0 | Integrate and verify combined candidate | Integration owner | Conflicting/shared-contract changes invalidate stale tests; fresh combined commit passes required gates. |
| P0 | Preserve per-attempt evidence | Platform engineer | Historical failures remain available; changed candidate cannot reuse a previous candidate's pass. |
| P1 | Add role-specific artifacts and handoffs | PO/BA + full-stack engineer | Schema-invalid or wrong-contract results block dependents; small tasks skip unnecessary agent calls. |
| P1 | Bound repairs, outages and cancellations | Platform engineer | Global budgets survive restart; cancellation stops owned workers; failed work is retained. |
| P1 | Register measured model policies and costs | Router engineer + Tester | Versioned eligibility and decimal cost data; evaluation includes failures and under-classified risk. |
| P1 | Refresh orchestration skill and CLI documentation | Tooling owner | Skill, script and report clearly distinguish planning from execution and use one tested routing policy. |
| P1 | Add pilot metrics and traceability | Tester | Every criterion has evidence; held-out evaluation and baseline results are reproducible. |
| P2 | Add AST-aware routing and broader adapters | Technical lead | Demonstrated improvement over simple rules without degrading high-risk classification. |

Decisions before implementation: choose the first project (proposed: SitePulse), confirm staffing/budget and provider/data-residency eligibility, assign human owners, and agree pilot quality tolerances. Start with sequential execution; parallelize only after integration exit criteria pass. External tracker integrations and dashboards are optional follow-on scope. The plan does not require a provider preference to be invented now.

## 10. Review boundaries

This review inspected the original report, the routing script, orchestration skill, SitePulse DAG/loop/gates/CLI, relevant tests and workspace rules, and queried the repository graph. It verified local behavior and consistency. It did not validate live provider availability, pricing, security certification, deployment readiness or full application behavior. Those are explicit work items with acceptance criteria above.


## 11. Implementation update (2026-11-08)

The implementation is available in `scripts/development_harness.py` and `scripts/engineering_harness/`. Setup, protocol details, deployment prerequisites and supported boundaries are in [the operating guide](../engineering-harness.md).

| Area | Delivered | Remaining qualification / follow-on |
| --- | --- | --- |
| Roles and handoffs | Five default role contracts, optional Architect, selective scope, input/candidate/contract hashes, independent Tester | Representative live feature evaluation and accountable human owners |
| Routing (R02–R06) | Validated registry, live capabilities, exact target constraints, risk floors, invalid-input rejection, post-diff risk reassessment, bounded escalation | Operator-evaluated model qualifications and current rates; richer AST classification |
| Durable execution | SQLite immediate claims, budget reservations, bounded leases, idempotent results, persistent attempts/deadlines, safe cancellation/reconciliation | Fleet-wide capacity management and operator retention/cleanup automation |
| Isolation (R09) | Digest-pinned Docker workers, assigned writable mounts, read-only root, no host credential forwarding, network isolation and per-container resource limits | Credential proxy/egress administration, disk quotas and deployment security review |
| Integration and verification (R07/R10/R11) | Sequential candidate commits, fresh committed-content export per gate, SitePulse runner adapter, positive test-count check, bounded gate repairs with dependent re-review | Parallel branch integration and project-specific disposable DB/browser infrastructure |
| Evidence (R08/R13) | Exclusive per-attempt files, content-linked append-only events, audit verification, redaction, preserved failures, concise summaries | Independently protected artifact storage/signing; no claim of host-operator-proof authentication |
| Model execution | Configurable Chat Completions gateway worker with bounded file tools, live model discovery and provider-reported usage; custom bridge protocol | Real account/proxy configuration and live provider compatibility tests; native provider transports where needed |
| Evaluation (R12/R14) | 36 deterministic routing regressions, paired cost/latency evaluation CLI, Docker/controller CI workflow | Held-out task set, measured acceptance tolerances, staffing and real pilot trials |

Validation completed:

- **37 new harness tests passed**, including a real Docker five-role run, filesystem/network restrictions, timeout/output-limit/cancellation checks, crash recovery, stale/duplicate results, budgets, gate repairs, evidence tampering, registry rejection and gateway tool-loop tests. The gateway tests use a simulated provider; no live account quality/cost claim is made.
- **36/36 routing regression cases matched**, with zero under-classifications in that synthetic set.
- Existing suites passed: **70 SitePulse harness tests**, **15 DevFactory tests**, **12 AuditGuard tests**, **13 TaskPilot tests**.
- Both the deterministic fixture image and gateway worker image built successfully. Python compilation, policy validation and diff whitespace checks passed.
- Graphify code graph was refreshed. It reported its existing missing SQL extractor dependency; SQL nodes were not refreshed by that extractor.

No SitePulse Rust/Flutter implementation was changed by this work, and its full database/browser application gate suite was not run as part of the root harness change. Concurrent unrelated workspace edits were preserved. The sequential runtime is implemented; the plan's production pilot, live credential infrastructure, parallel integration, signed artifact store and fleet dashboard are not represented as complete.
