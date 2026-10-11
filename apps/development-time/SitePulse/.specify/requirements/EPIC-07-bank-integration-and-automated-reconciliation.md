# Epic: Bank Account Integration, Virtual IBAN & Automated Dues Reconciliation

> **Epic ID:** EPIC-07  
> **Module:** `backend-rust`, `flutter-ui`, `flutter-domain`  
> **Status:** IN PROGRESS (3 / 6 Stories Completed - STORY-07-01, STORY-07-02, STORY-07-03 Verified)  
> **Target Audience:** `SITE_MANAGER`, `HOME_RESIDENT`, `SAAS_ADMIN`  
> **Governance:** Turkish Condominium Law (634 Sayılı KMK Madde 35), TCMB Açık Bankacılık & 6493 Sayılı Kanun  
> **Business Value:** Automates dues collection and ledger reconciliation directly with Turkish banks (*Kuveyt Türk Sandbox, Garanti BBVA, İş Bankası, Yapı Kredi, Akbank*) and licensed FinTech payment facilitators. Eliminates manual bank statement tracking, removes human matching errors via flat-specific Virtual IBANs (Sanal IBAN) and dynamic FAST TR-Karekods, and provides a zero-permission Excel/MT940 parser for individual developers.

---

## 1. Epic Overview & Architectural Context

In the Turkish property management ecosystem, **KMK Article 35-f** mandates that all dues and contributions must be collected into an official bank account opened in the name of the residential complex (*Site Yönetimi Potansiyel Vergi Numarası*).

This epic solves the operational bottleneck of manually matching bank transfers ("A Blok D:14 Aidat", "Mehmet Bey aidat ödemesi") by introducing three complementary tiers tailored for both enterprise sites and individual software developers:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        BANK RECONCILIATION TIERED ARCHITECTURE                         │
├─────────────────────────┬───────────────────────────────┬──────────────────────────────┤
│ Tier / Solution         │ Technical Mechanism           │ Developer / Site Pre-req     │
├─────────────────────────┼───────────────────────────────┼──────────────────────────────┤
│ Tier 1: Sanal IBAN      │ Dedicated IBAN per flat       │ Site Manager bank agreement  │
│ Tier 2: FAST TR-Karekod │ Dynamic TCMB QR + Instant Pay │ FinTech / Bank FAST API      │
│ Tier 3: Zero-Approval   │ Excel / CSV / MT940 Ingestion │ 0 Permissions, instant start │
└─────────────────────────┴───────────────────────────────┴──────────────────────────────┘
```

---

## 2. User Stories & Acceptance Criteria

### STORY-07-01: Flat-Specific Virtual IBAN (Sanal IBAN) Allocation
- **Status:** `COMPLETED` (Verified with Kuveyt Türk Sandbox, ISO 7064 MOD-97-10 check digits & E2E suite)
- **Target Role:** Site Manager & System
- **Description:** Automatically provision and bind a unique Virtual IBAN sub-account to each apartment (`bagimsiz_bolum_id`) under the site's primary commercial collection account.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Automated allocation of virtual IBAN upon unit setup
    Given a new flat "A Blok Daire 14" is registered in "Begonya Sitesi"
    When the virtual IBAN generation service is triggered
    Then a valid TR Sanal IBAN is generated with format "TR410020504213991067000014"
    And the IBAN is stored immutably against unit "A Blok D:14"
    And the resident sees their dedicated bank IBAN on their mobile dashboard
  ```
- **Implementation Artifacts:**
  - `virtual_iban_service.rs`, `kuveyt_turk_service.rs`, `models/mod.rs`, `handlers/mod.rs`
- **Verification & Tests:**
  - `when_unit_created_then_generates_unique_sanal_iban`
  - `when_querying_resident_dashboard_then_includes_allocated_virtual_iban`
  - `scripts/test-virtual-iban-e2e.sh`

---

### STORY-07-02: Zero-Approval Bank Statement (Excel / CSV / MT940) Parser
- **Status:** `COMPLETED` (Verified with integration & UI test suite)
- **Target Role:** Site Manager (Individual Developer Friendly)
- **Description:** Allow site managers to upload monthly Excel, CSV, or SWIFT MT940 statements exported from any Turkish bank internet branch. An intelligent regex/NLP matcher parses transfer descriptions, extracts block/flat identifiers and resident names, and proposes batch dues clearances.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Site manager uploads bank statement Excel file
    Given the manager uploads an Excel statement containing "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33"
    When the statement parsing engine processes the transaction rows
    Then the engine identifies unit "A Blok D:14" with 100% confidence
    And matches the exact outstanding dues balance ₺1.423,33
    And marks the transaction as "ONAY_BEKLIYOR" in the reconciliation queue
  ```
- **Implementation Artifacts:**
  - `bank_statement_parser.rs`, `mt940_engine.rs`
- **Verification & Tests:**
  - `when_parsing_turkish_bank_excel_then_matches_flat_and_amount`

---

### STORY-07-03: Real-Time Bank Webhook & Payment Notification Listener
- **Status:** `COMPLETED` (Verified with live Sandbox webhook, instant dues clearance & Idempotency Gate)
- **Target Role:** System / Bank Integration
- **Description:** Provide a secure REST webhook endpoint accepting real-time incoming transfer notifications from participating banks (Kuveyt Türk, Garanti BBVA, Yapı Kredi, Akbank) with idempotency keys and automatic settlement to prevent duplicate booking.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Real-time incoming transfer notification from bank
    Given a valid incoming webhook payload to Sanal IBAN "TR410020504213991067000014"
    And payload indicates ₺1460.67 transfer with reference "TXN-KT-LIVE-..."
    When the webhook controller processes the event
    Then the unit "A Blok D:14" dues status transitions to "ODENDI"
    And an official receipt is issued (#DKN-2026-...)
    And subsequent duplicate requests return "DUPLICATE_IGNORED" without double-crediting
  ```
