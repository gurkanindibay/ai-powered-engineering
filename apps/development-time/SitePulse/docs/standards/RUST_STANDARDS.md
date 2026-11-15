# Rust Engineering & Architectural Standards Specification

> **Version:** 1.2.0  
> **Status:** Active Organizational Standard  
> **Target Toolchain:** Rust 2021 Edition, minimum Rust 1.80 (`std::sync::LazyLock`) & Rust 2024 Readiness  
> **Skill Foundation:** [leonardomso/rust-skills](https://github.com/leonardomso/rust-skills) (265 Rules across 26 Categories)  
> **Local Skill Path:** [.agents/skills/rust-skills/SKILL.md](file:///.agents/skills/rust-skills/SKILL.md)  
> **Governing Agents:** **Architect Agent (System Architect)** & **Developer Agent (The Maker)**  
> **Workflow Skill:** [.agents/skills/sitepulse-rust-backend/SKILL.md](file:///.agents/skills/sitepulse-rust-backend/SKILL.md) (how to apply these rules in the SitePulse backend)  
> **Enforcement:** `scripts/rust_standards_lint.py` (gate `rust-standards-lint`) checks sections 10–16 mechanically  

---

## 1. Executive Summary & Purpose

This standard establishes the non-negotiable architectural rules, domain invariants, memory safety disciplines, error handling taxonomies, and coding standards for all Rust software authored in this workspace.

It directly integrates and operationalizes the **265 rules of the [leonardomso/rust-skills](https://github.com/leonardomso/rust-skills) standard**, dividing responsibilities clearly between:
- **The Architect Agent:** System boundary definition, trait abstractions, API contracts, DTO schemas, concurrency topologies, database schemas & migration design, error taxonomies, and performance budgets.
- **The Developer Agent (Maker):** Zero-defect code synthesis, ownership & borrowing discipline, zero-panic implementation, Clippy compliance (`-D warnings`), persistence validation, and test harness execution.

---

## 2. Rule Categorization & Agent Division Matrix (based on `rust-skills`)

The 26 rule categories from `leonardomso/rust-skills` are formally assigned to agent operational boundaries:

| Priority | Category | Prefix | Governing Agent | Primary Focus |
|:---|:---|:---|:---|:---|
| **CRITICAL** | Ownership & Borrowing | `own-` | **Developer** | `&T` over `.clone()`, slices `&[T]` / `&str` over containers, `Cow<'a, T>`, interior mutability (`RefCell`, `Mutex`, `RwLock`). |
| **CRITICAL** | Error Handling | `err-` | **Both** | **Architect:** Defines `AppError` enums, HTTP mapping, error taxonomy.<br/>**Developer:** Uses `?` propagation, `.context()`, zero `.unwrap()` in production. |
| **CRITICAL** | Memory Optimization | `mem-` | **Developer** | `with_capacity()`, `Box<[T]>`, `SmallVec`, enum variant boxing, clearing collections. |
| **CRITICAL** | Unsafe Code | `unsafe-` | **Architect** | Unsafe code strictly forbidden unless reviewed/permitted by Architect. Must include `// SAFETY:` comments and `cargo miri` passes. |
| **HIGH** | API Design | `api-` | **Architect** | Builder pattern, newtype safety, typestate patterns, sealed traits, `#[must_use]`, parse don't validate. |
| **HIGH** | Async / Await | `async-` | **Both** | **Architect:** Tokio runtime architecture, task topologies, cancellation tokens.<br/>**Developer:** Never hold locks across `.await`, use `spawn_blocking` for CPU-bound tasks, `try_join!`, bounded channels. |
| **HIGH** | Concurrency | `conc-` | **Both** | **Architect:** Lock topologies, state sharing models, atomic memory orderings.<br/>**Developer:** Scoped threads, Rayon `par_iter()`, deadpool connection checkouts. |
| **HIGH** | Compiler Optimization | `opt-` | **Developer** | `#[inline]`, `#[cold]` for error paths, release profiles (`lto`, `codegen-units = 1`). |
| **HIGH** | Numeric & Arithmetic Safety | `num-` | **Both** | **Mandatory:** Zero `f32`/`f64` in financial models. Mandatory `rust_decimal::Decimal`. Explicit overflow handling (`checked_`, `saturating_`). |
| **MEDIUM** | Type Safety | `type-` | **Both** | **Architect:** Newtype IDs (`UserId(i64)`), enum state machines.<br/>**Developer:** Exhaustive matching, Option/Result combinators. |
| **MEDIUM** | Trait & Generics Design | `trait-` | **Architect** | Associated types vs generics, blanket impls, orphan rule compliance, dyn-compatibility. |
| **MEDIUM** | Conversions | `conv-` | **Developer** | Implement `TryFrom` for fallible conversions, `FromStr` for string parsing, `AsRef`/`AsMut`. |
| **MEDIUM** | Const & Compile-Time | `const-` | **Developer** | Inline `const { }` blocks, `const fn`, const generics. |
| **MEDIUM** | Serde | `serde-` | **Architect** | `#[serde(rename_all = "camelCase")]`, `#[serde(default)]`, `#[serde(try_from = ...)]`, custom deserializers. |
| **MEDIUM** | Pattern Matching | `pat-` | **Developer** | `let ... else` for early returns, `matches!()`, exhaustive enum matching without wildcard `_`. |
| **MEDIUM** | Macros | `macro-` | **Developer** | Prefer functions over macros; procedural macros isolated in dedicated crates. |
| **MEDIUM** | Closures | `closure-` | **Developer** | Least restrictive `Fn` trait bounds (`FnOnce` $\to$ `FnMut` $\to$ `Fn`), edition-2021 disjoint captures. |
| **MEDIUM** | Collections | `coll-` | **Developer** | Choose appropriate collections (`HashMap` vs `BTreeMap` vs `VecDeque`), preallocate capacity. |
| **MEDIUM** | Naming Conventions | `name-` | **Both** | `UpperCamelCase` for types/enums, `snake_case` for functions/variables, `as_`/`to_`/`into_` conversion semantics. |
| **MEDIUM** | Testing | `test-` | **Both** | Unit tests in module `tests`, integration tests in `tests/`, deterministic fixtures, boundary fuzzing. |
| **MEDIUM** | Documentation | `doc-` | **Both** | Doc comments `///`, `# Errors`, `# Panics`, `# Safety` sections. |
| **MEDIUM** | Observability | `obs-` | **Both** | Structured tracing (`tracing::info!`, `tracing::error!`), span instrumentation (`#[instrument]`), correlation IDs. |
| **MEDIUM** | Performance Patterns | `perf-` | **Developer** | Minimize allocations, zero-copy parsing, string interning where beneficial. |
| **LOW** | Project Structure | `proj-` | **Architect** | Module hierarchy, clean architecture separation, workspace Cargo configs. |
| **LOW** | Clippy & Linting | `lint-` | **Developer** | `#![deny(unused_must_use)]`, zero warnings under `cargo clippy -- -D warnings`. |
| **REFERENCE** | Anti-patterns | `anti-` | **Developer** | Avoid boolean flags in arguments, clone-to-satisfy-borrow-checker, stringly typed APIs. |

---

## 3. Clean Architecture & Layering Directives

Every Rust application (such as `apps/development-time/SitePulse/backend`) must strictly adhere to the following layer structure:

```mermaid
graph TD
    subgraph Presentation_Layer [Presentation & Transport Layer (Axum 0.7)]
        H[HTTP Handlers & Routers]
        M[Tower Middleware: CORS, Trace]
        DTO[Request / Response DTOs (Serde)]
    end

    subgraph Service_Layer [Business & Application Logic]
        S[Application Services & Use Cases]
        VAL[Domain Validators & Invariant Checkers]
    end

    subgraph Domain_Layer [Pure Domain Core]
        E[Entities & Aggregate Roots]
        VO[Value Objects & Decimals]
        ERR[Domain Error Enums (thiserror)]
    end

    subgraph Persistence_Layer [Persistence & Infrastructure]
        R[Repositories & Query Runners]
        Pool[deadpool-postgres Connection Pool]
        MIG[Append-Only Migrations V*.sql]
    end

    Presentation_Layer --> Service_Layer
    Service_Layer --> Domain_Layer
    Service_Layer --> Persistence_Layer
    Persistence_Layer --> Domain_Layer
```

### 3.1 Architect Responsibilities:
- Design interfaces (traits) in the domain/service layers.
- Define request/response DTO schemas with explicit serde rules (`serde-rename-all`, `serde-deny-unknown-fields`).
- Ensure no database or web framework dependencies enter the core domain.

### 3.2 Developer Responsibilities:
- Implement Axum handlers extracting state via `State(AppState)` (a cheap `Clone` holding `Arc<RwLock<..>>` and the optional pool) and payloads via `Json<T>`.
- Map DTOs to domain entities using `TryFrom` / `From` conversions (`conv-tryfrom-fallible`).
- Keep handlers thin: delegate validation and coordination to the Service Layer.

---

## 4. Financial & Calculation Invariants (Zero Floating-Point)

In accordance with `num-overflow-explicit`, `num-cast-try-from`, and statutory requirements (e.g. Kat Mülkiyeti Kanunu - KMK 634):

1. **Floating-Point Prohibition:**  
   `f32` and `f64` types are **strictly prohibited** in financial domains, balance accounting, interest accruals, dues allocations, and payment calculations.
2. **Mandatory Decimal Type:**  
   All monetary fields, percentages, interest rates, and fee calculations must use `rust_decimal::Decimal`.
3. **Database Column Types:**  
   PostgreSQL financial columns must strictly be `NUMERIC(15, 2)` (or `NUMERIC(18, 4)` for high-precision rates).
4. **Rounding Policy:**  
   Calculations must use banker's rounding (`RoundingStrategy::MidpointNearestEven`) to 2 decimal places (`round_dp_with_strategy(2, ...)`). The strategy is always written out: `round_dp(..)` (implicit strategy) is forbidden. Splitting a total across recipients never rounds per share; it uses `domain::apportion` (largest remainder on whole cents), which guarantees:
   $$\sum \text{UnitShares} = \text{TotalExpense}$$
   **Recorded exception (pending decision):** the KMK 20 delay penalty in `dues_calculation_service.rs` uses `MidpointAwayFromZero`. It must not be changed silently; a change needs a product decision, updated midpoint fixtures in `harness/fixtures/financial_cases.json`, and a note here.
5. **No Loss in Type Narrowing:**  
   Never cast financial IDs or amounts with `as`. Use `From` for lossless widening and `TryFrom` with explicit errors for narrowing.

---

## 5. Error Handling & Resilience (`err-` & `type-`)

1. **Custom Typed Errors (`err-custom-type`, `err-thiserror-lib`):**  
   Domain and library code must use `thiserror` to define structured error enums (`AppError`).
2. **Standardized HTTP Error Envelope:**  
   `AppError` must implement `axum::response::IntoResponse`, returning clean HTTP status codes and a structured JSON payload:
   ```json
   {
     "error": {
       "message": "Human-readable diagnostic",
       "code": 404
     }
   }
   ```
3. **Context Preservation (`err-context-chain`, `err-source-chain`):**  
   Preserve low-level error causes with `#[source]` or `.context("...")`.
4. **Zero Panics in Production (`err-no-unwrap-prod`):**  
   Calling `.unwrap()` or bare `.expect()` in production handler paths or domain services is **strictly forbidden**. Every fallible call must use `?`, `let ... else`, or exhaustive pattern matching.
5. **Document Fallibility (`err-doc-errors`):**  
   Any public function returning `Result` must include an `# Errors` section in its doc comments.

---

## 6. Concurrency & Asynchronous Programming (`async-` & `conc-`)

1. **Locking Discipline (`async-no-lock-await`):**  
   **CRITICAL:** Never hold a `std::sync::MutexGuard` or `std::sync::RwLockReadGuard` across an `.await` boundary. This causes deadlocks and starves the Tokio worker pool. If a lock must span `.await`, use `tokio::sync::Mutex` or restructure the logic to drop the guard before awaiting.
2. **Offloading CPU-Intensive Work (`async-spawn-blocking`):**  
   Expensive operations (Argon2 password hashing, bulk JSON serialization, cryptographic proofs) must be wrapped in `tokio::task::spawn_blocking`.
3. **Channel Backpressure (`async-bounded-channel`):**  
   Never use unbounded channels in production queues. Use `tokio::sync::mpsc::channel(capacity)` to enforce backpressure.
4. **Cancellation Safety (`async-cancel-safety`, `async-cancellation-token`):**  
   Use `tokio_util::sync::CancellationToken` for graceful shutdowns. Ensure branches inside `tokio::select!` are cancellation-safe.

---

## 7. Data Persistence & Migration Integrity

1. **Persistence Verification Lint (`memory_persistence_lint.py`):**  
   The codebase strictly enforces `#![deny(unused_must_use)]`. Discarding database query execution (`let _ = client.query(...)`) or swallowing errors (`.await.ok()`) is a fatal lint failure.
2. **Append-Only Versioned Migrations:**  
   SQL migrations (`backend/migrations/V*.sql`) are strictly immutable once committed. Every new schema change must:
   - Introduce a new sequential file `V<n+1>__descriptive_name.sql`.
   - Be registered in `backend/src/migrations.rs`.
   - Pass the automated upgrade test in `scripts/schema_integrity_check.py`.
3. **Optimistic Locking:**  
   All entity records undergoing concurrent state updates (such as unit balances) must include an integer `version` column. Concurrent update collisions must be reported as a conflict (HTTP 409), never silently overwritten. (`AppError::Conflict` is the target variant once the typed error taxonomy of section 5 is in place.)

---

## 8. Automated Verification Pipeline & Quality Gates

Every code change must pass all gates before delivery:

```bash
# 1. Compile & Syntax AST Gate
cargo check --all-targets

# 2. Strict Clippy Gate (zero warnings)
cargo clippy --all-targets -- -D warnings

# 3. Formatting Standard
cargo fmt --check

# 4. Automated Unit & Integration Tests
cargo test --all-targets

# 5. Persistence Lint, Rust Standards Lint & Financial Integrity Gates
python3 scripts/memory_persistence_lint.py
python3 scripts/rust_standards_lint.py
python3 scripts/run_tests.py --only rust-build,rust-clippy,rust-test,money-fixtures,persistence-lint,rust-standards-lint
```

**Formatting policy.** `cargo fmt --check` does not pass on the legacy files yet. Until the dedicated formatting-only commit lands: new files are `rustfmt`-clean, every file under `src/domain/` is `rustfmt`-clean (hard rule), and the number of unformatted files may only go down (ratchet). Do not reformat a legacy file inside a behavior change; it hides the diff.

---

## 9. Binding Directives for Agents

### 9.1 Binding to Architect Agent
- **Contract Freezing:** The Architect defines all traits, DTO structs, Axum route signatures, and DB schemas before coding begins.
- **Standards Verification:** The Architect validates that designs use `rust_decimal::Decimal`, enforce Clean Architecture separation, and incorporate `rust-skills` API patterns (`api-builder-pattern`, `api-newtype-safety`, `api-typestate`).
- **Review Gate:** The Architect has veto power over any implementation introducing `f32`/`f64` in domain logic, unprincipled mutex locking, or leaking database models to the API boundary.

### 9.2 Binding to Developer Agent (Maker)
- **Mandatory Reference:** The Developer must read `apps/development-time/SitePulse/docs/standards/RUST_STANDARDS.md` and consult [.agents/skills/rust-skills/SKILL.md](file:///.agents/skills/rust-skills/SKILL.md) for detailed rule references.
- **Zero-Warning Obligation:** Code must compile with zero errors and zero Clippy warnings (`-D warnings`).
- **Borrowing First:** Implement borrowing (`&str`, `&[T]`) instead of cloning. Avoid unnecessary heap allocations.
- **Zero Panic Rule:** Zero occurrences of `.unwrap()` in production paths.
- **Persistence Verification:** Ensure all database operations are checked and propagated. Run `memory_persistence_lint.py` before completing any task.
- **SitePulse Workflow:** Follow [.agents/skills/sitepulse-rust-backend/SKILL.md](file:///.agents/skills/sitepulse-rust-backend/SKILL.md) and run `rust_standards_lint.py` (sections 10–16) before completing any task.

---

## 10. Module Layout & Dependency Direction (SitePulse backend)

The layer diagram of section 3 maps onto the crate like this:

| Module | Contains | May depend on | Must not depend on |
|:---|:---|:---|:---|
| `src/domain/` | Pure value objects and rules: `apportionment`, `text`, `iban`, `email`, `fingerprint` | `std`, `rust_decimal`, `chrono`, `thiserror`, crypto crates | `axum`, `tokio_postgres`, `deadpool_postgres`, `reqwest`, `crate::{state, db, services, handlers, auth}`, `std::env`, global state |
| `src/services/` | Use cases and residential policy (ledger, reconciliation, capital projects, ...) | `domain`, `models`, `db`, `state` | `handlers` |
| `src/db/` | Repositories and transaction helpers | `domain`, `models` | `handlers`, `services` |
| `src/handlers/` | Axum extraction, HTTP status mapping, response DTO assembly | everything above | — |
| `src/scheduler.rs` | Background jobs | `services`, `db` | `handlers` |

1. **One rule, one place.** When a rule already has a home in `domain`, call it. Re-implementing it inline is a lint failure (section 16). When a rule has no home and is needed in a second place, move it to `domain` first, then call it from both.
2. **Handlers stay thin.** A function that the scheduler or another service needs does not live in `handlers`. `handlers` may re-export it for compatibility (`pub use`).
3. **Re-exports keep call sites stable.** Moving a function keeps a `pub use` at the old path until every caller is migrated; tests in `tests/` are callers.

## 11. Persisted Contracts

A persisted contract is any value whose exact bytes are stored, printed, or compared later. In SitePulse these include generated virtual IBANs, tenant slugs, webhook payload hashes, receipt verification hashes, receipt numbers, and migration checksums.

1. **Never change a contract in place.** Add a versioned function (`transfer_hash_v2`) and migrate callers deliberately. The canonical forms in `domain::fingerprint` are versioned for this reason.
2. **Pin every contract with a golden test.** The test asserts the literal output for a fixed input, with a message saying it is a persisted contract.
3. **Fixing a bug in a generator must not change existing outputs.** Example: the virtual IBAN overflow was fixed with `wrapping_add` (identical release output), and known prefix collisions were documented and tested instead of re-hashed.
4. **Regeneration needs a migration.** Changing how a stored identifier is derived requires a migration plan for the stored values, not just new code.

## 12. Money Splitting & Rounding

1. Split a total across recipients only with `domain::apportion(total, &weights)`. It works on whole cents, returns shares that sum exactly to the total, and is deterministic (largest remainder, then larger weight, then lower position).
2. Never compute `total / n` per recipient and "fix the drift" on one recipient afterwards.
3. Any view or summary of an apportionment calls the same function as the code that posts it, so displayed and charged amounts cannot differ.
4. Weights are non-negative integers (`u64`). Convert signed inputs with `u64::try_from` and reject negatives with a domain error.
5. Explicit strategy only: `round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven)` unless an exception is recorded in section 4.

## 13. Identity & Text Normalization

1. **Email.** Compare and look up email addresses only through `domain::email`: `NormalizedEmail::parse` for new input, `NormalizedEmail::normalize` for lookup keys and SQL parameters, `same_email(a, b)` for in-memory comparison. Both sides of a comparison are normalized. A SQL `LOWER(email) = $1` needs a normalized `$1`.
2. **Turkish text.** Fold for matching only with `domain::fold_turkish`. It handles `İ`→`i` (dropping U+0307) and decomposed input. Never chain `.to_lowercase().replace('ı', "i")...`: lower-casing `İ` first leaves a combining dot behind.
3. **Identifiers derived from text** (slugs) are persisted contracts (section 11): stored values are never regenerated by a folding change.
4. **IBANs.** Parse and validate only with `domain::TrIban` (checksum, ASCII-before-slicing, bank code). Check `TrIban::bank_code()` against `SupportedBank::eft_code()` when the user selects a bank. Never hand-write `starts_with("TR") && len() == 26`.

## 14. Parsing External Input

Bank statements, webhooks, CSV files, and provider responses are external input.

1. **Report, never drop.** A parser returns accepted records plus a report of rejected entries with a line number and reason (`ParseReport`, `SkippedStatementEntry`). `continue` without recording why is forbidden for external rows.
2. **No hidden clocks.** Fallback values such as "today" are parameters (`fallback_date`), so parsing is deterministic and testable.
3. **Direction and sign are data.** Debits, credits, and reversals are distinguished explicitly. Only entries that are incoming payments may reach reconciliation.
4. **Byte-safe slicing.** Prove input is ASCII (or use `char` iteration) before slicing at fixed offsets; a 26-byte string is not 26 characters.
5. **Precompiled patterns.** Regular expressions are `static NAME: LazyLock<Result<Regex, regex::Error>>`, used via `.as_ref().ok()?` or `.map_err(..)?`, with a unit test asserting every pattern compiles. `Regex::new` inside a function body is forbidden.
6. **State unsupported formats.** Document what a parser does not handle (for example `.xlsx` binary, quoted CSV) and reject it rather than guessing.

## 15. Tenant Scoping & Shared State

1. `AppStateInner` holds every tenant's data. Every read of `inner.units`, `inner.users`, `inner.dues`, or similar collections in a service filters by the site (or unit) the operation belongs to, before any calculation.
2. Every multi-tenant calculation has a test with **two sites** in state that proves the other site is untouched.
3. Do not add new `if let Some(pool)` / `state.pool` branches in services. New persistence goes into a `db` repository function; the ratchet `pool-branch` may only go down.
4. Never hold an `inner` guard across `.await`. Clone or collect what is needed, drop the guard, then await (section 6). Enforced by `lock_scope_lint.py` (gate `lock-lint`).
5. **The tenant comes from the token, not the request.** Every handler that accepts a request type with a `site_id` field takes a `crate::tenancy::TenantScope` and pins the site through it (`scope.pin(..)`, `pin_opt(..)`, `pinned(..)`) before calling a service. A site staff scope turns a missing site into its own and refuses a foreign one (403); only the platform (SaaS admin) scope may name any site. The middleware's body/query scan is a second line of defence, not the first.
6. **Object ids are checked against their owner.** A route whose path carries an id the middleware cannot attribute to a site (capital projects, budgets, receipts) loads the object and checks `scope.allows(&object.site_id)`. A foreign object is reported as **404**, never 403, so ids of other tenants cannot be probed.
7. **Never guess a tenant.** When a record's site is unknown, leave it empty (unattributed) so that no tenant can see it. Fallbacks such as `unwrap_or_else(|| "1".to_string())` or a hard-coded `"site-..."` are forbidden outside `src/state.rs` fixtures and tests.
8. **Tenant transactions bind their tenant.** A transaction opened for one site calls `crate::db::tx_bind_tenant(&tx, site)` first: PostgreSQL row-level security (V21) then hides and refuses every other site's rows inside it, even for a query that forgets its `site_id` predicate. Tenant-scoped reads use `db::begin_tenant_read`. Every table with a tenant key (`site_id`, `unit_id`, `payment_entry_id`, `project_id`, `budget_id`) is passed to `sp_enable_tenant_rls` in a migration; identity tables that span tenants are listed in `RLS_EXEMPT` with a reason.
9. **Reads never move money.** A `GET` takes the state lock for reading only and never settles, offsets or rewrites ledger rows. Advance offsets (avans mahsubu) run on the write paths that create liabilities (accruals) through `services::advance_offset_service::settle_advances`, which books them as same-debtor virman receipts with allocations in one tenant-bound transaction.
10. **No absolute overwrites of the ledger from memory.** Paid amounts and advance balances are changed only by increments inside a locked transaction, each with its ledger row. Writing a balance or a paid amount computed from the in-memory copy back to PostgreSQL is forbidden.
11. **Financial reads fail loudly.** With PostgreSQL, a failed ledger read is a 503 (`LedgerReadError`), never an empty list or the cached in-memory copy.

Rules 5–8 are enforced by `tenant_isolation_lint.py` (gate `tenant-lint`); rules 8–11 are tested against PostgreSQL by `tests/db_tenant_isolation_tests.rs` (gate `rust-db-test`).

## 16. Testing & Mechanical Enforcement

1. **Hermetic by default.** A test needing secrets, keys, a database, or the network is opt-in through an explicit environment variable (for example `SITEPULSE_REQUIRE_KT_KEYS=1`) and prints a `SKIPPED ...` line otherwise. It must not fail in a clean checkout.
2. **Bug fixes start with a failing test** that reproduces the defect at the call site (not only in the extracted helper).
3. **Domain modules carry their own unit tests**, including boundary cases (empty, zero, negative, overflow, multi-byte input).
4. **Shared fixtures** (`harness/fixtures/*.json`) are the channel for cross-language reuse (Rust, Dart, future .NET). Decimal values are strings in fixtures.
5. **`rust_standards_lint.py` enforces** sections 10–15:

| Rule | Kind | Enforces |
|:---|:---|:---|
| `domain-purity` | hard | §10 domain dependency limits |
| `layering` | hard | §10 only `handlers`, `app.rs`, `main.rs` import `crate::handlers` |
| `inline-email`, `inline-turkish-fold`, `inline-iban-check` | hard | §13 shared normalization |
| `regex-per-call` | hard | §14.5 |
| `implicit-rounding`, `float-money` | hard | §4, §12 |
| `ad-hoc-hash` | hard | §11 hashing only in `domain::fingerprint` (allow-list: token hash in `auth.rs`, checksums in `migrations.rs`) |
| `non-english-identifier` | hard | workspace English-only rule |
| `domain-unformatted` | hard | §8 formatting policy |
| `query-flatten` | hard | a struct extracted with `Query<T>` declares its fields inline: `#[serde(flatten)]` makes `serde_urlencoded` pass values as strings, so `page=1` fails with "expected i64". Flatten in JSON bodies is fine |
| `unwrap`, `expect`, `string-error`, `pool-branch`, `unformatted-file` | ratchet | counts in `scripts/rust_standards_baseline.json` may only go down |

After paying down debt, lower the ratchet with `python3 scripts/rust_standards_lint.py --update-baseline`. Never raise a count with `--force` to make a change pass.
