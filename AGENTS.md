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
   - Monetary or calculation fields MUST use high-precision decimals (`decimal` in C#, `BigDecimal` in Java, `Decimal` in Python, `NUMERIC(15,2)` in SQL). Never introduce floating-point arithmetic in financial domains.

3. **Verification Before Delivery**:
   - Always run the relevant automated test suite before concluding any code modification:
     - Runtime tests: `dotnet test apps/runtime/AuditGuard/tests/AuditGuard.Tests` and `dotnet test apps/runtime/TaskPilot/tests/TaskPilot.Tests`
     - Dev-time tests: `python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests` and `dotnet test factory/DevFactory`
