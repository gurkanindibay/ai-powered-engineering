# Epic: SaaS Multi-Tenancy & Autonomous Site Onboarding

> **Epic ID:** EPIC-03  
> **Module:** SaaS Platform Architecture (`backend-api`, `backend-service`, `android-ui`)  
> **Status:** COMPLETED (5 / 5 Stories Completed - 100%)  
> **Target Audience:** SaaS Super Administrator, Sales & Operations Team  
> **Business Value:** Enables SitePulse to scale commercially as a cloud SaaS across hundreds of independent residential complexes.

---

## 1. Epic Overview

Transforms SitePulse from a single-site solution into a multi-tenant SaaS platform where new residential complexes sold to property management companies can be immediately provisioned with tenant data isolation and automated Site Admin credential creation.

---

## 2. User Stories & Acceptance Criteria

### STORY-03-01: Multi-Tenant Architecture & Data Isolation
- **Status:** `COMPLETED`
- **Spec Ref:** `SPEC-002`
- **Description:** Implement logical tenant isolation across all entities (`siteler`, `bloklar`, `bagimsiz_bolumler`, `aidat_borclari`, `tahsilat_hareketleri`) using mandatory `site_id` tenant scoping.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Query operations strictly scoped by tenant
    Given multiple registered sites in the database
    When a Site Manager queries units or finances
    Then queries only return records matching the manager's site_id
    And no cross-tenant data leakage is possible
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/main/resources/db/migration/V1__init_schema.sql`
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/dto/SiteOnboardingDtos.java`
- **Verification & Tests:**
  - `SqlSchemaGate.verify_numeric_precision`
  - Integration entity tests

---

### STORY-03-02: SaaS Super Admin Management Dashboard
- **Status:** `COMPLETED`
- **Spec Ref:** `SPEC-002`
- **Description:** Provide a specialized mobile & web dashboard for SaaS Super Administrators to view total active sites, monthly MRR/ARR dues volume, managed unit count, and portfolio statistics.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: SaaS Admin views portfolio overview
    Given a user with SAAS_ADMIN role
    When accessing the SaaS Super Yönetici dashboard
    Then display active site cards (e.g. Begonya Sitesi, Palmiye Evleri)
    And show cumulative metrics: Total Sites, Total Units, and Monthly Dues volume
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardScreen.kt` (`SaasSuperAdminDashboardContent`)
- **Verification & Tests:**
  - Live Android emulator screencap verification

---

### STORY-03-03: New Site Onboarding & Tenant Provisioning Workflow
- **Status:** `COMPLETED`
- **Spec Ref:** `SPEC-002`
- **Description:** Implement the onboarding workflow for freshly signed residential sites, capturing both Site parameters (Name, City, Unit Count, Plan Tier) and the Primary Site Admin details (Name, Email, Phone) in a unified registration flow.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: SaaS Admin creates new site and provisions first Site Admin
    Given SaaS Admin fills onboarding form for "Palmiye Evleri Sitesi" (Kadıköy, İstanbul, 40 Daire, Pro Paket)
    And provides Primary Site Admin details ("Murat Yıldırım", "murat@palmiyesitesi.com", "0532 444 55 66")
    When submitting the registration
    Then a new site record is created with active status and unique slug "palmiye-evleri-sitesi"
    And a new user is created with role "SITE_MANAGER" bound to this site_id
    And the new site card appears in the SaaS admin portfolio list
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardScreen.kt` (`RegisterSiteModalBottomSheet`)
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/service/SiteOnboardingService.java`
- **Verification & Tests:**
  - `whenRegisteringNewSite_thenProvisionsSiteAndManagerWithTemporaryPassword`
  - Live Android emulator screencap verification

---

### STORY-03-04: Automated Site Manager Account Creation & Credential Provisioning
- **Status:** `COMPLETED`
- **Spec Ref:** `SPEC-002`
- **Description:** Automatically provision the primary Site Manager user account during site onboarding and generate a cryptographically strong temporary password (`SP-XXXX-YYYY`) with a single-tap copy dialog and automated dispatch.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Generate temporary password for newly registered Site Admin
    When a new site is registered with admin email "murat@palmiyesitesi.com"
    Then generate a 12-character temporary password in format "SP-XXXX-YYYY"
    And return response with mustChangePassword = true
    And display a modal with instant copy-to-clipboard functionality
    And trigger SMS credential alert to the manager's mobile number
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/service/SiteOnboardingService.java`
  - `apps/development-time/SitePulse/android/app/src/main/java/com/sitepulse/app/ui/dashboard/DashboardScreen.kt` (`AdminCredentialsProvisionedDialog`)
- **Verification & Tests:**
  - `whenRegisteringNewSite_thenProvisionsSiteAndManagerWithTemporaryPassword`
  - `whenDuplicateEmail_thenThrowsException`

---

### STORY-03-05: Multi-Tenant REST API Endpoints
- **Status:** `COMPLETED`
- **Spec Ref:** `SPEC-002`
- **Description:** Expose standard REST endpoints for registering new tenants and querying the portfolio: `POST /api/v1/saas/sites` and `GET /api/v1/saas/sites`.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: REST endpoint returns 201 Created on valid site onboarding
    When sending POST request to /api/v1/saas/sites with valid payload
    Then the HTTP status code is 201 Created
    And response includes siteId, slug, siteAdminId, and temporaryPassword
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/controller/SiteOnboardingController.java`
- **Verification & Tests:**
  - Unit & MockMvc tests in backend test runner
