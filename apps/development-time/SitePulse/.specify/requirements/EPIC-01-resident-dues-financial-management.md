# Epic: Resident Dues Management & Financial Transparency

> **Epic ID:** EPIC-01  
> **Module:** Resident Domain & UI (`android-domain`, `android-ui`, `backend-api`)  
> **Status:** IN_PROGRESS (5 / 6 Stories Completed - 83.3%)  
> **Target Audience:** Site Residents (Kat Maliki / Kiracı)  
> **Governing Law:** Kat Mülkiyeti Kanunu (KMK - 634 Sayılı Kanun, Article 20)  

---

## 1. Epic Overview

Provides residents of managed complexes with full transparency into their financial obligations, statutory interest liabilities, payment receipts, and immediate management communication channels without floating-point inaccuracies.

---

## 2. User Stories & Acceptance Criteria

### STORY-01-01: High-Precision Domain Money & Dues Value Objects
- **Status:** `COMPLETED`
- **Task Ref:** `task-01`
- **Description:** Implement immutable domain value objects (`Money`, `AidatBorcu`, `Daire`, `Kisi`) using arbitrary-precision arithmetic (`BigDecimal`). Floating-point types (`float`, `double`) are strictly prohibited to prevent financial rounding drift.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Preserve kuruş-level precision in dues calculation
    Given a resident dues balance of ₺1.450,00 and statutory interest
    When calculations are performed
    Then all monetary fields maintain 2 decimal places with HALF_EVEN rounding
    And zero floating-point drift occurs across successive operations
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/domain/model/ManagerModels.kt`
- **Verification & Tests:**
  - `FinancialIntegrityGate.verify_due_rounding`
  - `DuesCalculatorTests.Should_Preserve_Kurus_Precision`

---

### STORY-01-02: KMK Statutory Delay Fee Calculation Engine
- **Status:** `COMPLETED`
- **Task Ref:** `task-02`
- **Description:** Implement the statutory 5% monthly delay penalty calculation engine pro-rated on a daily basis according to Article 20 of Kat Mülkiyeti Kanunu ($\text{Penalty} = \text{Principal} \times 0.05 \times \frac{\text{DaysOverdue}}{30}$).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Calculate 10-day overdue statutory delay penalty
    Given an unpaid aidat of ₺1.400,00 that is 10 days past due
    When the delay compensation calculator executes
    Then the calculated delay penalty is exactly ₺23,33
    And the total liability displayed is ₺1.423,33
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/domain/model/ManagerModels.kt`
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/service/AidatCalculationService.java`
- **Verification & Tests:**
  - `whenOverdueBy10Days_thenCalculatesExact5PercentProRatedPenalty`
  - `whenNotOverdue_thenPenaltyRemainsZero`
  - `TestSitePulseHarness.test_financial_integrity_gate_kmk_calculation`

---

### STORY-01-03: Reactive Resident Dashboard State Management
- **Status:** `COMPLETED`
- **Task Ref:** `task-03`
- **Description:** Implement `DashboardViewModel` with unidirectional data flow (UDF) using Kotlin Coroutines and `StateFlow` to manage loading, loaded, and error states for resident balances.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Emit reactive state on dashboard launch
    Given a logged-in resident (Ahmet Yılmaz - A Blok D:14)
    When DashboardViewModel initializes
    Then it emits UiState with current balance (₺1.423,33), 10 days overdue badge, and announcements
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardViewModel.kt`
- **Verification & Tests:**
  - `DashboardViewModelTest.testStateFlowEmission`
  - `SyntaxGate`

---

### STORY-01-04: Material 3 Resident Dashboard UI Screens
- **Status:** `COMPLETED`
- **Task Ref:** `task-04`
- **Description:** Build native Jetpack Compose Material 3 screens including Hero Balance Card with overdue badge, quick action grid (`Aidat Öde`, `Dekontlar`, `Arıza Bildir`, `Yönetim`), and announcement banner.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Render resident hero balance and actions
    When the resident launches the app
    Then the Hero Balance Card displays ₺1.423,33 with "10 Gün Gecikme"
    And all action buttons meet the >=48dp touch target accessibility requirement
    And unapproved sub-meter features ("Sayaç Gir", "Rezervasyon") are hidden
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardScreen.kt`
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/theme/Theme.kt`
- **Verification & Tests:**
  - `SyntaxGate.verify_curly_braces`
  - Android emulator visual inspection screenshot

---

### STORY-01-05: Account Movement Ledger & Payment Receipts
- **Status:** `COMPLETED`
- **Task Ref:** `task-04`
- **Description:** Display an itemized ledger of recent transactions showing accrued monthly dues, statutory interest debits, and paid transaction histories with receipt indicators.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: View recent financial movements
    Given an authenticated resident
    When viewing "Hesap Hareketleri"
    Then display "Eylül 2026 Aidatı (₺1.400,00)" and "KMK Gecikme Tazminatı (+₺23,33)"
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardScreen.kt`
- **Verification & Tests:**
  - Visual verification in Android screencap

---

### STORY-01-06: Offline Room Cache & Synchronization Layer
- **Status:** `PENDING`
- **Task Ref:** `task-08`
- **Description:** Implement local SQLite/Room database caching for resident dashboard statements and balance records, gracefully degrading to cached state when offline.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Display cached dues when network is offline
    Given the device is in airplane mode or disconnected
    When the resident opens the dashboard
    Then show last synchronized financial statement with "Çevrimdışı Mod" banner
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/data/` (Planned)
- **Verification & Tests:**
  - `RoomCacheTests.Should_Return_Cached_Statement_On_Network_Timeout`
