# Epic: SaaS Multi-Tenancy & Autonomous Site Onboarding

> **Epic ID:** EPIC-03  
> **Module:** SaaS Platform Architecture (`backend-rust`, `flutter-ui`)  
> **Status:** COMPLETED (6 / 6 Stories Completed - 100%)  
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
  - `apps/development-time/SitePulse/backend/migrations/V1__init_schema.sql`
  - `apps/development-time/SitePulse/backend/src/models/mod.rs`
- **Verification & Tests:**
  - `SqlSchemaGate.verify_numeric_precision`
  - Integration entity tests

---

### STORY-03-02: SaaS Super Admin Management Dashboard
- **Status:** `COMPLETED`
- **Spec Ref:** `SPEC-002`
- **Description:** Provide a specialized cross-platform mobile & web dashboard for SaaS Super Administrators to view total active sites, monthly MRR/ARR dues volume, managed unit count, and portfolio statistics.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: SaaS Admin views portfolio overview
    Given a user with SAAS_ADMIN role
    When accessing the SaaS Super Yönetici dashboard
    Then display active site cards (e.g. Begonya Sitesi, Palmiye Evleri)
    And show cumulative metrics: Total Sites, Total Units, and Monthly Dues volume
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
- **Verification & Tests:**
  - Flutter client integration tests & live verification

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
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
  - `apps/development-time/SitePulse/backend/src/services/saas_tenant_service.rs`
- **Verification & Tests:**
  - `when_registering_new_site_then_provisions_site_and_manager_with_temporary_password` (Rust)
  - Flutter client unit tests

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
  - `apps/development-time/SitePulse/backend/src/services/saas_tenant_service.rs`
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
- **Verification & Tests:**
  - `when_registering_new_site_then_provisions_site_and_manager_with_temporary_password` (Rust)
  - `when_duplicate_email_then_throws_exception` (Rust)

---

### STORY-03-05: Multi-Tenant REST API Endpoints
- **Status:** `COMPLETED`
- **Spec Ref:** `SPEC-002`
- **Description:** Expose standard REST endpoints for registering new tenants and querying the portfolio: `POST /api/v1/saas/tenants` and `GET /api/v1/saas/tenants`.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: REST endpoint returns 201 Created on valid site onboarding
    When sending POST request to /api/v1/saas/tenants with valid payload
    Then the HTTP status code is 201 Created
    And response includes siteId, slug, siteAdminId, and temporaryPassword
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/handlers/mod.rs`
- **Verification & Tests:**
  - Rust Axum integration tests in `tests/integration_tests.rs`

---

### STORY-03-06: Deletion of Inactive / Action-Free Sites
- **Status:** `COMPLETED`
- **Spec Ref:** `SPEC-002 (Section 3.3)`
- **Description:** Allow SaaS Admins to delete a site if and only if no actions (units, dues liabilities, resident registrations) exist for that site. Attempting to delete a site with existing records is strictly blocked.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Delete site without any related actions
    Given a site has zero units, zero dues collection, and zero registration requests
    When SaaS Admin confirms deletion of the site
    Then the site is permanently removed from the system
    And the tenant portfolio is updated

  Scenario: Invariant prevents deletion of active site with transactions
    Given a site has active units or dues records
    When SaaS Admin attempts to delete the site
    Then the deletion request is blocked
    And an explanatory invariant violation error is returned
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/saas_tenant_service.rs`
  - `apps/development-time/SitePulse/backend/src/handlers/mod.rs`
  - `apps/development-time/SitePulse/flutter/lib/ui/dashboard/dashboard_controller.dart`
  - `apps/development-time/SitePulse/flutter/lib/ui/components/saas_admin_view.dart`
  - `apps/development-time/SitePulse/flutter/lib/ui/dashboard/dashboard_screen.dart`
- **Verification & Tests:**
  - `flutter/test/dashboard_controller_test.dart`
  - `flutter/test/widget_test.dart`
  - `backend/tests/saas_tenant_tests.rs`

