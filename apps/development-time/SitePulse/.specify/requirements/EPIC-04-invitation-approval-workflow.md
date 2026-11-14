# Epic: Digital Resident Self-Registration & Approval Queue

> **Epic ID:** EPIC-04  
> **Module:** Invitation & Registration Flow (`backend-rust`, `flutter-ui`, `flutter-domain`)  
> **Status:** COMPLETED (7 / 7 Stories Completed - 100%)  
> **Target Audience:** Site Admin (Yönetici) and prospective Residents (Kat Maliki / Kiracı)  
> **Business Value:** Eliminates manual data entry bottlenecks by allowing home owners to self-register via a secure link while retaining administrative gatekeeping and verification.

---

## 1. Epic Overview

Enables the Site Admin to generate and broadcast a secure invitation link (via WhatsApp, SMS, or QR). Prospective residents click the link, submit their unit and contact information, and enter the Site Admin's **Onay Bekleyen Başvurular (Approval Queue)**. The admin can verify unit legitimacy, approve with one-tap credential generation (`SP-SAKIN-XXXX`), and synchronize the unit into the active site ledger.

---

## 2. User Stories & Acceptance Criteria

### STORY-04-01: Tokenized Invitation Link Generation API
- **Status:** `COMPLETED`
- **Description:** Expose an API endpoint (`POST /api/v1/site/invitations/site`) that generates a time-limited (7 days), URL-safe, cryptographically unique tokenized invitation link (`https://sitepulse.app/join/{slug}?token={token}`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Generate 7-day secure invite link
    Given an authenticated Site Manager for "Begonya Sitesi" (slug: "begonya-sitesi")
    When requesting an invitation link
    Then generate a token with 7-day expiry
    And return URL formatted as "https://sitepulse.app/join/begonya-sitesi?token=SP-INV-XXXX"
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/registration_approval_service.rs`
  - `apps/development-time/SitePulse/backend/src/handlers/mod.rs`
- **Verification & Tests:**
  - `when_generating_invite_link_then_returns_valid_url_and_token` (Rust)


Executable scenarios: [`STORY-04-01-invitation-link-generation.feature`](../features/EPIC-04/STORY-04-01-invitation-link-generation.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-04-02: Quick Action & Modal Bottom Sheet Link Sharing
- **Status:** `COMPLETED`
- **Description:** Provide a **"Davet Linki"** quick action button and dedicated card on the Site Manager dashboard that opens an `InviteLinkModalBottomSheet` with the registration URL, 7-day validity guarantee, one-tap clipboard copy, and direct WhatsApp sharing.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Site Admin copies or shares invite link
    Given the Site Manager taps "Davet Linki"
    When the modal opens
    Then display the invitation URL with copy and WhatsApp share buttons
    And tapping "Linki Kopyala" copies the URL to the clipboard with confirmation
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart` (`InviteLinkModalBottomSheet`)
- **Verification & Tests:**
  - Flutter client integration tests & live verification


Executable scenarios: [`STORY-04-02-invite-link-sharing.feature`](../features/EPIC-04/STORY-04-02-invite-link-sharing.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-04-03: Resident Public Self-Registration Submission API
- **Status:** `COMPLETED`
- **Description:** Expose an endpoint accepting resident registration requests with applicant full name, email, phone number, block, flat number, floor, and occupancy type (`OWNER` / `TENANT`), placing the application into a `PENDING` review queue.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Home owner submits online registration
    Given a valid site invitation link
    When the home owner fills "Kerem Yılmaz", "B Blok D:18", "kerem.yilmaz@gmail.com"
    And submits the form
    Then return 201 Created with status "PENDING"
    And assign a unique requestId (e.g. "req-101")
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/registration_approval_service.rs`
  - `apps/development-time/SitePulse/backend/src/models/mod.rs`
- **Verification & Tests:**
  - `when_submitting_self_registration_then_creates_pending_request` (Rust)


Executable scenarios: [`STORY-04-03-self-registration-submission.feature`](../features/EPIC-04/STORY-04-03-self-registration-submission.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-04-04: Site Manager Real-Time Approval Queue
- **Status:** `COMPLETED`
- **Description:** Display an **"ONAY BEKLEYEN BAŞVURULAR"** section on the Site Manager screen with a real-time pending counter badge (e.g. `2 Bekliyor`), applicant cards showing flat number badge (`B18`), applicant name, floor, ownership type, submission timestamp, and action buttons (`Reddet`, `✓ Onayla & Şifre Üret`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Site manager views pending applications
    Given 2 pending registration requests
    When the site manager views the dashboard
    Then the header badge displays "2 Bekliyor"
    And applicant cards display block, unit, contact info, and submission age
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart` (`PendingRegistrationCard`)
  - `apps/development-time/SitePulse/flutter/lib/models/manager_models.dart` (`RegistrationRequestItem`)
- **Verification & Tests:**
  - Flutter client integration tests & live verification


Executable scenarios: [`STORY-04-04-approval-queue.feature`](../features/EPIC-04/STORY-04-04-approval-queue.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-04-05: One-Tap Approval & Resident Credential Provisioning
- **Status:** `COMPLETED`
- **Description:** When the Site Manager taps **"✓ Onayla & Şifre Üret"**, verify unit availability, generate resident login password (`SP-SAKIN-XXXX`), pop the credentials modal with transmission confirmation, remove the applicant from the queue, decrement the badge, and increment the active site ledger (`24 Daire -> 25 Daire`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Approve applicant and provision account
    Given pending application for "Kerem Yılmaz" (B Blok D:18)
    When Site Manager taps "✓ Onayla & Şifre Üret"
    Then account is activated with generated password "SP-SAKIN-XXXX"
    And confirmation dialog displays credentials
    And Kerem Yılmaz appears in the site dues ledger
    And pending badge decrements from 2 to 1
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/registration_approval_service.rs`
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart` (`RegistrationApprovedDialog`)
- **Verification & Tests:**
  - `when_approving_pending_registration_then_provisions_user_and_returns_credentials` (Rust)
  - Flutter client integration tests


Executable scenarios: [`STORY-04-05-one-tap-approval.feature`](../features/EPIC-04/STORY-04-05-one-tap-approval.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-04-06: Application Rejection with Reason
- **Status:** `COMPLETED`
- **Description:** Provide the Site Manager with the ability to reject erroneous, duplicate, or unverified registration requests (`Reddet`), removing them from the queue and logging a rejection audit status.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Reject unverified registration
    Given a pending application with unverified tenant claims
    When Site Manager clicks "Reddet"
    Then the application status transitions to "REJECTED"
    And the item is removed from the active approval queue
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/registration_approval_service.rs`
  - `apps/development-time/SitePulse/flutter/lib/controllers/dashboard_controller.dart`
- **Verification & Tests:**
  - Unit tests in `integration_tests.rs` (Rust) and Flutter tests


Executable scenarios: [`STORY-04-06-application-rejection.feature`](../features/EPIC-04/STORY-04-06-application-rejection.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-04-07: Unit-Scoped Co-Resident Invitation Link & Home Permissions
- **Status:** `COMPLETED`
- **Description:** Allow verified Home Owners (Kat Maliki) to generate an invitation link bound strictly to their specific unit (`Bağımsız Bölüm`). Persons who register via this link are granted `HOME_RESIDENT` role with permissions and data access restricted exclusively to that specific home.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Home owner generates unit-scoped invitation link
    Given authenticated home owner Ahmet Yılmaz for unit "A Blok D:14" (unitId: "d-14")
    When generating a resident invite link
    Then produce a tokenized URL "https://sitepulse.app/join/begonya-sitesi/units/d-14?token=SP-HANE-XXXX"
    And state security constraint "Bu link sadece A Blok D:14 yetkisi tanımlar. Başka daire bilgilerine erişemez."

  Scenario: Co-resident registers with unit-scoped permissions
    Given a valid unit invite token for "A Blok D:14"
    When Zeynep Yılmaz registers with relationship "SPOUSE"
    Then account is created with role "HOME_RESIDENT" and assigned unitId "d-14"
    And Zeynep can view dues and submit maintenance tickets only for A Blok D:14
    And Zeynep is added to the household member list
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/home_resident_invitation_service.rs`
  - `apps/development-time/SitePulse/backend/src/handlers/mod.rs`
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart` (`HomeResidentInviteBottomSheet`)
- **Verification & Tests:**
  - `when_generating_unit_invite_link_then_returns_unit_scoped_url_and_token` (Rust)
  - `when_registering_home_resident_then_assigns_home_resident_role_and_unit_scope` (Rust)
  - Flutter client integration tests

Executable scenarios: [`STORY-04-07-unit-scoped-invitation.feature`](../features/EPIC-04/STORY-04-07-unit-scoped-invitation.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
