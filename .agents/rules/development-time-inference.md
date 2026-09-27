---
description: Behavioral rules and engineering workflows for Development-Time Inference systems (apps/development-time/, factory/).
globs: apps/development-time/**, factory/**
---

# Development-Time Inference Engineering Directives

When working on or generating code for **Development-Time Inference** applications (`apps/development-time/`, `factory/`):

## 1. Core Principles
Development-time inference uses AI models, agents, and spec harnesses *during the engineering lifecycle* to specify, design, architect, code, test, and manufacture applications:
1. **Spec-Driven Precedence**:
   - The `.specify/constitution.md` and feature specs (`.specify/specs/*/spec.md`) represent ground truth.
   - Always read the specification and acceptance criteria before writing code.
2. **Topological Task Scheduling**:
   - Features must follow the DAG defined in `.specify/tasks/task-dag.json`.
   - Never implement a child task before all its prerequisite tasks are marked as verified.
   - Use `python3 harness/harness_cli.py next` to identify eligible tasks.
3. **Maker-Checker Closed Loop**:
   - Separate the role of generation (Developer/Maker) from validation (Tester/Checker).
   - Generated code must pass all registered verification gates:
     - Syntax AST Gate (e.g. `SyntaxGate`, Roslyn AST parser).
     - Domain/Integrity Gate (e.g. `FinancialIntegrityGate`).
     - Build & Unit Test Gate (100% assertions passing).
4. **Isolated Ephemeral Sandboxing**:
   - In factory and autonomous generation settings, code must be compiled and tested in an isolated sandbox before being merged into the codebase.
5. **English-Only Source Code Mandate**:
   - All manufactured code, domain models, database schemas, tables, columns, variables, functions, and tests must be strictly written in English. Non-English code identifiers are strictly prohibited.
6. **Automatic Stack Restart After Fixes**:
   - After completing any issue fix or code modification in SitePulse, proactively restart the full development stack by executing `apps/development-time/SitePulse/scripts/restart-all.sh` so the user can immediately test live changes across the backend (8080), Flutter web client (9090), and UX prototype (9091).
7. **Papara-Style Full-Screen Navigation Mandate**:
   - In mobile client views (Flutter UI), floating center `AlertDialog` popups and partial/half-screen bottom sheets are strictly prohibited for interactive flows. In accordance with modern Turkish fintech UX (e.g. Papara, Enpara), all user interactions, payment checkouts, detail breakdowns, forms, announcements, and confirmations must open as dedicated, 100% viewport **Full-Screen Pages** (`AppFullscreenPage` / `Navigator.push(MaterialPageRoute(fullscreenDialog: true))`). Each page features a clean `AppBar` (title, subtitle, back/close button) and a sticky bottom action bar (`AppFullscreenPage.buildBottomBar`), and upon completion or dismissal returns cleanly to the exact calling screen via `Navigator.pop()` without layout shifts.

