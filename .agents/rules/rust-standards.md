---
description: Mandatory Rust Engineering and Architectural Standards (based on leonardomso/rust-skills and workspace clean architecture).
globs: **/*.rs, **/Cargo.toml, apps/development-time/SitePulse/backend/**
---

# Rust Engineering & Architectural Standards Directives

When modifying, generating, or reviewing Rust source code in this workspace:

## 1. Authoritative Standards Reference
- Follow the master specification in [docs/RUST_STANDARDS.md](file:///docs/RUST_STANDARDS.md).
- Apply the 265 rules across 26 categories from [leonardomso/rust-skills](file:///.agents/skills/rust-skills/SKILL.md) (`own-`, `err-`, `mem-`, `unsafe-`, `api-`, `async-`, `conc-`, `opt-`, `num-`, `type-`, `lint-`).

## 2. Core Agent Obligations

### For Architect Agent:
1. **Contract-First Design:** Define DTOs, domain models, and trait interfaces before implementation.
2. **Numeric Safety:** Enforce `rust_decimal::Decimal` and PostgreSQL `NUMERIC(15,2)` for all monetary/calculation fields. Forbid `f32`/`f64`.
3. **Error Taxonomy:** Define strongly typed error enums (`AppError`) with `thiserror` and standard Axum `IntoResponse` JSON error envelopes.
4. **Append-Only Migrations:** Design immutable SQL migrations (`V*.sql`) registered in `migrations.rs`.

### For Developer Agent (The Maker):
1. **Zero Clippy Warnings:** All code must compile cleanly with `cargo clippy --all-targets -- -D warnings`.
2. **Zero Panic in Production:** Never use `.unwrap()` or bare `.expect()` in production handler/service paths. Use `?` operator, `let ... else`, or exhaustive matches.
3. **Borrowing over Cloning:** Accept `&str` and `&[T]` instead of owned containers. Never clone to placate the borrow checker without architectural necessity.
4. **Persistence Integrity:** Respect `#![deny(unused_must_use)]`. Never discard database query results (`let _ = db.query(...)` or `.await.ok()`).
5. **No Locks Across Await:** Never hold a `std::sync::MutexGuard` or `RwLockReadGuard` across an `.await` boundary. Offload CPU-heavy operations to `tokio::task::spawn_blocking`.
6. **Automated Verification:** Execute `python3 scripts/memory_persistence_lint.py` and `cargo test` before submitting changes.
