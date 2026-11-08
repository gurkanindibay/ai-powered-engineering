# SitePulse Engineering Constitution (Spec Kit)

> **Version:** 1.0.0  
> **Domain:** Residential Site & Community Management (Apsiyon Model)  
> **Primary Interface:** Cross-Platform Mobile & Web (Flutter / Dart / Material 3)  
> **Platform Governance:** Kat Mülkiyeti Kanunu (KMK - 634 Sayılı Kanun)  

---

## 1. Core Architectural Principles

### 1.1 Kat Mülkiyeti Kanunu (KMK) Compliance
1. **Financial Integrity & Calculation Rules:**
   - Currency must NEVER use floating-point types (`float`, `double`, `f32`, `f64`). All financial balances, dues, and interest calculations must use `rust_decimal::Decimal` (Rust), `Decimal` (Dart/Python), or `BigDecimal`.
   - Statutory Delay Penalty (**Gecikme Tazminatı**): Per KMK Article 20, unpaid dues incur a maximum of 5% monthly delay compensation, pro-rated on a daily basis ($\text{Delay} = \text{Principal} \times 0.05 \times \frac{\text{DaysOverdue}}{30}$).
   - **Arsa Payı Distribution:** When expenses are shared based on land-share ratios, rounding remainders must be reconciled down to the single kuruş (₺0.01) so that $\sum \text{DairePayi} = \text{ToplamGider}$.

2. **Role & Tenancy Segregation:**
   - Every unit (**Bağımsız Bölüm** / Independent Unit) has an immutable relationship with its **Kat Maliki** (Property Owner).
   - A unit may have an optional active **Kiracı** (Tenant).
   - Core dues (operating expenses: kapıcı, temizlik, güvenlik) can be billed to Kiracı or Maliki; capital expenses (demirbaş, çatı onarımı, asansör yenileme) are legally attributable solely to the **Kat Maliki**.

### 1.2 English-Only Code & Engineering Standards
1. **Language Mandate:**
   - All source code, identifiers, types, schemas, tables, columns, variable names, function names, API route paths, tests, and code comments MUST be authored strictly in English.
   - Non-English identifiers (e.g., `Daire`, `AidatBorcu`, `tahsilat_hareketleri`) in source code are strictly prohibited. English domain terms (`ApartmentUnit`, `DuesLiability`, `collection_transactions`, `principal_amount`, `delay_penalty`) must be used exclusively.
   - User-facing UI display labels may provide localized translations, but internal models, data structures, and APIs must remain 100% in English.

---

## 2. Backend & Database Conventions (Rust 2021 + PostgreSQL)

1. **Stack & Versioning:**
   - **Language:** Rust 2021 (LTS Edition)
   - **Framework:** Axum 0.7 + Tokio + tower-http
   - **Database:** PostgreSQL 16+
   - **Migration Tool:** Versioned immutable SQL migration scripts in `migrations/`

2. **Database Schema & Financial Rigor:**
   - **Monetary Columns:** Must strictly use `NUMERIC(15, 2)` in PostgreSQL and `rust_decimal::Decimal` in Rust models. `f32` or `f64` is strictly forbidden.
   - **Auditability:** All financial transactions (tahakkuk, tahsilat, gecikme zammı) must be stored in immutable ledger tables (`tahsilat_hareketleri`) with timestamp, operator ID, and balance snapshot.
   - **Concurrency Control:** Use optimistic locking (`version` integer column) on unit balance records to prevent double-spending or race conditions during payment gateway webhooks.
   - **Referential Integrity:** Enforce foreign keys between `siteler` -> `bloklar` -> `bagimsiz_bolumler` -> `kat_malikleri` and `aidat_tahakkuklari`.

3. **Rust Standards & Agent Governance:**
   - All backend code must strictly adhere to [docs/RUST_STANDARDS.md](../../../../docs/RUST_STANDARDS.md) and [rust-skills](../../../../.agents/skills/rust-skills/SKILL.md) (265 rules across 26 categories).
   - The **Architect Agent** governs API contracts, DTO schemas, and database migrations.
   - The **Developer Agent** guarantees zero Clippy warnings (`-D warnings`), zero unwrap in production, strict borrowing, and persistence safety (`memory_persistence_lint.py`).

---

## 3. Flutter Client Development Conventions

1. **Stack & Versioning:**
   - **Language:** Dart 3.x
   - **UI Framework:** Flutter 3.x with **Material 3 (M3)**
   - **Architecture:** Provider / ChangeNotifier with Unidirectional Data Flow (UDF)
   - **Asynchronous:** Dart `async`/`await` & Streams

2. **UI & Usability Mandates (UI/UX Guardrails):**
   - **Touch Targets:** Minimum 48dp on all clickable elements.
   - **Design Tokens:** All colors and typography must use Material 3 Theme tokens; no hardcoded hex values in widgets.
   - **Papara-Style Full-Screen Navigation Standard:** Desktop-style floating center popups (`AlertDialog`, centered `Dialog`) and partial/half-screen modal bottom sheets are strictly prohibited for interactive flows on mobile interfaces. In accordance with leading Turkish fintech UX (e.g. Papara, Enpara), all multi-step interactions, payment checkouts, detail breakdowns, forms, announcements, and confirmations must open as dedicated, 100% viewport **Full-Screen Pages** (`AppFullscreenPage` / `Navigator.push(MaterialPageRoute(fullscreenDialog: true))`). Each page features a clean `AppBar` (title, subtitle, back/close button) and a sticky bottom action bar (`AppFullscreenPage.buildBottomBar`), and upon completion or dismissal returns cleanly to the exact calling screen via `Navigator.pop()` without layout shifts.
   - **State Handling:** Every screen must explicitly define four states: `Loading`, `Empty`, `Error`, and `Success`.
   - **Accessibility:** Content descriptions on all icons, WCAG 2.1 AA contrast ratios on text and buttons.

3. **Offline-First & State Synchronization:**
   - All resident information and recent balance statements must be cached locally.
   - Network errors must gracefully degrade to offline-cached data with a clear "Çevrimdışı Mod" indicator.

---

## 4. The Harness Loop & Graph Constraints

1. **Topological Task Scheduling:**
   - Code must only be written for tasks whose prerequisites in `task-dag.json` are in the `VERIFIED` state.
   - Core Domain entities must be established and tested before UI ViewModels or API integrations are attempted.

2. **Verification Gates:**
   - **Build Gate:** Code must compile with zero errors and zero warnings.
   - **Financial Precision Gate:** Unit tests must assert exact decimal balances without rounding leaks.
   - **Lint Gate:** Flutter widget and naming conventions must adhere to Dart best practices.
   - **Budget Limit:** A task loop terminates and escalates if verification gates fail after 3 successive iterations.
