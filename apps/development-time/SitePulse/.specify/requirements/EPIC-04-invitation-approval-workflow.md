# Epic: Digital Resident Self-Registration & Approval Queue

> **Epic ID:** EPIC-04  
> **Module:** Invitation & Registration Flow (`backend-api`, `android-ui`, `android-domain`)  
> **Status:** COMPLETED (6 / 6 Stories Completed - 100%)  
> **Target Audience:** Site Admin (Yönetici) and prospective Residents (Kat Maliki / Kiracı)  
> **Business Value:** Eliminates manual data entry bottlenecks by allowing home owners to self-register via a secure link while retaining administrative gatekeeping and verification.

---

## 1. Epic Overview

Enables the Site Admin to generate and broadcast a secure invitation link (via WhatsApp, SMS, or QR). Prospective residents click the link, submit their unit and contact information, and enter the Site Admin's **Onay Bekleyen Başvurular (Approval Queue)**. The admin can verify unit legitimacy, approve with one-tap credential generation (`SP-SAKIN-XXXX`), and synchronize the unit into the active site ledger.

---

## 2. User Stories & Acceptance Criteria

### STORY-04-01: Tokenized Invitation Link Generation API
- **Status:** `COMPLETED`
- **Description:** Expose an API endpoint (`POST /api/v1/site-admin/sites/{siteId}/invite-link`) that generates a time-limited (7 days), URL-safe, cryptographically unique tokenized invitation link (`https://sitepulse.app/join/{slug}?token={token}`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Generate 7-day secure invite link
    Given an authenticated Site Manager for "Begonya Sitesi" (slug: "begonya-sitesi")
    When requesting an invitation link
    Then generate a token with 7-day expiry
    And return URL formatted as "https://sitepulse.app/join/begonya-sitesi?token=SP-INV-XXXX"
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/service/RegistrationApprovalService.java`
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/controller/RegistrationApprovalController.java`
- **Verification & Tests:**
  - `whenGeneratingInviteLink_thenReturnsValidUrlAndToken`

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
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardScreen.kt` (`InviteLinkModalBottomSheet`)
- **Verification & Tests:**
  - Live Android emulator screencap verification

---

### STORY-04-03: Resident Public Self-Registration Submission API
- **Status:** `COMPLETED`
- **Description:** Expose a public endpoint (`POST /api/v1/public/sites/{slug}/join`) accepting resident registration requests with applicant full name, email, phone number, block, flat number, floor, and occupancy type (`OWNER` / `TENANT`), placing the application into a `PENDING` review queue.
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
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/controller/RegistrationApprovalController.java`
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/dto/RegistrationRequestDtos.java`
- **Verification & Tests:**
  - `whenSubmittingSelfRegistration_thenCreatesPendingRequest`

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
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardScreen.kt` (`PendingRegistrationCard`)
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/domain/model/ManagerModels.kt` (`RegistrationRequestItem`)
- **Verification & Tests:**
  - Live Android emulator screencap verification

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
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/service/RegistrationApprovalService.java`
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardScreen.kt` (`RegistrationApprovedDialog`)
- **Verification & Tests:**
  - `whenApprovingPendingRegistration_thenProvisionsUserAndReturnsCredentials`
  - Live Android emulator screencap verification

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
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/service/RegistrationApprovalService.java`
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardViewModel.kt`
- **Verification & Tests:**
  - Unit test in `RegistrationApprovalServiceTest`
