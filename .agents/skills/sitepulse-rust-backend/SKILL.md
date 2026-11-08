---
name: sitepulse-rust-backend
description: >
  Workflow for changing the SitePulse Rust backend (apps/development-time/SitePulse/backend):
  where new code goes, which shared domain primitives to reuse (money apportionment, Turkish
  folding, IBAN, email, fingerprints), how to treat persisted contracts, external input and
  tenant scoping, how to test, and which gates to run. Use before writing, reviewing, or
  refactoring any backend Rust code. Complements the generic rust-skills rules and the
  binding standard docs/RUST_STANDARDS.md.
license: MIT
metadata:
  author: Antigravity
  version: "1.0.0"
  standard: docs/RUST_STANDARDS.md v1.2.0 (sections 10-16)
  enforcement: apps/development-time/SitePulse/scripts/rust_standards_lint.py (gate rust-standards-lint)
---

# SitePulse Rust Backend Development

`docs/RUST_STANDARDS.md` says **what** the rules are. This skill says **how** to apply them while
changing the backend, so the same mistakes are not reintroduced. It was written from the
reusability assessment in `docs/reports/rust-backend-reusability-report.md`, which found the same rule
implemented in several places with different behavior (IBAN validation, Turkish folding, email
matching, money splitting) and fixed them.

Generic Rust guidance (ownership, async, error types, API design) lives in
[rust-skills](../rust-skills/SKILL.md). Use that for language questions and this skill for
SitePulse-specific decisions.

---

## 1. Before Writing Code

1. Read the feature spec under `apps/development-time/SitePulse/.specify/specs/` and confirm the task is eligible in the DAG
   (`python3 apps/development-time/SitePulse/harness/harness_cli.py next`).
2. Search for an existing implementation of the rule you need **before** writing one:
   ```bash
   grep -rn "fn <likely_name>\|<distinctive literal>" apps/development-time/SitePulse/backend/src
   ```
   Check `src/domain/` first (section 3 lists what is there).
3. Run the lint once to know the starting point:
   ```bash
   python3 scripts/rust_standards_lint.py
   ```

## 2. Where Does New Code Go?

| You are writing... | Put it in | Notes |
|:---|:---|:---|
| A pure rule over values (calculation, validation, normalization, canonical form) | `src/domain/<topic>.rs` | No I/O, no `AppState`, no `std::env`, typed `thiserror` errors, unit tests in the same file |
| Residential policy or a use case (accrual, allocation order, reconciliation decisions) | `src/services/<feature>_service.rs` | Call `domain` for rules; filter state by site first |
| SQL and transactions | `src/db/<entity>_repository.rs` | Normalize parameters (email!) before binding |
| Axum extraction, status codes, response DTOs | `src/handlers/mod.rs` | Thin: map errors to HTTP and delegate |
| Something the scheduler and handlers both need | `src/services/` (e.g. `ledger_application.rs`) | Never import `crate::handlers` outside handlers/app/main |
| Request/response types | `src/models/mod.rs` | Additive fields get `#[serde(default)]` so older clients keep working |

Decision rule: if a second call site needs a rule, it moves to `domain` **before** the second
call site is written, never after.

## 3. Reuse These Primitives

| Need | Use | Never |
|:---|:---|:---|
| Split a total across units by weight | `domain::apportion(total, &weights)` | `total / n` per unit plus a "drift fix" on one unit |
| Round money | `round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven)` | `round_dp(2)` (implicit), `f32`/`f64` |
| Match Turkish text (bank narratives, names, periods) | `domain::fold_turkish` | `.to_lowercase().replace('ı', "i")...` |
| Build a slug | `services::to_slug` (built on `fold_turkish`) | A new slug function |
| Validate / display an IBAN | `domain::TrIban::parse`, `.bank_code()`, `.grouped()`; `SupportedBank::eft_code()` | `starts_with("TR") && len() == 26`; byte slicing unchecked input |
| Generate a unit virtual IBAN | `VirtualIbanService::generate_virtual_iban` (returns `Result`) | A new hashing scheme (stored values would change) |
| Compare / look up an email | `NormalizedEmail::normalize`, `same_email`, `NormalizedEmail::parse` | `email.to_lowercase()`, `trim()` on one side only |
| Hash a transfer or receipt | `domain::fingerprint::{transfer_hash_v1, receipt_hash_v1}` | A new `format!` + `Sha256` in a handler |
| Verify an HMAC webhook signature | `domain::fingerprint::verify_hmac_sha256_hex(secret, body, sig)` | Reading `std::env` inside the check |
| Parse a bank statement | `BankStatementParser::parse_statement_report(content, format, fallback_date)` | Dropping rows silently, `Utc::now()` inside parsing |
| Persist ledger changes after in-memory settlement | `services::ledger_application::{ledger_snapshot, persist_ledger_changes}` | Importing them from `handlers` |

