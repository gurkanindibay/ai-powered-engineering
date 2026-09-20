---
description: Behavioral rules and architecture constraints for Runtime Inference systems (apps/runtime/).
globs: apps/runtime/**
---

# Runtime Inference Engineering Directives

When working on or generating code for **Runtime Inference** applications (`apps/runtime/`):

## 1. Core Principles
Runtime inference systems use LLMs, heuristics, or agentic loops inside the production request/response pipeline. Because LLM outputs are stochastic:
1. **Never Trust Raw Probabilistic Outputs**: All model extraction or decision making must pass through deterministic verification gates before persisting or triggering side effects.
2. **Strict Verification Gates**:
   - Arithmetic invariants must be validated with zero tolerance ($\sum \text{items} == \text{subtotal}$, $\text{subtotal} + \text{tax} + \text{tip} == \text{total}$).
   - Policy compliance rules must be verified deterministically via rule catalogs (`PolicyCatalog.cs`, `PolicyAuditGate.cs`).
3. **Anti-Rot Feedback Shaper**:
   - Provide pinpoint mathematical feedback to the agent (e.g. `Calculated subtotal: $45.00 vs Stated: $50.00 (Delta: -$5.00)`).
   - Do not re-inject entire raw contexts or raw exception tracebacks into the prompt.
4. **Hard Iteration Budgets**:
   - Maintain a bounded loop budget (default max: 3 iterations).
   - On budget exhaustion, do not loop indefinitely: transition safely to human review or terminal rejection.
5. **State Graph Observability**:
   - Route execution through a typed state machine (`AuditGraphEngine`).
   - Emit `AuditStepTrace` events at each node for telemetry, auditability, and benchmark evaluations.
