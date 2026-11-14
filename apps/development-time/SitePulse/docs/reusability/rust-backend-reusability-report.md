# Rust Backend Reusability Assessment

Date: 8 November 2026  
Repository baseline: `106295d`  
Scope: SitePulse Rust backend (`apps/development-time/SitePulse/backend`) and its potential reuse across this workspace.  
Revision: 3. Revision 2 re-verified the findings against source ([Revision notes](#revision-notes)); revision 3 records which findings are now implemented ([Implementation status](#implementation-status)).

## Executive decision

**Consolidate reusable behavior inside SitePulse first, then extract small libraries when a second consumer exists.** The most valuable business asset is the existing decimal-based dues ledger. The second financial asset, capital-project apportionment, has duplicated logic and an unclear rounding policy, so it needs fixing before anyone reuses it. The general-purpose candidates are narrower: Turkish text folding, a validated IBAN value object, identity (email) normalization, canonical fingerprints and webhook signatures, and credential primitives. Statement parsing has a useful interface but needs correctness hardening before broader reuse.

Several "reuse" findings are also correctness findings. The same rule is implemented in more than one place with different behavior:

- Bank-account setup checks only the `TR` prefix and length, while a checksum validator already exists.
- Three Turkish folding routines give different results for `İ`.
- The backend uses three rounding behaviors for money.

Consolidation is justified by these divergences, not by hypothetical future consumers.

The checkout has one Rust service package, `sitepulse-backend`, with a library target and two binaries. The only other Cargo manifest is the standards-check crate under [.agents/skills/rust-skills/checks](../../../../../.agents/skills/rust-skills/checks/Cargo.toml), which is tooling, not a service. No second Rust service exists to show actual cross-service duplication. AuditGuard and TaskPilot are .NET services, so they cannot use a Rust crate directly without an integration boundary. Do not add FFI or a new network service just to share small helpers. Share contracts, fixtures, and engineering patterns across languages first.

The recommended outcome is a modular SitePulse backend whose domain behavior can be tested on its own, not an immediate rewrite into a platform framework. This assessment includes no implementation changes.

## Scope and evidence

The assessment inspected the Cargo manifest, library/bootstrap, router, authentication, state, migration runner, repositories, domain services, scheduler, and representative test suites. The repository Rust standards were the review baseline. Findings describe the inspected source. Proposed interfaces and delivery priorities are architectural judgments, not measured savings.

`graphify-out/` is absent from this checkout, so graph navigation could not be used. All evidence comes from direct source inspection. Line references are to the baseline commit. Links use GitHub-style line anchors, relative to this report.

Evidence anchors:

- [Cargo package and dependencies](../../backend/Cargo.toml) and [public library modules](../../backend/src/lib.rs#L4): an existing library seam, but no Cargo workspace or extracted packages. Every module is `pub`, including `handlers`, so there is no deliberate public API surface yet.
- [Shared application state](../../backend/src/state.rs#L38): an optional PostgreSQL pool plus a shared `Arc<RwLock<AppStateInner>>` holding users, sites, units, liabilities, tokens, bank configuration, and payment state. `state.pool` / `if let Some(pool)` branching appears 93 times across 12 source files, so most services carry both a memory path and a database path.
- [Ledger operations](../../backend/src/services/dues_ledger.rs#L29), [payment orchestration](../../backend/src/services/payment_tracking_service.rs#L319), and [transaction helpers](../../backend/src/db/payment_repository.rs#L248): an existing separation of arithmetic from transactional persistence that should be kept.
- [HTTP handlers](../../backend/src/handlers/mod.rs) (4,045 lines), [models](../../backend/src/models/mod.rs) (2,314 lines), and [site administration](../../backend/src/services/site_admin_service.rs) (2,318 lines): large modules that mix several feature concerns. File size is not evidence of duplication by itself, but it makes independent reuse and API ownership harder.

## Prioritized opportunities

Priority is the recommended implementation order. Effort is relative extraction complexity, not a calendar estimate. Readiness describes current boundaries, not production certification.

| Priority | Candidate | Existing reuse / likely consumer | Readiness and effort | Recommended decision |
|---|---|---|---|---|
| P1 | Dues ledger and allocation | Manual payments, reconciliation, webhook payments, advances, reversals, scheduler | Strong internal seam; medium effort | Formalize a domain module; extract later if a compatible consumer appears |
| P1 | Capital-project apportionment | Installment accrual and unit share summary (two copies) | Duplicated, inconsistent; low–medium effort | Fix and consolidate into one largest-remainder apportionment function in the ledger domain |
| P1 | Turkish text folding | Ledger designation, reconciliation matching, tenant slugs | Three divergent implementations; low effort | Use `fold_turkish` as the single primitive; keep use-specific transforms local |
| P1 | IBAN validation and formatting | Bank-account setup, virtual IBAN generation, display | Validator exists but setup bypasses it; low–medium effort | Introduce a validated `TrIban` value object; isolate the identifier generator |
| P2 | Identity (email) normalization | Login, registration, invitations, tenant onboarding, repositories | Repeated inline with inconsistent trimming; low effort | One `NormalizedEmail` newtype used by services and repositories |
| P2 | Canonical fingerprints and webhook signatures | Webhook idempotency hash, receipt verification hash, HMAC verification | Small pure helpers mixed with env access; low effort | Shared fingerprint and signature module with injected secrets |
| P2 | Statement import | CSV/text and MT940 ingestion for reconciliation | Narrow entry point; medium hardening effort | Separate parser contracts and diagnostics before extraction |
| P2 | Credential and token primitives | Login, registration, invitations, administrator resets | Primitive reuse already present; medium effort | Separate crypto utilities from authorization and environment access |
| P2 | Repository ports and payment unit of work | PostgreSQL and memory implementations | High coupling; high effort | Introduce narrow behavior-oriented ports incrementally |
| P3 | Migration execution and pool configuration | Future PostgreSQL services | Useful mechanism; medium effort | Parameterize the mechanism; keep application migrations and seed data local |
| P3 | Reconciliation and scheduling | Other residential-management workflows | Domain-bound; high effort to generalize | Keep in SitePulse; separate pure decisions from execution |
| — | Shared verification fixtures | Rust backend and Flutter client already; .NET later | Already reused across languages | Extend; this is the main cross-language reuse channel |
| Defer | SaaS CRUD framework / bank SDK | No confirmed second consumer | Broad coupling or sandbox-only behavior | Do not extract now |

### 1. Dues ledger: highest-value domain reuse

[dues_ledger.rs](../../backend/src/services/dues_ledger.rs#L29) already centralizes outstanding balances, settlement, reversal, waterfall allocation, designation, and debtor eligibility. [PaymentTrackingService](../../backend/src/services/payment_tracking_service.rs#L319) calls it for canonical payments, and the transfer and reversal paths use it too. Several handlers call the canonical payment method. This is existing reuse to strengthen, not a reason to replace proven arithmetic with a new generic engine.

Create an internal `ledger` domain boundary with explicit liability, settlement, allocation, and policy types. Keep Axum, PostgreSQL, `AppState`, receipt presentation, and provider-specific transaction payloads outside it. Keep decimal precision and the distinction between amounts owed, amounts paid, and outstanding balances.

[`allocate_waterfall`](../../backend/src/services/dues_ledger.rs#L99) accepts caller-provided slice indices and indexes `dues[i]` directly. An out-of-range index panics. That is acceptable only under trusted internal preconditions. A reusable public interface should validate indices or accept validated identifiers. [`payer_may_settle`](../../backend/src/services/dues_ledger.rs#L52) and [`open_dues_for`](../../backend/src/services/dues_ledger.rs#L224) take the payer role as `&str`. A typed debtor role should replace it at the boundary, in line with the workspace's enum-over-string direction. Owner/tenant eligibility, capital dues, designation, and penalty-first allocation are residential policy, not universal accounting behavior.

**Acceptance:** all existing financial fixtures remain unchanged. Partial payment, surplus, designation, reversal, zero/negative input, duplicate candidates, and invalid-index behavior each have an explicit contract. Allocation plus remainder always equals the accepted payment amount.

### 2. Capital-project apportionment: consolidate and correct before reuse

Splitting a budget across units by equal share or land share is general apportionment logic, the kind of code that gets copied. The source currently has it in two places that disagree:

- [Installment accrual](../../backend/src/services/capital_project_service.rs#L409) and [unit share summary](../../backend/src/services/capital_project_service.rs#L718) each re-implement the equal / land-share split. Only accrual applies the remainder ("kuruş") correction, so the summary can report per-unit shares that do not add up to the budget and differ from the accrued liabilities.
- The [remainder correction](../../backend/src/services/capital_project_service.rs#L441) comment says it adjusts the unit with the highest land share. The code adds the difference to `unit_shares[0]`, the first unit in iteration order.
- Both paths clone `inner.units` without filtering by `project.site_id`, though the comment says "Get all units for this site" and project creation [filters by site](../../backend/src/services/capital_project_service.rs#L101). If in-memory state holds more than one tenant's units, apportionment includes other sites. Confirm this with a multi-site test before any reuse. It may be a tenant-isolation defect, not only a reuse concern.
- Shares use `round_dp(2)` (the library's default, banker's rounding), while delay penalties use midpoint-away-from-zero (see [Financial policy conflicts](#extraction-boundaries-and-risks)).
- Dues are linked back to a project by `period.contains(&project.title)` string matching, not by a project identifier.

Replace both copies with one pure function in the ledger domain, for example `apportion(total, weights, rounding) -> Vec<Decimal>`. It should use a documented largest-remainder (or deterministic tie-break) rule and be called by both accrual and summary. Link capital liabilities to projects by identifier.

**Acceptance:** for any budget and any set of weights, shares sum exactly to the budget. Summary and accrual return identical shares. The adjusted unit is deterministic and documented. A multi-site fixture proves only the project's site is apportioned. Zero units, zero total land share, and a single unit are covered.

### 3. Turkish text folding: three divergent implementations

Three routines fold Turkish text, and they disagree:

| Location | `İ` handling | Result for `"İSTANBUL"` |
|---|---|---|
| [`dues_ledger::fold_turkish`](../../backend/src/services/dues_ledger.rs#L190) | Lower-cases, then strips U+0307 combining dot | `istanbul` |
| [`ReconciliationService::normalize_turkish`](../../backend/src/services/reconciliation_service.rs#L340) | Lower-cases first, so `İ` is already `i` + U+0307 before the `'İ'` replace runs; the combining dot survives | `i̇stanbul` (matching mismatch) |
| [`saas_tenant_service::to_slug`](../../backend/src/services/saas_tenant_service.rs#L569) | Same order problem; U+0307 is non-alphanumeric and becomes `-` | `i-stanbul` |

`fold_turkish` is the only correct one. Make it the shared primitive and build slug and matching transforms on top of it. Keep slug punctuation rules, whitespace handling, and matching rules at their call sites. These transforms produce different outputs and should not become one configurable utility with many boolean switches. Changing `to_slug` changes generated slugs, so existing tenant slugs must be kept as they are (a slug is an identifier) and only newly generated slugs use the fixed rule.

**Acceptance:** table-driven Unicode fixtures cover dotted/dotless I in both cases, combining dots, NFC versus NFD input, Turkish capitals, punctuation, and whitespace. Existing stored slugs are unchanged. No new crate is needed for this change alone.

### 4. IBAN helpers: validated value object and isolated identifier generator

[VirtualIbanService](../../backend/src/services/virtual_iban_service.rs#L11) contains checksum, validation, and display functions that could become a small validated `TrIban` value object. The current state:

- **The validator is bypassed where it matters.** [Bank-account setup](../../backend/src/services/site_bank_account_service.rs#L57) implements its own weaker check (prefix `TR` and length 26) instead of calling `validate_tr_iban`, which is marked `#[allow(dead_code)]` and used only by tests. A mistyped IBAN with a bad checksum is accepted and stored. The bank code inside the IBAN (characters 5–9) is not checked against the selected `SupportedBank`.
- **Slicing assumes ASCII.** Validation and display check `len()` (bytes) and then slice at fixed byte offsets. A 26-byte string containing multi-byte characters can make `&clean[2..4]` fall inside a character boundary and panic. Check ASCII structure before slicing.
- **`compute_check_digits` skips non-digits** instead of rejecting invalid BBAN input.
- **Generator overflow.** In [`generate_virtual_iban`](../../backend/src/services/virtual_iban_service.rs#L97), `site_hash` is built with wrapping arithmetic, but `site_hash + block_hash` uses plain `+`. That can overflow, which panics in debug and test builds and silently wraps in release.
- **Collisions are possible.** The block hash is a byte sum, so `AB` and `BA` collide. `unit_number.abs()` maps `-14` and `14` to the same suffix. `% 1_000_000` truncates large unit numbers. A bank code longer than five characters is accepted by `{:0>5}` padding and produces a malformed IBAN.

Keep the generator as a SitePulse-specific identifier strategy until bank-backed allocation requirements exist. Source comments that claim BDDK/TCMB compliance are not evidence of bank provisioning or external certification.

**Acceptance:** bank-account setup rejects bad checksums and bank-code mismatches. Malformed Unicode never panics. Invalid bank codes, negative units, and out-of-range units are rejected. Checksum tests use independent published fixtures. Generator collision behavior is documented and tested. Do not present the helper as a bank-issued virtual-account SDK.

### 5. Identity normalization: one email type instead of inline lower-casing

Email normalization is repeated inline in [auth_service.rs](../../backend/src/services/auth_service.rs#L161), [user_repository.rs](../../backend/src/db/user_repository.rs#L10), [saas_tenant_service.rs](../../backend/src/services/saas_tenant_service.rs#L36), [site_admin_service.rs](../../backend/src/services/site_admin_service.rs#L87), and [home_resident_invitation_service.rs](../../backend/src/services/home_resident_invitation_service.rs#L103). The variants differ. Request input is usually `trim().to_lowercase()`, but stored values are compared with `to_lowercase()` only. A stored address with surrounding whitespace never matches, and uniqueness checks can disagree with the database's `LOWER(email)` lookups.

Introduce a `NormalizedEmail` newtype that trims, lower-cases, and validates at construction. Services and repositories should accept that type instead of `String`. This is a small, low-risk change that also removes a class of duplicate-account bugs.

**Acceptance:** registration, invitation, tenant onboarding, login, and password reset all use the type. Fixtures cover case, surrounding whitespace, and duplicate detection against both memory and PostgreSQL.

### 6. Canonical fingerprints and webhook signatures

Two hand-built canonical strings are hashed with SHA-256: the [webhook payload hash](../../backend/src/handlers/mod.rs#L1649) used for redelivery detection, and the [receipt verification hash](../../backend/src/services/payment_tracking_service.rs#L25). Both format amounts with `{:.2}`. The canonicalization rules are therefore part of a persisted contract, but they are implicit: field order, trimming, case, decimal scale, and timestamp format all live in `format!` strings. The webhook hash lives in the handlers module, so it is not reusable from services.

[`verify_webhook_signature`](../../backend/src/auth.rs#L191) correctly uses constant-time HMAC comparison but reads `SITEPULSE_BANK_WEBHOOK_SECRET` from the environment on every call, and it has no timestamp or replay window.

Create a small `fingerprint` module with versioned canonical-form builders and an HMAC verifier that takes the secret (and optionally a tolerance window) as parameters. These are the most portable primitives in the backend. The same canonical-form spec can be implemented in .NET for AuditGuard without sharing Rust code.

**Acceptance:** golden-hash fixtures pin each canonical form and version. Changing a field's formatting requires a new version. Signature verification is tested with injected secrets, wrong secrets, malformed hex, and missing headers.

### 7. Statement import: extract only after making data loss visible

[BankStatementParser](../../backend/src/services/bank_statement_parser.rs#L26) already accepts text and returns transaction records without database access, and [Mt940Engine](../../backend/src/services/mt940_engine.rs#L22) is isolated in the same way. If extraction goes ahead, move their small transaction/format contracts out of the broad models module.

The source shows these hardening needs:

- Unparseable tabular rows and MT940 transactions can be dropped with `continue` and no per-row diagnostics.
- Missing dates fall back to the current UTC date, and generated row IDs restart on every import.
- Currency is always set to `TRY`. MT940 debit/credit indicators are matched but not kept as a direction or applied to the amount.
- `Excel` selects text parsing, not binary `.xlsx` decoding, and splitting on commas is not a complete quoted-CSV parser.
- Regular expressions are compiled on every call ([parser](../../backend/src/services/bank_statement_parser.rs#L230), [reconciliation](../../backend/src/services/reconciliation_service.rs#L280)), and some compile errors are swallowed with `.ok()?`. Compile them once (`std::sync::LazyLock`) so that a bad pattern fails a test instead of silently matching nothing.

Use an explicit input format, import context, currency and direction, source identity, and a `ParseReport` that lists accepted records and the reasons rows were rejected. Inject any fallback date. Keep parsing separate from deduplication and payment posting.

**Acceptance:** fixtures cover malformed-row reporting, quoted delimiters, debit/credit handling, supported MT940 variants, locale amounts, repeated imports, and currency. Unsupported formats are rejected explicitly.

### 8. Authentication: share primitives, keep product authorization

[auth.rs](../../backend/src/auth.rs#L42) combines typed claims, JWT/Argon2 operations, global secret loading, route authorization, tenant scoping, and webhook security. [AuthService](../../backend/src/services/auth_service.rs#L396) already delegates password hashing to the common helper, and other services use it too. The cryptography is not duplicated.

Put credential hashing and token verification behind injected configuration and a clock. Keep `Role`, resident/unit checks, route allowlists, and tenant resolution in SitePulse. Do not export its 12-hour token policy or process-global secret cache as general defaults. Change fallible reusable operations to return typed errors instead of using `expect` or panicking on configuration. The remaining `expect` calls in [auth.rs](../../backend/src/auth.rs#L108) are on infallible paths, which is acceptable but should be documented as such. No backend source uses `spawn_blocking`. Argon2 work called from async request handling blocks a runtime worker and needs an explicit blocking-execution boundary.

**Acceptance:** coverage remains for invalid and expired tokens, wrong secrets, unsupported stored hashes, and cross-tenant denial. Library initialization does not read environment variables or install global tracing subscribers.

### 9. Persistence: preserve atomicity before abstracting CRUD

The main obstacle is the shared state plus optional pool (93 branch sites), not a lack of repository files. Services coordinate PostgreSQL operations and memory updates directly. [payment_repository.rs](../../backend/src/db/payment_repository.rs#L248) already exposes transaction-scoped helpers for idempotency, locking, sequences, receipts, entries, dues, and advances.

Put a payment-specific unit-of-work boundary around that atomic workflow. Do not replace it with generic `save<T>` repositories that take a fresh connection per call. Keep memory adapters for deterministic tests, with explicit semantics, and do not assume they prove PostgreSQL locking, constraint, or crash behavior. Split shared state by feature as dependencies become explicit, rather than creating one large trait that mirrors every state field.

**Acceptance:** a failure before commit leaves no partial financial state. Concurrent repeated requests create one logical payment. A restart reloads committed state. Tenant boundaries hold at the repository level. These are verified against a disposable PostgreSQL instance as well as memory tests.

### 10. Shared verification assets: reuse that already crosses languages

[financial_fixtures.rs](../../backend/tests/financial_fixtures.rs#L1) runs the backend against `harness/fixtures/financial_cases.json`. The Flutter client runs the same file in [financial_fixture_test.dart](../../flutter/test/financial_fixture_test.dart). This is working reuse without runtime coupling, and it is the model for cross-language sharing in this workspace.

Extend the fixture vocabulary before adding any cross-language service calls. Add policy identifiers (rounding strategy, allocation order), apportionment cases (section 2), folding cases (section 3), IBAN cases (section 4), and canonical-hash golden values (section 6). A future .NET consumer can implement the same fixture contract without importing Rust. The Flutter side was not run during this assessment.

**Acceptance:** every participating implementation runs the same versioned input/output cases. Decimal values stay strings in interchange. Policy differences are explicit, not hidden in adapters.

### 11. Migration and startup mechanisms: future infrastructure reuse

[Migration execution](../../backend/src/migrations.rs#L72) already provides checksums, a session-level advisory lock, and per-migration transactions. If `apply_pending` fails, the unlock still runs. What is not covered is an unlock that fails, and cancellation of the startup future: the lock is session-scoped and the connection goes back to the pool, so a stuck lock could survive on a pooled connection. A reusable runner would take a migration list and a lock namespace instead of embedding SitePulse SQL files and a fixed lock key. It would use a dedicated non-pooled connection or `pg_advisory_xact_lock`.

[db/base.rs](../../backend/src/db/base.rs#L29) mixes pool configuration, environment policy, schema initialization, fixtures, and destructive reset helpers. `DB_SSLMODE` defaults to `disable` there. Extract only typed pool configuration and the runner mechanism. Keep seed and reset operations out of any general production infrastructure API. Return configuration errors to the executable, which decides how to terminate. The current [main.rs](../../backend/src/main.rs#L21) `expect` calls are acceptable at that level.

**Acceptance:** a second migration set runs independently. A checksum mismatch fails safely. Concurrent startup is serialized. Cancellation and connection recycling do not leave locks held. Production TLS policy stays enforced.

## Extraction boundaries and risks

**Resolve financial policy conflicts first.** [RUST_STANDARDS.md](../standards/RUST_STANDARDS.md) requires banker's rounding (`MidpointNearestEven`) to two decimal places. The backend currently uses three behaviors:

- [delay penalties](../../backend/src/services/dues_calculation_service.rs#L54) use explicit midpoint-away-from-zero;
- [capital apportionment](../../backend/src/services/capital_project_service.rs#L426) uses `round_dp(2)`, which is banker's rounding but only by default;
- canonical hashes format amounts with `{:.2}`.

Do not silently change working financial behavior during extraction. Decide the authoritative policy for each feature, document any exception or update the standard, pass the strategy explicitly everywhere, and lock it with midpoint fixtures. This report makes no legal determination about the correct penalty rate or allocation policy.

**Separate domain errors from transport.** Fifty service method signatures return `Result<_, String>`, and persistence uses boxed errors. The messages are a mix of Turkish and English user-facing text. That ties the domain to one presentation language and prevents callers from matching on error kinds. Introduce feature-specific typed errors, map them to HTTP envelopes and localized messages at the Axum boundary, and keep domain libraries free of any dependency on `IntoResponse`.

**Decouple the scheduler from handlers.** [scheduler.rs](../../backend/src/scheduler.rs#L5) imports `handlers::apply_advance_payments_offset`, `handlers::ledger_snapshot`, and `handlers::persist_ledger_changes`. Those three functions are ledger persistence logic that sits in the HTTP layer. Move them to a ledger application service so that the scheduler and handlers both depend on it, not on each other.

**Keep residential behavior local.** Delay fees, occupancy transfers, owner-versus-tenant liability, tariffs, and capital-project policy are valuable product logic. Reuse within residential products is plausible. Reuse in unrelated task or expense services is unproven. Model configurable policy only when a real consumer needs a different rule.

**Avoid premature platform packages.** Do not extract all models, the full router, `AppState`, or SaaS CRUD into a shared `common` crate. Do not promote [KuveytTurkSandboxService](../../backend/src/services/kuveyt_turk_service.rs#L6) to a production banking SDK on the strength of sandbox probe and configuration behavior. Live provider behavior was not assessed.

**Make the build hermetic before extraction.** The one failing test depends on `backend/keys/`, which is git-ignored (see [Validation](#validation-and-limitations)). An extracted crate's test suite must pass in a clean checkout. Gate secret-dependent tests behind an explicit opt-in (`#[ignore]` or an environment check that skips with a reported reason).

## Delivery roadmap

1. **Establish behavior contracts and a clean baseline.** Decide rounding ownership. Run `cargo fmt` once in a separate formatting-only commit, so later extraction diffs stay reviewable. Make the sandbox-key test opt-in. Capture parser, folding, apportionment, and canonical-hash behavior as fixtures. Record the intended consumer and success criteria for each extraction. Preserve existing API contracts.
2. **Fix the divergent duplicates.** Route bank-account setup through the IBAN validator. Replace `normalize_turkish` and the `to_slug` folding with `fold_turkish`. Consolidate capital apportionment and add the site filter. Introduce `NormalizedEmail`. These steps are worthwhile within SitePulse even if no other service adopts them.
3. **Organize domain modules.** Add ledger-owned types, typed errors, and a fingerprint module. Move the ledger persistence helpers out of `handlers` and point the scheduler at them. Narrow `lib.rs` exports to what is intended to be public.
4. **Separate import and application execution.** Add parser diagnostics and explicit context. Precompile patterns. Keep reconciliation decisions pure and keep residential matching policy local.
5. **Introduce a payment unit of work.** Preserve current transaction ordering and post-commit state updates. Add database-backed contract and concurrency checks before moving persistence boundaries.
6. **Extract only a proven package.** Add a Cargo workspace once at least one independent consumer uses the proposed library. Good first candidates are the fingerprint/IBAN primitives, hardened statement import, or narrow financial-domain logic. They do not need to ship together. Declare the supported Rust version, dependencies, error contracts, and API ownership.

For each stage, require passing relevant existing tests, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, and the repository persistence checks before accepting code changes. Run the SitePulse full gate with database coverage when it is available, and report unavailable gates separately. Generate the knowledge graph (`graphify . --code-only`) and keep it updated after implementation.

Success is measured by:

- repeated policy implementations removed, with one function per rule;
- financial fixtures unchanged;
- tests that run without constructing all of `AppState`;
- a real second consumer for any extracted crate;
- database atomicity preserved.

No percentage code reduction, throughput gain, or time saving is claimed without measurement.

## Validation and limitations

This is a source-based architecture assessment, not a security certification or a complete defect audit. Findings marked as possible defects (the capital-project site filter, IBAN overflow, and email trimming) come from reading the source and have not been reproduced with new tests. No application code, schema, running service, or graph index was changed. No recurring diagnostic tool was created, because existing source-search and Cargo commands were enough.

Commands executed against the baseline:

| Command | Result |
|---|---|
| `cargo clippy --offline --all-targets -- -D warnings` | **Pass**, zero warnings |
| `cargo fmt --check` | **Fail**, 941 formatting hunks across 40 files (all `src/` and `tests/` files); no `rustfmt.toml` present |
| `cargo test --offline --no-fail-fast` | **142 passed, 1 failed**, exit code 101 |

| Test target | Passed | Failed |
|---|---:|---:|
| Library unit tests | 21 | 0 |
| API security | 7 | 0 |
| Architecture regression | 5 | 0 |
| Financial fixtures | 3 | 0 |
| Integration | 82 | 1 |
| Payment compliance | 8 | 0 |
| Payment ledger hardening | 16 | 0 |

The two binary targets and the doc tests contain zero tests. The failing test is `when_probing_kuveyt_turk_sandbox_status_then_reports_keys_loaded`, at [`tests/integration_tests.rs:895`](../../backend/tests/integration_tests.rs#L895): `status_json.private_key_present` is false. The service looks for `keys/kt-private-key.asc` (overridable with `KT_PRIVATE_KEY_PATH`). `backend/keys/*` is git-ignored, so the file can never exist in a fresh checkout. The failure is caused by the environment and shows a non-hermetic test, not a code regression. No keys were generated and no credentials were changed.

All relative links in this report were checked and point to existing files. Tests increase confidence in current behavior but do not certify the proposed extraction interfaces or database concurrency guarantees.

The .NET and Python workspace suites, Flutter gates, live database checks, and live provider sandbox connectivity tests are outside this documentation-only change. They were not counted as passed. A full production-readiness audit was not performed.

## Implementation status

Implemented on branch `t3/evaluate-rust-backend-reuse` after revision 2. Findings sections above describe the baseline (`106295d`); this table records what changed.

| Finding | Status | Where |
|---|---|---|
| §2 Capital apportionment | **Done.** One largest-remainder function on whole cents, used by both accrual and summary. Shares always sum to the amount; the leftover cent goes to the largest remainder, not to `units[0]`. Units are filtered by `project.site_id`. Summary dues are matched by `CapitalDues` type and the `"<title>: "` period prefix, no longer by any period containing "Demirbaş"/"Asansör". Negative land shares are rejected. | [domain/apportionment.rs](../../backend/src/domain/apportionment.rs), [capital_project_service.rs](../../backend/src/services/capital_project_service.rs), [capital_apportionment_tests.rs](../../backend/tests/capital_apportionment_tests.rs) |
| §3 Turkish folding | **Done.** `fold_turkish` moved to `domain::text` (it also strips decomposed diacritics). `normalize_turkish` and `to_slug` delegate to it, so `İ` no longer yields `i̇` / `i-`. Stored slugs are not regenerated. | [domain/text.rs](../../backend/src/domain/text.rs), [shared_rules_tests.rs](../../backend/tests/shared_rules_tests.rs) |
| §4 IBAN | **Done.** `TrIban` value object: ASCII-checked before slicing, checksum enforced, non-digit BBANs rejected. Bank-account setup now validates check digits and that the IBAN's bank code matches `SupportedBank::eft_code()`. The generator returns `Result`, rejects bad bank codes and unit numbers outside `1..=999999`, and uses `wrapping_add` (same release output, no debug panic). Generated values are unchanged (pinned by test). Known prefix collisions are documented and tested, not changed, because generated IBANs are stored identifiers. | [domain/iban.rs](../../backend/src/domain/iban.rs), [virtual_iban_service.rs](../../backend/src/services/virtual_iban_service.rs), [site_bank_account_service.rs](../../backend/src/services/site_bank_account_service.rs) |
| §5 Email normalization | **Done.** `NormalizedEmail` / `same_email` replace inline lower-casing in services and repositories, so both sides of every comparison are trimmed and lower-cased. Also fixed: the registration-approval person lookup passed the raw request email to `LOWER(email) = $1`. | [domain/email.rs](../../backend/src/domain/email.rs) |
| §6 Fingerprints and signatures | **Done.** Versioned canonical forms (`transfer_*_v1`, `receipt_*_v1`) with golden-hash tests, plus an HMAC verifier that takes the secret as a parameter. Handler/service functions delegate, and their output is byte-identical. A replay window is **not** added: it needs a signed timestamp header agreed with the bank. | [domain/fingerprint.rs](../../backend/src/domain/fingerprint.rs) |
| §7 Statement import | **Partly done.** `parse_statement_report` returns a `ParseReport` with skipped entries and reasons, and takes an injected fallback date. The upload API returns these as `skipped_entries` (additive field). MT940 debits (`D`/`DR`) and reversals (`RC`/`RD`) are no longer imported as positive incoming payments. Regexes compile once (`LazyLock`), with a test that every pattern compiles. **Not done:** quoted-CSV parsing, `.xlsx` decoding, currency detection, and stable cross-import row ids. | [bank_statement_parser.rs](../../backend/src/services/bank_statement_parser.rs), [mt940_engine.rs](../../backend/src/services/mt940_engine.rs) |
| Scheduler/handler coupling | **Done.** `ledger_snapshot`, `persist_ledger_changes`, and `apply_advance_payments_offset` moved to `services::ledger_application`. `handlers` re-exports them for compatibility, and the scheduler no longer imports `handlers`. | [ledger_application.rs](../../backend/src/services/ledger_application.rs) |
| Hermetic tests | **Done.** The Kuveyt Türk key-presence assertions run only with `SITEPULSE_REQUIRE_KT_KEYS=1`; otherwise the test prints an explicit SKIPPED line. | [integration_tests.rs](../../backend/tests/integration_tests.rs#L888) |
| Rounding policy | **Open decision.** Apportionment no longer uses midpoint rounding at all (exact cents). Delay penalties still use midpoint-away-from-zero, which conflicts with RUST_STANDARDS.md. Changing it changes financial results, so it was left for an explicit decision. | — |
| §1 Ledger typed boundary, §8 auth injection, typed service errors, §9 payment unit of work, §11 migration runner | **Not started.** These need API and persistence redesign and database-backed tests. They remain on the roadmap (stages 3, 5, 6). New domain modules use typed `thiserror` errors. | — |
| `cargo fmt` baseline | **Not run.** Formatting all 40 files would bury these changes in a 941-hunk diff. Run it as a separate formatting-only commit. | — |

Test fixtures changed for stricter validation: the bank-setup tests used IBANs with invalid check digits. They now use the same BBANs with correct check digits, and the Flutter test-mode prefill was updated the same way. Seeded and legacy IBANs are not re-validated on read.

## Revision notes

Changes from revision 1 after re-verification against source:

- **Corrected:** "one tracked Rust Cargo package" now also names the `.agents/skills/rust-skills/checks` tooling crate.
- **Corrected:** the IBAN section said bank-account setup used the IBAN helpers. It uses its own prefix/length check and bypasses checksum validation.
- **Corrected:** the migration section implied failure cleanup was missing. The unlock does run after a failure; the remaining risks are unlock failure, cancellation, and pooled-connection reuse.
- **Corrected:** the rounding conflict was described as one exception. There are three distinct behaviors.
- **Corrected:** the scheduler depends on three handler functions, not one.
- **Corrected:** the Flutter fixture consumer is now linked to the actual test file.
- **Added:** capital-project apportionment (duplicated logic, remainder correction applied to the wrong unit and missing from the summary, missing site filter).
- **Added:** a concrete divergence table for Turkish folding.
- **Added:** identity normalization; canonical fingerprints and webhook signatures; per-call regex compilation; IBAN generator overflow and collision cases; error-language coupling; `lib.rs` export surface; hermetic-test requirement.
- **Added:** Clippy and rustfmt gate results, with a formatting-only baseline commit as the first roadmap step.