## 4. Recipes

### 4.1 Add a domain primitive

1. Create `src/domain/<topic>.rs` with a module doc comment that names the rule and its contract.
2. Define a `#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]` error enum. Messages are
   user-presentable English sentences.
3. Prefer a validated newtype (`TrIban`, `NormalizedEmail`) with `parse` over a `bool` validator
   ("parse, don't validate").
4. Register it in `src/domain/mod.rs` (`pub mod` + `pub use`).
5. Unit tests in the same file: valid cases, every error variant, boundaries (empty, zero,
   negative, overflow, multi-byte input), and independent fixtures where a standard exists
   (published IBANs, not ones the module generated).
6. Replace **every** inline copy of the rule with a call, and add a call-site regression test in
   `tests/` for the behavior that was wrong.
7. `rustfmt --edition 2021 src/domain/<topic>.rs` (domain files must be formatted).

### 4.2 Change something stored, printed, or hashed (persisted contract)

1. Find the golden test that pins it. If none exists, write one **first** against the current output.
2. Bug fix that must not change outputs: change the code, keep the golden test green.
3. Deliberate change: add a `_v2` function next to `_v1`, keep `_v1` for stored values, and
   write down how stored values migrate (or why they do not).

### 4.3 Money calculations

1. Inputs and outputs are `Decimal`; database columns are `NUMERIC(15,2)`.
2. Splitting: `apportion`. Summaries call the same function as posting.
3. Any change to a financial result updates `harness/fixtures/financial_cases.json` so the Rust
   and Dart implementations stay aligned, and the `money-fixtures` gate must pass.
4. Do not change the delay-penalty rounding (`MidpointAwayFromZero`) without an explicit product
   decision; it is a recorded exception in RUST_STANDARDS.md section 4.

### 4.4 Parse external input

1. Return accepted records **and** skipped entries with reasons (`ParseReport`).
2. Pass clocks and defaults in as parameters.
3. Treat debit/credit/reversal explicitly; only incoming credits reach reconciliation.
4. Regexes: `static NAME: LazyLock<Result<Regex, regex::Error>>` plus a `pattern_tests` module
   asserting each compiles.
5. Add an additive response field (with `#[serde(default)]`) instead of hiding skipped data.

### 4.5 Touch multi-tenant state

1. Filter `inner.units` / `inner.users` / `inner.dues` by site before calculating.
2. Clone what you need, drop the guard, then `.await`.
3. Write a test with two sites in state proving the other site is untouched
   (see `tests/capital_apportionment_tests.rs`).
4. Handlers: take `scope: crate::tenancy::TenantScope` and pin the request's `site_id`
   (`scope.pin_opt(&mut q.site_id)?` / `scope.pinned(q.site_id)?`). For a path id that is not a
   unit (project, budget, receipt), load the object and return **404** unless
   `scope.allows(&object.site_id)`; see `handlers::capital::scoped_capital_project`.
5. Never guess a tenant (`unwrap_or_else(|| "1".to_string())`): unknown stays empty.
6. A transaction for one site starts with `crate::db::tx_bind_tenant(&tx, site)` (RLS, V19); a
   single-site read uses `crate::db::begin_tenant_read`. A new table with a tenant key gets
   `SELECT sp_enable_tenant_rls(..)` in its migration.
7. GET handlers never move money: take `inner.read()`, no offsets, no ledger writes. Advance
   offsets go through `services::advance_offset_service::settle_advances` on write paths.
8. With PostgreSQL, return a 503 when a ledger read fails, never an empty or cached result.

### 4.6 Fix a bug

1. Reproduce it with a failing test at the call site.
2. Fix it at the rule's home (`domain` or the owning service), not with a local patch.
3. Search for other copies of the same logic (`grep`), and fix or route them too.

