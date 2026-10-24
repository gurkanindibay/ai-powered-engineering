# Antigravity Workspace Directives: AI-Powered Engineering

Welcome Antigravity Agent. This workspace implements advanced agentic software engineering paradigms to mitigate the stochasticity of Large Language Models.

The workspace is strictly partitioned into two paradigms:
1. **Runtime Inference Systems (`apps/runtime/`)**:
   - `AuditGuard`: Autonomous expense audit microservice with in-loop mathematical validation, policy gates, and directed graph state machine.
   - `TaskPilot`: High-reliability task and workflow management business service with clean domain boundaries.
2. **Development-Time Inference Systems (`apps/development-time/`, `factory/`)**:
   - `SitePulse`: AI-manufactured residential site platform built using Spec-Driven Development (`.specify`), Task DAG dependency graphs, and a closed-loop Maker-Checker verification harness.
   - `DevFactory`: Autonomous software manufacturing assembly line factory producing standalone C# software.

---

## Workspace Rules & Operational Constraints

1. **Context Boundary Awareness**:
   - When modifying files under `apps/runtime/`, apply the rules defined in [.agents/rules/runtime-inference.md](file:///.agents/rules/runtime-inference.md).
   - When modifying files under `apps/development-time/` or `factory/`, apply the rules defined in [.agents/rules/development-time-inference.md](file:///.agents/rules/development-time-inference.md).

2. **Invariants & Decimal Precision**:
   - Monetary or calculation fields MUST use high-precision decimals (`decimal` in C#, `rust_decimal::Decimal` in Rust, `Decimal` in Dart/Python, `BigDecimal` in Java, `NUMERIC(15,2)` in SQL). Never introduce floating-point arithmetic in financial domains.

3. **Verification Before Delivery**:
   - Always run the relevant automated test suite before concluding any code modification:
     - Runtime tests: `dotnet test apps/runtime/AuditGuard/tests/AuditGuard.Tests` and `dotnet test apps/runtime/TaskPilot/tests/TaskPilot.Tests`
     - Dev-time tests: `python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests` and `dotnet test factory/DevFactory`

4. **English-Only Development Language**:
   - All source code, identifiers, types, schemas, tables, columns, variable names, function names, API route paths, tests, and code comments MUST be authored strictly in English. Non-English identifiers in source code are strictly prohibited.

5. **Tooling & Automation Language Preference (Python Over Bash)**:
   - Prefer Python for developer tools, verification scripts, harness utilities, data inspectors, and automation scripts over Bash. Python provides structured typing, native JSON/data parsing, cross-platform stability, and testability.

6. **Tool Crystallization & Continuous Improvement**:
   - When developing features, fixing bugs, or executing complex verification tasks, evaluate whether a custom script, diagnostic query, or verification procedure has recurring value across future development iterations.
   - If so, do not leave it as an ephemeral scratch script; crystallize it into a permanent, production-grade Python tool under `scripts/`, support `--help` and `--json`, document it in [skills.md](file:///skills.md), and register it in [.agents/skills/continuous-improvement-tooling](file:///.agents/skills/continuous-improvement-tooling/SKILL.md) so subsequent iterations can immediately leverage it.
