# Epic: Identity, Authentication & Scoped Permission Model

> **Epic ID:** EPIC-06  
> **Module:** `backend-auth`, `backend-rust`, `flutter-ui`, `flutter-domain`  
> **Status:** COMPLETED (5 / 5 Stories Completed - 100%)  
> **Target Audience:** All Users (`SAAS_ADMIN`, `SITE_MANAGER`, `HOME_OWNER`, `HOME_RESIDENT`)  
> **Business Value:** Provides enterprise-grade authentication with dual login options (Password & Google OAuth2) and strict scoped permissions to safeguard tenant data and individual flat privacy.

---

## 1. Epic Overview

This epic establishes the identity and security framework for the SitePulse platform:
- **Dual Login Methods**:
  1. Standard email + password registration with cryptographic hashing and temporary password change enforcement.
  2. Google OAuth2 / OpenID Connect ("Sign in with Google") with ID token validation and automated account linking.
- **Permission Model (RBAC + Scoped ABAC)**:
  - 4 distinct roles (`SAAS_ADMIN`, `SITE_MANAGER`, `HOME_OWNER`, `HOME_RESIDENT`).
  - 11 fine-grained action permissions.
  - Strict unit-level boundary isolation preventing residents from viewing neighboring flats or managing site finances.

---

## 2. User Stories & Acceptance Criteria