## 5. Tests

| Kind | Location | Rule |
|:---|:---|:---|
| Domain unit tests | `#[cfg(test)] mod tests` in the domain file | Boundaries and every error variant |
| Service and call-site behavior | `tests/<area>_tests.rs` | `AppState::new()` memory mode; name tests `when_<situation>_then_<outcome>` |
| Cross-language money | `harness/fixtures/financial_cases.json` + `tests/financial_fixtures.rs` | Decimals as strings |
| Database behavior | `scripts/schema_integrity_check.py`, `scripts/api_system_check.py`, `tests/db_tenant_isolation_tests.rs` (`#[ignore]`, gate `rust-db-test`) | Needs PostgreSQL; memory tests do not prove locking, RLS or constraints |
| Secrets / network | Opt-in via env var (`SITEPULSE_REQUIRE_KT_KEYS=1`) | Print `SKIPPED ...` otherwise; never fail a clean checkout |

## 6. Verification Before Delivery

Run from `apps/development-time/SitePulse/`:

```bash
cd backend && cargo clippy --offline --all-targets -- -D warnings && cargo test --offline --no-fail-fast && cd ..
python3 scripts/rust_standards_lint.py          # hard rules + ratchet (uses cargo fmt --check)
python3 scripts/memory_persistence_lint.py
python3 scripts/tenant_isolation_lint.py       # TenantScope, object ownership, guessed tenants, tx binding, RLS coverage
python3 scripts/lock_scope_lint.py             # no global-state guard held across I/O
python3 scripts/run_tests.py --skip-db          # full gate run; add DB_PASS=... without --skip-db when PostgreSQL is available
```

Report skipped gates as skipped. After paying down debt (fewer `unwrap`, `String` errors, pool
branches, unformatted files), lower the ratchet:

```bash
python3 scripts/rust_standards_lint.py --update-baseline
```

Never use `--force` to raise a count so that a change passes.

## 7. Review Checklist

- [ ] New pure rules live in `src/domain/`, with typed errors and unit tests.
- [ ] No rule re-implemented inline (email, Turkish folding, IBAN, apportionment, hashing).
- [ ] No `crate::handlers` import outside handlers/app/main.
- [ ] Persisted contracts unchanged, or versioned with a migration note; golden tests green.
- [ ] Money: `Decimal` only, explicit rounding strategy, `apportion` for splits, fixtures updated.
- [ ] External input: skipped entries reported, no hidden `Utc::now()`, debits excluded, regexes static.
- [ ] Multi-tenant reads filtered by site; two-site test present; no guard held across `.await`.
- [ ] Site input pinned through `TenantScope`; path object ids checked for ownership (404 if foreign);
      no guessed tenant; tenant transactions call `tx_bind_tenant`; new tenant tables have RLS.
- [ ] GETs are read-only (no offsets, no ledger writes); ledger reads fail with 503, not empty data.
- [ ] No new `unwrap`/`expect` in production paths; new service methods return typed errors.
- [ ] New and domain files `rustfmt`-clean; legacy files not reformatted inside a behavior change.
- [ ] English identifiers; Turkish only inside string literals.
- [ ] clippy, tests, `rust_standards_lint.py`, `memory_persistence_lint.py`, `run_tests.py` run and reported.

## 8. Known Debt (do not copy these patterns)

Tracked by the ratchet and the report's roadmap; new code must not add to them:

- Services return `Result<_, String>` and mix Turkish and English messages (target: typed errors
  mapped to HTTP and localized at the handler boundary).
- Services branch on `state.pool` to keep memory and PostgreSQL in sync (target: repository ports
  and a payment unit of work). The in-memory `AppStateInner` is still the read model in database
  mode and is loaded whole at start-up, so the backend runs as a single instance (the scheduler is
  guarded by an advisory lock, but the cache is not shared).
- Row-level security is permissive when no tenant is bound (start-up load, platform jobs); only
  tenant-bound transactions are isolated by PostgreSQL.
- Capital dues are linked to projects by period text (`"<title>: Taksit n/m"`), not by a project id
  on `DuesLiability`.
- Statement import does not decode `.xlsx` or quoted CSV and assumes TRY.
- Argon2 hashing runs on async workers without `spawn_blocking`.
- Most legacy files are not `rustfmt`-clean (pending a formatting-only commit).
