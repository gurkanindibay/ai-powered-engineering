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
