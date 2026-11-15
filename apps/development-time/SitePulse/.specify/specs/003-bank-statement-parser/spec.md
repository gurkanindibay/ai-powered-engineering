# Specification: Zero-Approval Bank Statement (Excel / CSV / MT940) Parser & Reconciliation Engine

> **Feature ID:** SPEC-003  
> **Epic ID:** EPIC-07 (STORY-07-02)  
> **Domain:** Automated Bank Statement Ingestion & Dues Reconciliation  
> **Target Roles:** Site Manager (Site Yöneticisi), SaaS Admin  
> **Governance:** Turkish Condominium Law (KMK Madde 35-f), High-Precision Decimal Accounting  

---

## 1. Context & Business Value

Property managers in Turkey spend significant hours manually reviewing bank statements exported from bank internet branches (*Garanti BBVA, İş Bankası, Yapı Kredi, Akbank, QNB, Ziraat*). Managers cross-check transaction narratives ("AHMET YILMAZ A BLOK D:14 EYLUL AIDAT") against apartment lists and manually mark dues as paid.

STORY-07-02 provides a **Zero-Approval / Zero-Permission** solution:
- Allows site managers to immediately ingest bank exports (Excel tabular copy/paste, CSV, or SWIFT MT940 files) without waiting for complex enterprise bank API credentials or legal integrations.
- An intelligent parser extracts block, flat number, resident name, and payment amount.
- Reconciles parsed amounts against outstanding dues liabilities (including KMK Article 20 statutory delay penalties) with exact `rust_decimal::Decimal` precision (zero float loss).
- Matches with 100% confidence when flat identifier, resident name, and outstanding amount align, queueing records as `ONAY_BEKLIYOR`.
- Provides batch approval to clear liabilities and transition dues to `PAID`.

---

## 2. Technical Architecture & Artifacts

### 2.1 Backend Artifacts (Rust / Axum)
- `mt940_engine.rs`: SWIFT MT940 parser handling standard tags (`:20:`, `:25:`, `:28C:`, `:60F:`, `:61:`, `:86:`, `:62F:`).
- `bank_statement_parser.rs`: Universal parser for Excel (TSV/CSV/tabular) and Turkish bank transaction line patterns with intelligent regex matching.
- `reconciliation_service.rs`: Matches parsed bank transactions against `IndependentUnit` roster and `DuesLiability` records, computes confidence scores, and executes batch settlements.
- REST Endpoints:
  - `POST /api/v1/bank/statements/parse`: Parses content and returns matched transactions.
  - `GET /api/v1/bank/statements/reconciliation-queue`: Retrieves pending reconciliation items.
  - `POST /api/v1/bank/statements/confirm-reconciliation`: Confirms selected matches, transitions dues to `PAID`, and marks items as `ONAYLANDI`.

### 2.2 Frontend Artifacts (Flutter UI)
- `bank_statement_reconciliation_page.dart`: Full-screen modal adhering to *Papara-Style Full-Screen Navigation Mandate* (`AppFullscreenPage`).
- Sample preset selector (Garanti BBVA, İş Bankası, SWIFT MT940) for 1-click testability.
- Interactive reconciliation queue with confidence badges, match details, and batch clearance button.

### 2.3 Bank-specific Excel sample downloads
- The bank selector's supported-bank catalogue is the source of truth: `GET /api/v1/site-admin/banks` returns bank code, display name, and statement format. Do not derive availability from a separate hard-coded list.
- In the **Excel / Ekstre Yükle** flow, show a sample workbook download for each catalog bank whose statement format is `EXCEL`. Do not show an Excel sample for a bank whose format is `CSV` or `MT940`, or for a bank absent from the catalogue.
- The current backend catalogue marks **Kuveyt Türk** and **Yapı Kredi** as `EXCEL`. Other currently catalogued banks use CSV or MT940 and therefore have no Excel sample link.
- Each downloadable `.xlsx` must use the corresponding bank label and a workbook layout the current parser can read. Its rows must contain clearly fictional sample transactions, including date, reference, description, and amount, and must be safe to upload without settling real dues. The sample must be generated or packaged as a downloadable file, not presented as an upload action.
- Keep the list data-driven so adding an Excel bank to the supported-bank catalogue exposes its sample without adding a UI-only bank definition. Hide the sample section when no catalogued Excel bank is available.
- **Catalog inconsistency to resolve during implementation:** `backend/db/seed/01-system-seed.sql` and the Flutter `SupportedBank` enum disagree with the backend `SupportedBank` enum/API. The sample UI must use the API result; this feature must not silently expand or redefine supported banks.

---

## 3. Detailed Acceptance Criteria (Gherkin)

```gherkin
Scenario: Site manager uploads bank statement Excel file
  Given the manager uploads an Excel statement containing "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33"
  When the statement parsing engine processes the transaction rows
  Then the engine identifies unit "A Blok D:14" with 100% confidence
  And matches the exact outstanding dues balance ₺1.423,33
  And marks the transaction as "ONAY_BEKLIYOR" in the reconciliation queue

Scenario: Site manager parses SWIFT MT940 bank statement
  Given an MT940 file containing tag :61: with amount 1423,33 and tag :86: with narrative "HAVALE - AHMET YILMAZ A BLOK D:14"
  When the MT940 engine parses the statement
  Then the transaction is extracted with date, amount Decimal("1423.33"), and description
  And matches unit "A Blok D:14" with 100% confidence
  And proposes settlement in the reconciliation queue

Scenario: Batch confirmation clears dues liabilities
  Given a pending reconciliation match for unit "d-14"
  When the site manager confirms the match
  Then the due status transitions to "PAID"
  And the match status transitions to "ONAYLANDI"
  And the collection summary reflects the settled payment
```
