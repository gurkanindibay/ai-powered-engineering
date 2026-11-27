# Engineering harness

The harness runs a sequential software engineering team: Product Owner → Business Analyst → Backend Developer → Frontend Developer → independent Tester → trusted verification. High/critical tasks add Architect. Backend/frontend scope omits irrelevant implementation stages; low-risk mechanical scope uses Developer + Tester.

Python 3.12+ and Git support planning and persistent state. Execution requires Linux, Docker, a locally available digest-pinned worker/toolchain image and an operator-owned policy. No host execution fallback, production deployment or automatic merge is provided. The user's checkout is never reset, staged, committed or rewritten.

## Start with planning

```bash
python3 scripts/development_harness.py --help
python3 scripts/development_harness.py --json plan --task "Implement payment reconciliation" --financial
python3 scripts/team_orchestrator.py --task "Fix documentation wording" --scope mechanical
```

Without capabilities, plans show unresolved targets. They are not live delegation payloads. `--complexity low` cannot override financial/auth/schema risk floors. The classifier is a conservative heuristic, not a proof of domain safety; supply explicit risk flags when relevant. Three to six estimated files imply at least MEDIUM; more than six imply at least HIGH. Model identity and options come from a validated capabilities registry. Two unsuccessful repairs promote the requested tier, subject to eligibility and explicit target constraints.

## Prove the controller and sandbox locally

The fixture bridge is deterministic and makes no model calls. It exercises all five role contracts in real containers. Its results establish controller behavior, not model quality.

```bash
docker build -t engineering-harness-fixture:local tests/engineering_harness
HARNESS_DOCKER_IMAGE=$(docker image inspect --format '{{.Id}}' engineering-harness-fixture:local) python3 -m unittest discover -s tests/engineering_harness -v
python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests
python3 scripts/development_harness.py --json evaluate --cases config/engineering-harness/routing-cases.json
```

Without `HARNESS_DOCKER_IMAGE`, the three Docker tests are explicitly skipped. The 36 routing cases are synthetic regression cases; use representative held-out tasks for a real pilot. CI builds the fixture image and runs the Docker tests rather than counting those skips as passes.

## Configure real model execution