### STORY-06-01: Multi-Role Scoped Permission Matrix (RBAC & Unit Isolation)
- **Status:** `COMPLETED`
- **Target Role:** System / Security Filter
- **Description:** Implement a granular permission matrix mapping roles to action capabilities, enforcing multi-tenant isolation (`site_id`) and unit-level boundary isolation (`bagimsiz_bolum_id`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Home resident restricted from site-wide management
    Given a user with role "HOME_RESIDENT" bound to unit "A Blok D:14"
    When they attempt to access site expense audit or invite other units
    Then access is denied with 403 Forbidden
    And they are permitted only to view dues and open tickets for "A Blok D:14"
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/models/mod.rs` (`Role`, `Permission`)
- **Verification & Tests:**
  - `when_resident_role_then_has_unit_restricted_permissions` (Rust)


Executable scenarios: [`STORY-06-01-role-permission-matrix.feature`](../features/EPIC-06/STORY-06-01-role-permission-matrix.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-06-02: Email & Password Registration & Secure Authentication
- **Status:** `COMPLETED`
- **Target Role:** All Roles
- **Description:** Provide email/password user registration and authentication with cryptographic password hashing, validation rules (min 8 chars, 1 number, 1 uppercase), and mandatory password change enforcement for site-provisioned accounts.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: User registers and authenticates with password
    Given a new user provides valid registration details with password "GucluSifre2026!"
    When registration is submitted
    Then user entity is created with hashed password and provider "LOCAL"
    And logging in with matching credentials issues a valid JWT access token
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/auth_service.rs`
  - `apps/development-time/SitePulse/backend/src/handlers/mod.rs`
- **Verification & Tests:**
  - `when_valid_password_registration_then_can_authenticate` (Rust)
  - `when_wrong_password_then_throws_exception` (Rust)


Executable scenarios: [`STORY-06-02-email-password-authentication.feature`](../features/EPIC-06/STORY-06-02-email-password-authentication.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-06-03: Google OAuth2 / ID Token Authentication & Account Linking
- **Status:** `COMPLETED`
- **Target Role:** All Roles
- **Description:** Enable "Sign in with Google" using Google ID tokens. Validate Google token claims (`sub`, `email`, `name`, `picture`), automatically link existing accounts by email, or provision a new user without requiring a password.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Sign in with Google links existing account
    Given an existing user registered with email "ahmet.yilmaz@gmail.com"
    When they authenticate using a verified Google ID token with matching email
    Then the Google subject ID and avatar URL are linked to their account
    And an authenticated session is returned with auth_provider "GOOGLE"
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/auth_service.rs`
  - `apps/development-time/SitePulse/backend/src/handlers/mod.rs`
- **Verification & Tests:**
  - `when_valid_google_id_token_then_authenticates_and_links_account` (Rust)


Executable scenarios: [`STORY-06-03-google-sign-in.feature`](../features/EPIC-06/STORY-06-03-google-sign-in.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-06-04: JWT Token Minting & Claim-Based Authorization
- **Status:** `COMPLETED`
- **Target Role:** Mobile & Web Clients
- **Description:** Mint standard JWT access tokens containing user claims (`sub`, `email`, `role`, `siteId`, `unitId`, `permissions`) and provide profile inspection endpoints.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: User inspects their active profile and permissions
    Given an authenticated session for "Kat Maliki"
    When inspecting authentication claims
    Then response returns role "HOME_OWNER", unitId "d-14", and permission set including "UNIT_INVITE_CO_RESIDENT"
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/services/auth_service.rs`
  - `apps/development-time/SitePulse/backend/src/models/mod.rs`


Executable scenarios: [`STORY-06-04-jwt-claims-and-profile.feature`](../features/EPIC-06/STORY-06-04-jwt-claims-and-profile.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-06-05: Cross-Platform Flutter Multi-Method Login & Registration Experience
- **Status:** `COMPLETED`
- **Target Role:** Mobile & Web User
- **Description:** Build a Flutter authentication interface supporting Email/Password sign-in/registration and an official "Google ile Giriş Yap" button, with active profile inspection and permission display.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: User chooses Google Sign-In in Flutter
    Given the user is on the SitePulse login screen
    When they tap "Google ile Giriş Yap"
    Then the Google authentication flow completes
    And the app dashboard updates to show their Google profile picture and permissions
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/flutter/lib/models/manager_models.dart`
  - `apps/development-time/SitePulse/flutter/lib/controllers/dashboard_controller.dart`
  - `apps/development-time/SitePulse/flutter/lib/screens/dashboard_screen.dart`
- **Verification & Tests:**
  - Flutter client integration tests & live verification


Executable scenarios: [`STORY-06-05-flutter-login-experience.feature`](../features/EPIC-06/STORY-06-05-flutter-login-experience.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-06-06: Forced Password Change Gate Before Any Operation
- **Status:** `COMPLETED`
- **Target Role:** All Roles (SaaS Admin, Site Manager, Home Owner, Home Resident, Auditor)
- **Description:** An account flagged `must_change_password = true` (bootstrap SaaS admin, onboarded site manager, approved resident, renewed temporary password) may sign in, but must set a permanent password before it can see or do anything else. The server is the authority; the client mirrors it so the user never lands on an empty or broken screen.
- **User Flow:**
  1. User signs in with a temporary password. The login response carries `user.must_change_password = true`.
  2. The client routes straight to the **Şifre Belirleme** screen (`/change-password`) instead of the role dashboard. No tabs, navigation or role data are shown, and no business APIs are called.
  3. Any URL the user opens (bookmark, reload, deep link) is held back and shows the same screen; the link is applied once the password is changed.
  4. The only actions are: change the password (current temporary password + new password + confirmation) or sign out.
  5. On success the server clears the flag, revokes the old sessions and returns new credentials. The client stores them, loads the role's data and opens the role's home page (or the held-back link).
  6. If any business API ever answers `403 PASSWORD_CHANGE_REQUIRED` (e.g. the flag was set again by an admin during the session), the client returns to step 2.
- **Server Rules:**
  - While the flag is set, every authenticated route except `POST /api/v1/auth/change-password`, `GET /api/v1/auth/me`, `POST /api/v1/auth/logout` and `POST /api/v1/auth/logout-all` returns `403` with error code `PASSWORD_CHANGE_REQUIRED`.
  - The new password must differ from the current one; a successful change sets `must_change_password = false` and invalidates earlier sessions.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario Outline: Temporary-password user is held at the password change screen
    Given a <role> account with must_change_password = true
    When the user signs in with the temporary password
    Then the password change screen is shown instead of the dashboard
    And no business data is requested from the server
    When the user sets a new valid password
    Then the <role> home page is shown with the role's data
    And signing in again with the new password does not ask for a change

    Examples:
      | role          |
      | SAAS_ADMIN    |
      | SITE_MANAGER  |
      | HOME_OWNER    |
      | HOME_RESIDENT |
      | AUDITOR       |

  Scenario: Server blocks operations before the password is changed
    Given an authenticated session whose user must change the password
    When the client calls any business endpoint
    Then the server answers 403 with code "PASSWORD_CHANGE_REQUIRED"
    And the client shows the password change screen
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/auth.rs` (route gate)
  - `apps/development-time/SitePulse/backend/src/services/auth_service.rs` (`change_password`)
  - `apps/development-time/SitePulse/flutter/lib/ui/navigation/app_router.dart` (router-level gate)
  - `apps/development-time/SitePulse/flutter/lib/ui/auth/force_password_change_screen.dart`
  - `apps/development-time/SitePulse/flutter/lib/domain/services/api_client.dart` (`passwordChangeRequired` signal)
- **Verification & Tests:**
  - `when_password_change_required_then_business_routes_are_blocked` (Rust)
  - `flutter/test/force_password_change_test.dart` (Flutter, every role)
  - e2e `GUI-06-06`, `GUI-03-03`

Executable scenarios: [`STORY-06-06-forced-password-change-gate.feature`](../features/EPIC-06/STORY-06-06-forced-password-change-gate.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