- **Implementation Artifacts:**
  - `handlers/mod.rs` (`handle_bank_incoming_webhook`), `reconciliation_service.rs`
- **Verification & Tests:**
  - `when_bank_webhook_delivers_virtual_iban_payment_then_clears_dues_and_generates_receipt`
  - `when_statement_contains_virtual_iban_then_matches_flat_with_100_percent_confidence`
  - `scripts/test-virtual-iban-e2e.sh`

---

### STORY-07-04: Dynamic FAST TR-Karekod Generation for Mobile Banking Apps
- **Status:** `PLANNED`
- **Target Role:** Home Resident
- **Description:** Generate TCMB / BKM standardized dynamic TR-Karekod strings in the Flutter application. Residents can scan or share the QR code using any Turkish mobile banking app (İşCep, Garanti BBVA, Akbank, Ziraat Mobil, etc.), which pre-fills the site IBAN, exact kuruş balance, and payment reference code.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Resident generates FAST QR code to pay dues
    Given resident "Ahmet Yılmaz" has an outstanding balance of ₺1.423,33
    When they tap "FAST QR ile Öde" on the Hero Balance Card
    Then a compliant TCMB TR-Karekod payload is rendered
    And payload embeds the Site IBAN, amount "1423.33", and subscriber ref "SITE-A14"
    And scanning the QR in any banking app pre-populates all payment fields with zero manual entry
  ```
- **Implementation Artifacts:**
  - `fast_qr_generator_service.dart`, `qr_payment_sheet.dart`
- **Verification & Tests:**
  - `when_generating_qr_then_embeds_standard_tcmb_fast_fields`

---

### STORY-07-05: Automated Ledger Reconciliation & Instant Digital Receipt Emission
- **Status:** `PLANNED`
- **Target Role:** Home Resident & Site Manager
- **Description:** Upon verified settlement of a bank transaction, immediately append an immutable ledger row in `tahsilat_hareketleri`, generate a PDF digital receipt with unique verification hash, and dispatch an in-app push notification and SMS to the resident.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Instant receipt generation on automated reconciliation
    Given a successful bank settlement of ₺1.423,33 for unit "A Blok D:14"
    When ledger reconciliation concludes
    Then an immutable record is inserted into "tahsilat_hareketleri"
    And a signed digital receipt "#DKN-2026-0914" is generated
    And resident receives push notification "Eylül 2026 aidatınız banka transferi ile ödendi"
  ```
- **Implementation Artifacts:**
  - `receipt_service.rs`, `models/mod.rs`
- **Verification & Tests:**
  - `when_settled_then_generates_immutable_receipt`

---

### STORY-07-06: Bank Account API Credentials & Delegation Vault
- **Status:** `PLANNED`
- **Target Role:** Site Manager & SaaS Admin
- **Description:** Provide a secure configuration screen where Site Managers can store their site's authorized bank API keys (`client_id`, `client_secret`, `sftp_credentials`) encrypted at rest with AES-256. This enables individual developers to operate as software providers while the legal banking agreement remains between the site management and the bank.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Site manager securely configures site bank credentials
    Given a logged-in site manager with permission "MANAGE_FINANCE"
    When they enter the site's Garanti BBVA corporate API credentials
    Then credentials are encrypted with AES-256 before persisting
    And a test connection probe validates API connectivity with the bank
  ```
- **Implementation Artifacts:**
  - `bank_vault_service.rs`, `models/mod.rs`
- **Verification & Tests:**
  - `when_saving_credentials_then_encrypted_with_aes256`

---

## 3. Harness Verification Gates

To ensure financial and security integrity, all code generated for EPIC-07 must pass:
1. **Financial Precision Gate:** Exact `rust_decimal::Decimal` and `Decimal` reconciliation down to ₺0.01 (zero kuruş discrepancy).
2. **Idempotency Gate:** Duplicate webhook deliveries for the same bank transaction ID must be rejected with HTTP 200 without double-crediting balances.
3. **Security Gate:** Plaintext bank credentials must never be written to logs or transmitted unencrypted.
