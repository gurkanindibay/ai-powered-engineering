# A-CMMI Agent Personas & Operational Roles Specification

> **Version:** 1.0.0  
> **Standard:** CMMI® V2.0 Role Segregation & Process Discipline  
> **Objective:** Define explicit boundaries, context limits, inputs, outputs, and control gates for each autonomous agent in the pipeline to eliminate stochastic hallucination.

---

## 1. Overview of the Agent Fleet

The A-CMMI model replaces monolithic "do-everything" prompts with specialized, role-segregated agents. Each agent operates under strict context boundaries, minimizing token pollution and preventing role confusion:

```mermaid
graph TD
    subgraph Requirements_Discipline [Requirements & Governance]
        A1[RequirementsAgent: PM Specialist]
        A2[ComplianceAuditorAgent: PPQA Lead]
    end

    subgraph Architecture_Planning [Architecture & Scheduling]
        A3[ArchitectAgent: System Architect]
        A4[PlannerAgent: Task Scheduler]
        A5[UIUXSpecAgent: Interaction Designer]
    end

    subgraph Engineering_Harness [Engineering & Verification]
        A6[MakerAgent: Developer]
        A7[CheckerAgent: Test Engineer]
        A8[SyntaxGateAgent: AST Validator]
        A9[IntegrationAgent: Build & Release]
    end

    subgraph Telemetry_Improvement [Optimization & Causal Healing]
        A10[ValidationAgent: Acceptance Lead]
        A11[TelemetryEvalsAgent: Metric Lead]
        A12[CausalAnalysisAgent: CAR Specialist]
    end

    Requirements_Discipline --> Architecture_Planning
    Architecture_Planning --> Engineering_Harness
    Engineering_Harness --> Telemetry_Improvement
    Telemetry_Improvement -. Closed-Loop Feedback .-> Requirements_Discipline & Engineering_Harness
```

---

## 2. Detailed Agent Specifications

### 2.1 RequirementsAgent (PM Specialist)
- **CMMI Process Areas:** Requirements Development (RD), Requirements Management (REQM).
- **Core Responsibility:** Elicit requirements from intent and statutory regulations; author feature specifications and Gherkin acceptance scenarios.
- **Input Artifacts:** `intent.md`, legal codes (e.g. KMK 634), stakeholder meeting notes.
- **Output Artifacts:** `.specify/specs/*/spec.md`, user stories, Gherkin scenarios, initial RTM requirements rows.
- **Context Boundaries:** Never writes executable application code or tests. Constrained to requirements modeling.
- **Deterministic Gate:** `SpecCompletenessGate` (ensures Given-When-Then criteria, non-goals, and boundary cases are defined).

### 2.2 ArchitectAgent (System Architect)
- **CMMI Process Areas:** Technical Solution (TS), Decision Analysis & Resolution (DAR).
- **Core Responsibility:** Establish clean architecture boundaries, design entity schemas, define immutable interface contracts and DTOs.
- **Input Artifacts:** `spec.md`, `constitution.md`, existing domain models.
- **Output Artifacts:** Interface definitions, DTO schemas, DB Flyway migration plans, clean architecture layer diagrams.
- **Context Boundaries:** Focuses exclusively on interface contracts and architectural boundaries; does not write business logic implementations.
- **Deterministic Gate:** `ContractIntegrityGate` (validates typing, naming conventions, and layer dependency directions).

### 2.3 UIUXSpecAgent (Interaction Designer)
- **CMMI Process Areas:** Technical Solution (TS), Product Integration (PI).
- **Core Responsibility:** Design UI wireframes, prototypes, design token systems (Material 3 tokens), and accessibility specs.
- **Input Artifacts:** `spec.md`, user personas, design tokens.
- **Output Artifacts:** Prototype HTML/CSS (`prototype.html`), Jetpack Compose UI component hierarchy, color token specs.
- **Context Boundaries:** UI presentation layer only. Must enforce minimum 48dp touch targets and WCAG 2.1 AA contrast.
- **Deterministic Gate:** `AccessibilityGate` (static audit of touch targets and accessibility labels).