The included `engineering_harness.gateway_bridge` implements a bounded workspace-tool loop against an operator-managed gateway offering `/v1/models` and `/v1/chat/completions`. The message/tool-call and usage formats follow the [official Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) and [function-calling guide](https://developers.openai.com/api/docs/guides/function-calling). Compatible gateways may route to several providers; validate the gateway's actual compatibility. Native Anthropic/Gemini transports need their own bridge implementation if they do not offer this gateway API. To use T3 Code sessions instead of API tokens, see [Run agents as T3 child sessions](#run-agents-as-t3-child-sessions-no-api-tokens).

1. Populate `config/engineering-harness/model-registry.example.json` with **evaluated, authorized** gateway targets before building a worker image. The committed example has an empty list deliberately. Each entry requires:

   ```json
   {
     "provider": "YOUR_PROVIDER_LABEL",
     "model": "YOUR_GATEWAY_MODEL_ID",
     "roles": ["product_owner", "business_analyst", "architect", "backend_developer", "frontend_developer", "developer", "tester"],
     "tiers": ["low", "medium"],
     "options": {"reasoning_effort": ["low", "medium"]},
     "max_tokens": 20000,
     "input_per_million": "1.00",
     "output_per_million": "2.00",
     "price_date": "YYYY-MM-DD",
     "benchmark_id": "YOUR_EVALUATION_VERSION"
   }
   ```

   These rates are illustrative, not current prices. Set actual prices, date, per-role/tier qualifications and supported options. The gateway bridge translates only `reasoning_effort`; custom bridges can support other capability-validated controls. Lowest declared input+output price wins among eligible targets, with stable identity tie-breaking. Registry qualifications and rates are trusted operator assertions, not inferred from a model name. Capability discovery intersects the registry with the gateway's live model IDs before every stage.

2. Build the base bridge image from the repository root:

   ```bash
   docker build -f config/engineering-harness/Dockerfile -t engineering-harness-worker:local .
   docker image inspect --format '{{.Id}}' engineering-harness-worker:local
   ```

   Use the returned `sha256:...` in policy. The image contains Python and the bridge. A SitePulse image must also contain its Rust/Flutter/PostgreSQL/browser toolchains, dependencies and caches. The worker root filesystem is read-only; configure writable build caches under `/tmp` or the disposable gate workspace. No secrets belong in an image. Network access during dependency installation is a separate image-build operation.

3. Supply a credential-brokering gateway on an administrator-created **internal** Docker network named `harness-egress-*`. The gateway, not the worker, holds provider credentials and enforces allowed upstreams, models, request quotas and authentication. Workers receive no host environment credentials, home directory, Docker socket or credential files. The controller checks Docker's internal-network property; proxy configuration, workload authentication and egress allowlists remain deployment responsibilities. Any peer on that network must be trusted. Use one network/proxy per appropriate trust boundary.

4. Generate and edit a policy outside worker control:

   ```bash
   python3 scripts/development_harness.py --json sitepulse-policy --image sha256:YOUR_PREPARED_IMAGE_DIGEST > /tmp/sitepulse-harness-policy.json
   python3 scripts/development_harness.py validate-policy /tmp/sitepulse-harness-policy.json
   ```

   Replace `bridge` with:

   ```json
   ["python3", "-m", "engineering_harness.gateway_bridge", "--endpoint", "http://YOUR_PROXY:PORT", "--registry", "/opt/models.json"]
   ```

   The bridge keeps worker context bounded: `read_file` accepts `start_line`/`end_line`, a capped `search` tool locates code before reading, each tool result is capped at 16 KiB, and once tool results exceed 48 KiB in total, all but the four most recent are replaced with short stubs. The system prompt and envelope stay a stable prefix so gateway prompt caching remains effective.

   Set `network` to the administered internal network. The generated template defaults to `none`, empty model preferences and conservative writable paths; it intentionally cannot reach a provider. Add role preferences when a specific provider/model/options are required. A missing requested target blocks execution; the harness does not silently substitute one. Policy is copied and hashed at intake, so editing its source file does not alter an existing run.

5. Set concrete task acceptance criteria in `acceptance`, mapping each to one or more required gate IDs. Add targeted gates alongside the existing regression checks. The generated SitePulse template only supplies a regression criterion and does not infer a feature's business acceptance. Schema/migration files are not writable by default; an operator must assign those paths and required upgrade checks for that task.

## Run agents as T3 child sessions (no API tokens)

When the operator works inside T3 Code, role agents run as T3 child sessions on the operator's existing provider subscriptions instead of a token-billed gateway. The Python controller cannot call T3 tools itself, so the work is split:

- **Harness (trusted):** risk assessment, model routing, budgets, envelope/result hashing, path enforcement, integration, Docker gates, audit trail.
- **T3 orchestrator agent:** calls `orchestrator_capabilities`, sends each harness-built `delegate_task` payload unchanged, and returns the child's final message to the harness.

`config/engineering-harness/t3-registry.json` maps T3 `providerInstanceId`/model pairs to roles and tiers, with per-tier default options (for example `effort`). The live catalog is intersected with it on every dispatch: disabled providers, missing models and unoffered option values drop out, and a tier whose default options are gone is withdrawn instead of retuned. Defaults are Haiku 5.5 (LOW), Sonnet 5.5 (LOW–HIGH, effort rising per tier), Opus 5.5 (HIGH/CRITICAL) and Codex `gpt-6.1-sol` (opt-in through policy `preferences`, for example a cross-provider Tester). Prices in this registry are **relative cost units** for ordering and budgets, not billed currency. `benchmark_id` marks the defaults as unevaluated; replace it after a held-out pilot.

Orchestrator loop (also in the team-orchestration skill):

```bash
# 1. Save orchestrator_capabilities output to catalog.json (no search filter).
python3 scripts/development_harness.py --json plan --task "..." --t3-catalog catalog.json
python3 scripts/development_harness.py --json create --repository . --revision COMMIT_SHA --policy POLICY.json --task "..." --t3-catalog catalog.json
# 2. Repeat until the status is terminal:
python3 scripts/development_harness.py --json t3-dispatch RUN_ID --catalog catalog.json
#    -> send .delegate_task as delegate_task arguments, save the child's final message
python3 scripts/development_harness.py --json t3-submit RUN_ID ATTEMPT_ID --output child.txt
```

`t3-dispatch` claims one stage and prints `delegate_task` arguments (title, role, `mode: wait`, timeout, `clientRequestId` = attempt ID, target and prompt). When no stage is pending it runs the trusted gates and returns the resulting status (`READY_FOR_REVIEW`, `REPAIRING`, `BLOCKED`). Children work directly in the harness-owned candidate checkout under the state directory, never in the user's checkout, and must end with a `<<<HARNESS_RESULT ... HARNESS_RESULT>>>` JSON block containing only `status`, `summary`, `artifacts` and `issues`. The controller stamps run/attempt IDs, input hash, candidate and usage. A missing or malformed block, extra fields, writes outside the role's paths, protected-path edits or Git history changes block the run. Duplicate identical submissions are idempotent. `t3-heartbeat RUN_ID ATTEMPT_ID` extends a long child's lease. `cancel` stops the run, but T3 children must be stopped by the orchestrator with `task_cancel`.

Limits of this transport: T3 children run with the orchestrator's T3 permissions rather than in the Docker sandbox, so path rules are enforced when the result is integrated, not by mounts. Edits a child makes outside the candidate checkout are not detected. T3 exposes no per-child token usage, so each attempt charges its full reservation (`min(attempt_tokens, max_tokens)` tokens). Gates still need the digest-pinned Docker image from the policy; `image`, `network` and `limits` apply to them, and `bridge` is ignored by T3 dispatch.

### Reviewer-coordinated auto-handover (Phase 4)

Routine handovers do not need an LLM. `scripts/harness_coordinator.py` validates the checkpoint, chooses the next qualified healthy provider, transfers the claim atomically and dispatches:

```bash
python3 scripts/harness_coordinator.py heartbeat --harness t3 --session "$AGENT_SESSION_ID" \
    --model deepseek-flash --issue 412 --worktree "$PWD" --context-pct 62
python3 scripts/harness_coordinator.py handover --issue 412 --reason provider_quota_exhausted \
    --from-harness t3 --from-session "$AGENT_SESSION_ID" --from-provider claudeAgent \
    --envelope .agents/local/handovers/412-002.json --json
python3 scripts/harness_coordinator.py recover --t3-db .agents/local/runs.sqlite3 --json
python3 scripts/harness_coordinator.py serve --once --json
python3 scripts/harness_coordinator.py simulate --cases config/engineering-harness/coordinator-scenarios.json
```

The three transports are a T3 `delegate_task` payload (`.agents/local/dispatch/t3/<handover>.json`, requiring `task_cancel` of the outgoing child first), a headless CLI in a fresh detached worktree (`config/engineering-harness/launchers.json`), or an IDE pickup brief (`.agents/local/handovers/pickup/`). `serve --once` (or `--passes`/`--interval`) is the daemon loop: it runs the watchdog, dispatches every pending envelope, and watches open issues labeled `handover:pending` (a label with no local envelope escalates rather than guessing). A failed CLI run is captured deterministically by `handover.py capture`, so a 429 or crash still checkpoints. The watchdog (`recover`) snapshots dirty expired sessions and **never removes, resets or force-cleans their worktrees**; an expired T3 attempt only escalates, because `task_cancel` must precede candidate export. The coordinator writes escalation records for invalid checkpoints, thrashing (2+ handovers or 2+ failed repairs), the `MAX_HANDOVERS = 3` cap and missing healthy providers; it never posts a review or merges. The context/quota checkpoint gate lives in `scripts/token_guard.py` (80% context, 85% quota).

### Unified Local Control Console & MCP Adapter (Phase 5)

`scripts/harness_console.py` provides a strictly loopback-only (`127.0.0.1`) web dashboard with SSE log/status streaming (`serve`) and a synchronized `--json` CLI backed by an append-only SQLite WAL command queue (`.agents/local/harness_console.sqlite3`). Operator interventions (`pause`, `resume`, `kill`, `steer`, `handover`, `pin`, `takeover`, `set-budget`, `mark-status`, `set-gate`, `approve`) preempt automated coordinator decisions: `harness_coordinator.py` honors active pauses, provider/T3-instance pins, tier approval gates, DeepSeek USD budget overrides, and steering notes, and records acknowledgements in `command_acks`. `scripts/harness_mcp.py` exposes `dispatch_task`, `steer_task`, `handover_task`, `pause_task`, `kill_task`, `get_status`, and `list_pickups` over local stdio JSON-RPC 2.0. Neither surface exposes secrets or raw Track B transcript message content. The loopback web server enforces browser CSRF/origin checks without per-user authentication, assuming a single-user developer machine.

## Create and run

```bash
python3 scripts/development_harness.py --json create --repository /path/to/repository --revision COMMIT_SHA --policy /tmp/sitepulse-harness-policy.json --task "Implement the agreed feature" --scope fullstack
python3 scripts/development_harness.py status RUN_ID
python3 scripts/development_harness.py step RUN_ID
python3 scripts/development_harness.py run RUN_ID
python3 scripts/development_harness.py events RUN_ID
python3 scripts/development_harness.py audit RUN_ID
```

Use `--state /private/path` before the subcommand to select a state directory. Default state is ignored `.engineering-harness/`, mode 0700; its database and evidence files use mode 0600. Commands return 0 for successful operations, 1 for terminal failure/cancellation or invalid audits/evaluations, and 2 for usage/configuration errors. Human-readable JSON is the default structured display; `--json` explicitly requests machine output.

Intake exports the requested committed revision into an owned Git repository under the state directory. Dirty user files are excluded, and archives containing links, special files or credential-looking paths are rejected. The candidate has its own commit identity, with the original source revision recorded alongside it. Implementation stages commit only allowed paths, reject protected checker/policy changes, and carry hashes of predecessor artifacts. The final Tester sees the integrated candidate. Every gate receives a fresh export of **exactly committed** content, so ignored files in a worker workspace cannot influence final verification.

The generated SitePulse policy reuses its existing full test runner and self-tests. It does not change SitePulse `.specify` task statuses or bypass CI recording restrictions. Database/browser checks need a disposable test service reachable through the configured internal network and its allowed proxy/service setup. Never supply production database access. Missing prerequisites fail the run; this runtime does not convert required checks to skips. Project migration/contract-specific criteria should point to the existing task CLI or appropriate trusted gate commands.

## Policy contract

Policy schema version 1 requires `image`, `bridge`, `network`, `limits`, `role_paths`, `protected_paths`, `gates`, `acceptance`, `preferences` and `schema_version`. Validate with `validate-policy` before intake.

- `image`: a local `sha256:<64 hex>` image ID or repository image pinned by `@sha256:<64 hex>`. Pulling is disabled at execution.
- `limits`: positive integer `tokens`, `seconds`, `attempt_tokens`, `attempt_seconds`, `memory_mb`, `cpus`, `pids`, `output_bytes`; decimal-string `cost`; integer `max_repairs` from 0 to 10. Limits apply across restarts. Tokens include input and output; model usage is not inferred from visible text.
- `role_paths`: all seven role names mapped to writable **directories**, relative to candidate root. Empty lists grant read-only access. Parent traversal, absolute paths, `.git` and mount syntax injection are rejected. Protected paths still override writable assignments during integration.
- `protected_paths`: prefix rules for trusted tests, gate scripts, policies, CI, specifications and other files that must not change in the run. New/changed tests are allowed only where assigned; include known acceptance checkers in protected paths. Protection is not a semantic proof that every editable test remains strong.
- `gates`: nonempty list of `{id, argv, cwd, timeout, test_pattern}`. Optional `repair_role` identifies which developer should handle failures of that gate; otherwise the last implementation role is used. Use argv arrays, not shell text. `cwd` is `.` or a relative directory. A `test_pattern` uses named group `count`; at least one required gate must prove a positive executed test count. Use `null` for build/lint commands.
- `acceptance`: nonempty map of criterion text to required gate IDs. The PO must preserve these accepted criteria, and the Tester must return a decision for every one. Gates cannot be selectively skipped by agent output.
- `preferences`: optional per-role `{provider, model, options}` constraints. All provided settings must match live capabilities. An empty map allows policy-based selection.

The controller initially runs only one worker at a time per run. Separate runs have separate candidates; operator/CI capacity controls should bound aggregate concurrency and disk usage. Docker limits CPU, memory and process count per container; deployments must add filesystem quotas and whole-host limits. Worker mount rules are enforced by Docker, not merely by prompts. Trusted verification commands may build in disposable writable copies. Compilation/test source that changes during a gate fails verification.

## Worker protocol

The container entrypoint receives one UTF-8 JSON document on stdin and returns one JSON document on stdout. Diagnostics belong on stderr (also retained in bounded execution evidence). Capabilities receive `{schema_version: 1, action: "capabilities"}` and return `{schema_version: 1, targets: [...]}` using the registry fields above. A nonzero exit, malformed JSON or invalid result blocks the run conservatively.

Execution envelopes include schema/run/task/attempt IDs, transport (`docker` or `t3`), role, objective/instruction, dependency IDs, source and candidate revisions, policy/contract hashes, predecessor artifacts, previous failure diagnostics, selected target, risk reasons, writable paths, accepted criteria, token/cost limits and timeout. Envelopes are bounded to 64 KiB; oversized handoffs block rather than silently losing context.

Every result has exactly:

```text
schema_version, run_id, task_id, attempt_id, input_hash, candidate,
status, summary, artifacts, issues, usage
```

`input_hash` is SHA-256 of canonical JSON (sorted keys, separators `,`/`:`, ASCII escapes, no NaN). `candidate` references the input candidate; the controller records any resulting integration commit separately. `status` is `completed`, `code_defect`, `blocked` or `infrastructure_error`. Completed results cannot carry unresolved issues. `usage` contains nonnegative integer `input_tokens` and `output_tokens`.

Optional Coordinator artifacts are `work_plan`/`coordination_risks`; PO `scope`/`acceptance_criteria`/`exclusions`; BA `domain_rules`/`contracts`/`edge_cases`; Architect `design`/`risks`; Developer `changes`/`tests`; Tester `criteria`/`verdict`/`residual_risks`. Types are validated. Tester verdict must be `pass`, with every accepted criterion mapped to `pass`. Those statements are supplemented by independently executed gates, not trusted as test execution evidence. The included gateway bridge stamps IDs and hashes itself and aggregates provider-reported usage; model text cannot invent those fields.

The gateway loop offers bounded file read/list/write tools and structured finish. It has no arbitrary command tool. Trusted gates execute separately. Other bridges must enforce envelope budgets, bind their results to actual provider usage and use their runtime's supported cancellation/permissions. Registry and proxy telemetry are trusted inputs. The bridge uses conservative request byte bounds and bounded turns; the proxy must enforce provider-side token/spending quotas too. Killing a local HTTP client cannot guarantee cancellation of already-billed upstream inference.

## Failures, recovery and evidence

```bash
python3 scripts/development_harness.py cancel RUN_ID
python3 scripts/development_harness.py recover RUN_ID
```

SQLite immediate transactions serialize claims and reserve whole-attempt token/cost ceilings before dispatch. Actual validated usage refunds the unused reservation once. Duplicate identical completions are idempotent; conflicting, stale or late completions are rejected. Unknown/missing usage keeps the reservation charged. Budget violations block readiness. Reservations, deadlines, repairs and events survive controller restarts.

Required gate failures trigger bounded repairs, requeue dependent roles including Tester, and rerun all gates. Infrastructure/configuration failures block. Workers that fail while leaving changes are preserved and blocked rather than silently rolled back. Leases are bounded by worker timeout plus grace; the store supports heartbeats. Recovery does not steal a live lease. It reconciles expired container state, stops remaining owned work, preserves candidates/reservations and blocks for inspection instead of blindly replaying external effects. An interrupted verification is also reconciled and blocked. Repeated callbacks cannot cause duplicate integration.

Cancellation records terminal state before stopping owned worker/gate containers. Source and evidence are retained. Stopped Docker containers have logging disabled and can be removed later by an operator after inspection; there is no broad automatic cleanup of user resources. Configure state retention, private backups, disk quotas and an owned-container cleanup job before a pilot.

Evidence is written once per attempt and verification, redacted for common secret assignments and linked by content hashes to append-only audit events. `audit` checks event chaining and referenced evidence content. Local storage is protected by filesystem permissions, **not cryptographic authentication against the host operator**. Redaction is defense in depth, not a complete secret detector. No private reasoning trace is requested. Protect and retain the state directory appropriately; snapshots contain repository source. Use an independently protected artifact store or CI attestation for stronger provenance.

READY_FOR_REVIEW means the exact combined candidate satisfied required checks and independent role review. It does not merge/deploy, guarantee zero defects, prove a rare-event failure rate or authorize external writes. Workers have no default production-write tool. External integrations need their own idempotency, approval and compensation design.

## Evaluation and remaining rollout work

`evaluate --cases FILE` reports exact-match and harmful under-classification counts. With `--measurements FILE`, supply paired entries `{task_id, repetition, arm: baseline|routed, accepted, duration_ms, cost}`. Every baseline/routed pair must match; cost-per-accepted includes failed-run costs, and no accepted results yields null. Report sample size, medians and p95 without claiming significance from small samples.

The implementation provides the sequential runtime, configurable model gateway, role contracts, project adapter, bounded repairs, fault tests and pilot evaluation tooling. Deployment-specific credentials/proxy enforcement, complete project images, live provider qualification, representative held-out feature trials, staffing and cost/latency acceptance decisions remain required. Parallel branch integration, native provider-specific bridges, artifact-store signing, fleet scheduling/dashboarding, AST classification and external tracker integrations remain follow-on work. They are not represented as finished by fixture tests.

## Test run records (gate captures)

A gate may declare `"captures": ["<directory>"]`. After the gate runs in its disposable copy of the candidate, the controller reads the **new** UTF-8 text files under those directories (files already tracked in the candidate are ignored; at most 64 files of 256 KiB each; links are rejected) and stores them in that gate's evidence, which is hashed and audited like all other evidence. The candidate itself is never modified.

```bash
python3 scripts/development_harness.py --json captures RUN_ID                       # list captured files
python3 scripts/development_harness.py --json captures RUN_ID --output /path/to/repository   # write them; never overwrites
```

The generated SitePulse policy uses this for test execution history (AGENTS.md rule 13): `sitepulse-full` runs `run_tests.py` with `SITEPULSE_TASK=engineering-harness`, which makes the browser suite record its run under `apps/development-time/SitePulse/.specify/executions`, and captures that directory. Workers cannot write there: every `.specify` subdirectory except `features/` is protected, and so are the e2e fixtures (`e2e/support`, `e2e/pages`, `conftest.py`, `pytest.ini`). The `tester` role may write `.specify/features`, `e2e/steps` and `e2e/tests`, so it can express acceptance criteria as Gherkin scenarios and bind their steps. Recording needs an image that can run the browser suite (PostgreSQL, Flutter web build, Chrome); without one the `gui-e2e` gate inside `sitepulse-full` fails and nothing is captured.
