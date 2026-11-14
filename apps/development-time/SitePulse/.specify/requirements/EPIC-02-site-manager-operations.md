# Epic: Site Manager Financial Oversight & Community Operations

> **Epic ID:** EPIC-02  
> **Module:** Site Manager Dashboard (`flutter-ui`, `flutter-domain`, `backend-rust`)  
> **Status:** COMPLETED (5 / 5 Stories Completed - 100%)  
> **Target Audience:** Site Managers / Management Boards (Site Yöneticisi)  
> **Business Value:** Real-time visibility into collection rates, cash flow, overdue follow-ups, and community notices.

---

## 1. Epic Overview

Enables complex managers to monitor building-wide financial health, inspect individual flat payment statuses, dispatch targeted payment reminders, add new flats/owners manually, and broadcast building announcements.

---

## 2. User Stories & Acceptance Criteria

### STORY-02-01: Complex-Wide Dues Collection Tracking & Progress Metrics
- **Status:** `COMPLETED`
- **Description:** Provide an aggregated financial health overview displaying total monthly dues accrued, total collected, overdue balance, collection percentage, and unit status breakdown (paid count vs overdue count).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Display complex collection progress
    Given a complex with 24 units and total monthly dues of ₺120.000,00
    When the Site Manager opens the management dashboard
    Then show collected amount ₺96.000,00 with "%80 Tahsilat" badge
    And show overdue balance ₺24.000,00 with breakdown (18 Daire Ödendi, 6 Daire Gecikmede)
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
  - `apps/development-time/SitePulse/flutter/lib/models/manager_models.dart`
- **Verification & Tests:**
  - Flutter client integration tests & live verification

Executable scenarios: [`STORY-02-01-collection-tracking.feature`](../features/EPIC-02/STORY-02-01-collection-tracking.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-02-02: Flat-by-Flat Dues Ledger & Filtering
- **Status:** `COMPLETED`
- **Description:** Render an interactive list of all flats in the complex with block, unit number, resident name, payment amount, and overdue day counter, filterable by `Tümü`, `Gecikmede`, and `Ödeyenler`.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Filter overdue flats
    Given the site manager is on the flat ledger
    When selecting "Gecikmede" filter tab
    Then display only flats with overdue status (e.g. A Blok D:14, B Blok D:8)
    And show exact days overdue with red badge
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
- **Verification & Tests:**
  - Flutter client integration tests & live verification

Executable scenarios: [`STORY-02-02-dues-ledger-filtering.feature`](../features/EPIC-02/STORY-02-02-dues-ledger-filtering.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-02-03: Manual Unit & Home Owner Registration
- **Status:** `COMPLETED`
- **Description:** Allow the Site Admin to manually add a new home owner (Kat Maliki / Kiracı) from the manager screen, specifying block, flat number, resident full name, email, and phone, automatically generating resident temporary login credentials.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Admin adds new home owner manually
    Given the Site Manager opens "+ Malik Ekle" modal
    When filling block "B", flat "25", resident "Fatma Şahin", email "fatma@gmail.com"
    And clicking "Kaydet & Şifre Üret"
    Then the unit count increments to 25 Daire
    And a credentials dialog displays generated temporary password "SP-SAKIN-XXXX"
    And the new resident appears in the site ledger
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
  - `apps/development-time/SitePulse/backend/src/services/site_admin_service.rs`
- **Verification & Tests:**
  - `when_registering_home_owner_then_provisions_user_with_resident_password` (Rust)
  - Flutter client unit tests

Executable scenarios: [`STORY-02-03-manual-owner-registration.feature`](../features/EPIC-02/STORY-02-03-manual-owner-registration.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-02-04: Targeted Payment Reminder & Resident Direct Messaging
- **Status:** `COMPLETED`
- **Description:** Enable the Site Manager to trigger payment reminders and direct messages targeting specific overdue residents with pre-filled debt details and channel selection (Push Notification / SMS).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Send reminder to overdue resident
    Given an overdue flat (A Blok D:14) in the manager ledger
    When tapping "Hatırlat" or "Mesaj Gönder"
    Then a prompt allows sending payment notice
    And an in-app confirmation notification notifies the manager of successful dispatch
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
- **Verification & Tests:**
  - Verified via Flutter UI widget tests

Executable scenarios: [`STORY-02-04-payment-reminders.feature`](../features/EPIC-02/STORY-02-04-payment-reminders.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-02-05: Site-Wide Announcement Broadcasting
- **Status:** `COMPLETED`
- **Description:** Provide a broadcasting interface for Site Managers to publish maintenance, water cut, or general assembly announcements that immediately surface on all residents' feeds.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Publish new site announcement
    Given the Site Manager taps "Duyuru Yap"
    When entering title "Planlı Su Kesintisi" and details
    And clicking "Yayınla"
    Then the announcement appears on both manager and resident announcement feeds
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
- **Verification & Tests:**
  - Verified via Flutter UI widget tests

Executable scenarios: [`STORY-02-05-announcements.feature`](../features/EPIC-02/STORY-02-05-announcements.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
