# Rust Engineering & Architectural Standards Specification

> **Version:** 1.1.0  
> **Status:** Active Organizational Standard  
> **Target Toolchain:** Rust 2021 Edition (LTS / 1.78+) & Rust 2024 Readiness  
> **Skill Foundation:** [leonardomso/rust-skills](https://github.com/leonardomso/rust-skills) (265 Rules across 26 Categories)  
> **Local Skill Path:** [.agents/skills/rust-skills/SKILL.md](file:///.agents/skills/rust-skills/SKILL.md)  
> **Governing Agents:** **Architect Agent (System Architect)** & **Developer Agent (The Maker)**  

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
- Implement Axum handlers extracting state via `State(Arc<AppState>)` and payloads via `Json<T>`.
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
   Calculations must use banker's rounding (`RoundingStrategy::MidpointNearestEven`) to 2 decimal places (`round_dp_with_strategy(2, ...)`). Remainder reconciliation must ensure:
   $$\sum \text{UnitShares} = \text{TotalExpense}$$
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
   All entity records undergoing concurrent state updates (such as unit balances) must include an integer `version` column. Concurrent update collisions must return `AppError::Conflict`.

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

# 5. Persistence Lint & Financial Integrity Gates
python3 scripts/memory_persistence_lint.py
python3 scripts/run_tests.py --only rust-build,rust-clippy,rust-test,money-fixtures,persistence-lint
```

---

## 9. Binding Directives for Agents

### 9.1 Binding to Architect Agent
- **Contract Freezing:** The Architect defines all traits, DTO structs, Axum route signatures, and DB schemas before coding begins.
- **Standards Verification:** The Architect validates that designs use `rust_decimal::Decimal`, enforce Clean Architecture separation, and incorporate `rust-skills` API patterns (`api-builder-pattern`, `api-newtype-safety`, `api-typestate`).
- **Review Gate:** The Architect has veto power over any implementation introducing `f32`/`f64` in domain logic, unprincipled mutex locking, or leaking database models to the API boundary.

### 9.2 Binding to Developer Agent (Maker)
- **Mandatory Reference:** The Developer must read `docs/RUST_STANDARDS.md` and consult [.agents/skills/rust-skills/SKILL.md](file:///.agents/skills/rust-skills/SKILL.md) for detailed rule references.
- **Zero-Warning Obligation:** Code must compile with zero errors and zero Clippy warnings (`-D warnings`).
- **Borrowing First:** Implement borrowing (`&str`, `&[T]`) instead of cloning. Avoid unnecessary heap allocations.
- **Zero Panic Rule:** Zero occurrences of `.unwrap()` in production paths.
- **Persistence Verification:** Ensure all database operations are checked and propagated. Run `memory_persistence_lint.py` before completing any task.