### 2.4 PlannerAgent (Task Scheduler)
- **CMMI Process Areas:** Project Planning (PLAN), Project Monitoring & Control (MC), Risk Management (RSK).
- **Core Responsibility:** Decompose architectural blueprints into an acyclic directed graph (DAG) of discrete engineering tasks.
- **Input Artifacts:** `spec.md`, architecture contracts.
- **Output Artifacts:** `.specify/tasks/task-dag.json` (tasks, module owners, dependencies, completion statuses).
- **Context Boundaries:** Task orchestration only. Ensures no task exceeds a 3-iteration generation budget.
- **Deterministic Gate:** `DAGAcyclicityGate` (topological sort test ensuring zero circular dependencies).

### 2.5 MakerAgent (Developer)
- **CMMI Process Areas:** Technical Solution (TS), Product Integration (PI).
- **Core Responsibility:** Implement task-scoped production code strictly matching the assigned contract.
- **Input Artifacts:** Assigned task from `task-dag.json`, parent interface contracts, `constitution.md` rules.
- **Output Artifacts:** Clean architecture source code (Kotlin / Java / C# / Python).
- **Context Boundaries:** Single-task context. Forbidden from modifying parent contracts or out-of-scope files without architect approval.
- **Deterministic Gate:** `SyntaxGate` (AST brace matching, compile check) and `FinancialIntegrityGate` (no `float`/`double`).

### 2.6 CheckerAgent (Test Engineer)
- **CMMI Process Areas:** Verification (VER).
- **Core Responsibility:** Generate and execute deterministic unit tests, mutation tests, and regression assertions in an isolated sandbox.
- **Input Artifacts:** Interface contracts, `MakerAgent` code diff, acceptance criteria.
- **Output Artifacts:** Unit test files, test execution logs, branch coverage reports.
- **Context Boundaries:** Read-only access to implementation code; author of verification test suites.
- **Deterministic Gate:** `UnitTestGate` (100% assertions green, zero compiler warnings treated as errors).

### 2.7 ValidationAgent (Acceptance Lead)
- **CMMI Process Areas:** Validation (VAL).
- **Core Responsibility:** Execute end-to-end user scenario validation against the running application or simulated staging environment.
- **Input Artifacts:** Gherkin scenarios from `spec.md`, compiled binary / service.
- **Output Artifacts:** Validation report, sign-off logs, RTM `VERIFIED` status transition.
- **Context Boundaries:** Operates at the system boundary (API/UI level), validating user journeys against initial business intent.
- **Deterministic Gate:** `GherkinScenarioGate` (all Given-When-Then paths verified with real assertions).

### 2.8 ComplianceAuditorAgent (PPQA Lead)
- **CMMI Process Areas:** Process & Product Quality Assurance (PPQA).
- **Core Responsibility:** Audit compliance with the project constitution (`constitution.md`), coding standards, security guardrails, and legal statutes.
- **Input Artifacts:** Full repository codebase, commit diffs, git history.
- **Output Artifacts:** Constitutional Audit Log, PPQA Non-Conformance Reports.
- **Context Boundaries:** Independent governance authority. Can veto a release if constitutional rules are breached.
- **Deterministic Gate:** `ConstitutionalGate` (zero violations of KMK financial rules or architectural segregation).

### 2.9 TelemetryEvalsAgent (Metrics Lead)
- **CMMI Process Areas:** Measurement & Analysis (MA), Quantitative Project Management (QPM).
- **Core Responsibility:** Collect and statistically analyze pipeline telemetry: Pass@1, Pass@3, token consumption, iteration counts.
- **Input Artifacts:** Loop execution traces, benchmark runs, gate failure logs.
- **Output Artifacts:** Benchmark scorecards, cost-per-task charts, statistical process control baselines.
- **Context Boundaries:** Quantitative telemetry only. Triggers alerts when variance exceeds 3-sigma limits.
- **Deterministic Gate:** `StatisticalOutlierGate` (halts autonomous run if repair budget or error count exceeds threshold).

### 2.10 CausalAnalysisAgent (CAR Specialist)
- **CMMI Process Areas:** Causal Analysis and Resolution (CAR).
- **Core Responsibility:** Perform root-cause analysis on escalated tasks or recurrent gate failures; generate permanent preventive prompt/harness patches.
- **Input Artifacts:** Failed loop traces, AST error dumps, compiler diagnostics.
- **Output Artifacts:** Root-cause analysis reports, updated prompt guidelines, automated regression unit tests.
- **Context Boundaries:** Meta-level analysis and process optimization.
- **Deterministic Gate:** `RegressionPreventionGate` (proves that the new rule or gate detects the historical defect).
