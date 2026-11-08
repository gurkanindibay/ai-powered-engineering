---
name: team-orchestration
description: Plan and run a durable software engineering harness with Product Owner, Business Analyst, Backend Developer, Frontend Developer and Tester roles, capability-validated model routing and isolated verification.
---

# Team orchestration

Use `scripts/development_harness.py` for persistent runs. The architecture and supported deployment boundaries are documented in `docs/engineering-harness.md`. Use `scripts/team_orchestrator.py` only for compatible planning; it no longer emits unvalidated T3 payloads or assumes model availability.

## Roles and routing

The five default responsibilities are Product Owner (scope/criteria), Business Analyst (domain/contracts), Backend Developer, Frontend Developer and independent Tester. High/critical work adds Architect. Select backend/frontend scope to omit unnecessary implementation roles; low-risk mechanical work can use Developer + Tester.

Risk floors cannot be lowered by `--complexity`: financial/concurrency/destructive persistence is CRITICAL; auth/schema/cross-service/broad changes are HIGH; routine API/UI behavior is MEDIUM. File-count estimates are secondary. The capability registry supplies eligible model identities, options, role/tier benchmark qualifications and decimal pricing. The harness refreshes live capabilities before dispatch and does not silently substitute a requested target.

## Workflow

1. Read project rules and accepted requirements. Use the existing Graphify graph and project gate tools.
2. Plan with `python3 scripts/development_harness.py --json plan --task "..."`. Planning without capabilities leaves model targets unresolved.
3. Configure an operator-owned policy, digest-pinned toolchain/bridge image and model registry. Never put credentials in policy, prompts, images or source files. The gateway proxy owns credentials and quotas.
4. Create from an explicit committed revision with `create --repository PATH --revision REV --policy POLICY --task "..."`. Dirty user edits are excluded; never clean or reset the user's checkout.
5. Use `step RUN_ID` or `run RUN_ID`. Role artifacts and input hashes are validated. Sequential implementation integrates into an owned candidate; trusted gates run on disposable copies of the exact final candidate.
6. Inspect `status`, `events` and `audit`. `cancel` stops owned work; `recover` reconciles expired attempts and blocks interrupted work without resetting budgets. Failure evidence and source are retained for inspection.
7. READY_FOR_REVIEW requires independent tester criteria and passing final gates. Merge/release remains a separate authorized action.

Gate failures trigger bounded developer repairs followed by another tester review and complete gate run. Two unsuccessful repairs request a higher eligible tier while preserving explicit target constraints. Environment/model/configuration failures block; they are not disguised as code repairs. Unknown usage retains its full reservation.

## Verification

- `python3 -m unittest discover -s tests/engineering_harness -v`
- Build `tests/engineering_harness/Dockerfile`, set `HARNESS_DOCKER_IMAGE` to its image digest, then rerun the suite for actual container isolation and protocol tests. Without the variable those tests are explicitly skipped.
- `python3 scripts/development_harness.py --json evaluate --cases config/engineering-harness/routing-cases.json`
- Run the existing project suites required by AGENTS.md. Fixture agents test the controller; they are not evidence of live model quality or cost savings.

T3 delegation from an interactive session follows the current T3 tool contract and `orchestrator_capabilities`. The Python runtime uses a container bridge protocol, not an undocumented T3 server endpoint. Do not confuse these transports or feed planner JSON directly into delegate_task.
