# GitHub Copilot Custom Instructions: AI-Powered Engineering Catalog

Welcome to the **AI-Powered Engineering** repository. This repository demonstrates how to architect software systems that tame the stochasticity of Large Language Models (LLMs) and agentic workflows.

The repository is strictly divided into two distinct engineering paradigms:
1. **Runtime Inference Systems (`apps/runtime/`)**: AI models, heuristics, and agentic loops executing as part of the live production application to process business transactions and make runtime decisions.
2. **Development-Time Inference Systems (`apps/development-time/`, `factory/`)**: AI models, agents, and spec-driven harnesses used *during the software development lifecycle* to specify, architect, implement, verify, and manufacture software.

---

## 1. Universal Coding Standards

- **Precision & Invariants**: Never use `float` or `double` for financial, quota, or monetary calculations. In .NET use `decimal`, in Java use `BigDecimal`, in Python use `Decimal`, and in SQL use `NUMERIC(15,2)` or `DECIMAL`.
- **Test-Driven Rigor**: Every domain model, verification gate, and service must have matching unit tests with 100% assertions passing.
- **Fail Deterministically**: When probabilistic LLM extraction or agent reasoning is involved, never trust raw outputs without passing them through deterministic verification gates.

---

## 2. Working on Runtime Inference Systems (`apps/runtime/`)

*Primary targets: `apps/runtime/AuditGuard/`, `apps/runtime/TaskPilot/`*

When assisting with code inside `apps/runtime/`:

### A. Deterministic Verification Gates (Layer 2: Loop Engineering)
- Always pair model extractions with zero-tolerance deterministic gates (e.g., `MathVerifyGate`, `PolicyAuditGate`).
- Validate mathematical invariants:
  $$\sum \text{LineItems} == \text{Subtotal}$$
  $$\text{Subtotal} + \text{Tax} + \text{Tip} == \text{GrandTotal}$$
- Flag policy violations (e.g., alcohol keywords, single-meal limits, unapproved weekend travel, threshold ceilings).

### B. Anti-Rot Context & Error Compaction (Layer 1: Harness Engineering)
- Never pass raw, bloated stack traces or uncontrolled prompts back into model loops.
- Use structured context compactors (e.g., `ContextCompactor.cs`) that format concise, actionable feedback with exact numerical deltas (e.g., `Line items sum to $42.50, but subtotal stated $47.50 (Delta: -$5.00)`).

### C. Bounded Iteration Budgets
- Every runtime self-healing loop must have a hard iteration budget (default: maximum 3 iterations).
- If the model cannot self-heal within budget, transition cleanly to an escalation state (`RequiresHumanReview` or `Rejected`) rather than running runaway loops or burning tokens.

### D. Directed State Machine Flow (Layer 3: Graph Engineering)
- Follow typed graph nodes: `Ingest` $\rightarrow$ `Extract` $\rightarrow$ `VerifyMath` $\rightarrow$ `AuditPolicy` $\rightarrow$ `Reconcile` $\rightarrow$ `Terminal`.
- Maintain complete step telemetry (`AuditStepTrace`) with node name, iteration count, latency in milliseconds, and status.

---

## 3. Working on Development-Time Inference Systems (`apps/development-time/`, `factory/`)

*Primary targets: `apps/development-time/SitePulse/`, `factory/DevFactory/`*

When assisting with code inside `apps/development-time/` or `factory/`:

### A. Spec-Driven Development (Spec Kit / `.specify`)
- Always inspect the `.specify/constitution.md` and feature specs (`.specify/specs/*/spec.md`) before generating code.
- Follow the multi-agent persona roles:
  - **PM Agent**: User stories, functional requirements, acceptance criteria.
  - **UI/UX Agent**: Design tokens, Material 3 layouts, HTML prototypes.
  - **Architect Agent**: Clean Architecture boundaries, contracts, and DTOs.
  - **Developer Agent (Maker)**: Implementation code complying with contracts.
  - **Tester Agent (Checker)**: Unit/Integration tests verifying acceptance criteria.

### B. Task Dependency Graph (Task DAG)
- Check `.specify/tasks/task-dag.json` or run `python3 harness/harness_cli.py status` before implementing new features.
- Never write code for a task whose prerequisite tasks are still pending. Implement in topological dependency order.

### C. The Closed-Loop Maker-Checker Harness
- Code generated at development time must satisfy:
  1. **Syntax Gate**: AST validation (Roslyn AST for C#, `SyntaxGate` for Kotlin/Java) to prevent malformed syntax.
  2. **Compile Gate**: Zero compiler errors (`dotnet build`, `./gradlew assembleDebug`, `mvn compile`).
  3. **Verification & Test Gate**: 100% test pass rate with zero skipped/regressed tests.
- When an edit fails a gate, extract concise diagnostic feedback (e.g., file, line number, compiler error code) and provide targeted fixes.

---

## 4. GitHub Copilot Prompting Tips for this Repo

- **For Runtime Gates**: Ask Copilot:
  `"Implement a deterministic verification gate for [Domain Rule] that checks [Invariants] and returns a structured GateResult with detailed diagnostic deltas."`
- **For Spec-Driven Tasks**: Ask Copilot:
  `"Read .specify/constitution.md and task-dag.json task [task-id], then generate the production implementation and matching unit tests complying with the architecture contract."`
