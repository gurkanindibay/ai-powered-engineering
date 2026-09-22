# Epic: Backend Persistence, REST APIs & Verification Harness

> **Epic ID:** EPIC-05  
> **Module:** Core Infrastructure (`backend-db`, `backend-service`, `harness`)  
> **Status:** COMPLETED (6 / 6 Stories Completed - 100%)  
> **Target Audience:** Engineering Team, Autonomous Agents, CI/CD Pipeline  
> **Business Value:** Guarantees strict financial correctness, zero rounding drift, automated verification gates, and full CMMI-compliant traceability.

---

## 1. Epic Overview

Establishes the enterprise-grade foundation of the SitePulse platform: PostgreSQL relational persistence with Flyway migrations, Java 21 / Spring Boot 3 domain entities with optimistic locking, REST APIs, and the autonomous Closed-Loop Verification Harness (AST syntax, financial precision, and task DAG scheduling).

---

## 2. User Stories & Acceptance Criteria

### STORY-05-01: PostgreSQL Relational Schema & Flyway Migrations
- **Status:** `COMPLETED`
- **Task Ref:** `task-05`
- **Description:** Implement PostgreSQL relational schema (`siteler`, `bloklar`, `bagimsiz_bolumler`, `aidat_borclari`, `tahsilat_hareketleri`) using Flyway migrations with strict `NUMERIC(15, 2)` monetary columns.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Flyway migrations execute with strict NUMERIC types
    When database migrations execute
    Then tables siteler, bloklar, bagimsiz_bolumler, aidat_borclari are created
    And all monetary balance columns are defined as NUMERIC(15,2)
    And no FLOAT or DOUBLE PRECISION types exist in the schema
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/main/resources/db/migration/V1__init_schema.sql`
- **Verification & Tests:**
  - `SqlSchemaGate.verify_numeric_precision`

---

### STORY-05-02: Spring Boot 3 JPA Entities with Optimistic Locking
- **Status:** `COMPLETED`
- **Task Ref:** `task-06`
- **Description:** Implement JPA domain entities using Spring Data JPA with `@Version` integer columns for optimistic concurrency control to prevent double-charging or race conditions.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Prevent concurrent balance modification race conditions
    Given two concurrent requests attempting to update the same unit balance
    When both commit simultaneously
    Then the second transaction fails with an OptimisticLockException
    And no balance inconsistency or corruption occurs
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/domain/entity/`
- **Verification & Tests:**
  - `JpaEntityGate.verify_version_attribute`

---

### STORY-05-03: Spring Boot REST Controllers & Endpoints
- **Status:** `COMPLETED`
- **Task Ref:** `task-07`
- **Description:** Expose standard REST API controllers for resident dues (`/api/v1/residents/{unitId}/dashboard`), SaaS onboarding (`/api/v1/saas/sites`), home owner provisioning (`/api/v1/site-admin/home-owners`), and invitation approvals (`/api/v1/site-admin/registrations/*`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: REST endpoint provides real-time calculated dues
    When client sends GET request to /api/v1/residents/d-14/dashboard
    Then return 200 OK with totalDue = 1423.33 and penalty = 23.33
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/controller/ResidentDashboardController.java`
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/controller/SiteOnboardingController.java`
  - `apps/development-time/SitePulse/backend/src/main/java/com/sitepulse/backend/controller/RegistrationApprovalController.java`
- **Verification & Tests:**
  - `RestEndpointGate`
  - Spring Boot MockMvc unit tests

---

### STORY-05-04: Closed-Loop Verification Harness & Gate Enforcement
- **Status:** `COMPLETED`
- **Task Ref:** `task-01`, `task-02`
- **Description:** Implement an automated Maker-Checker verification harness that checks Kotlin/Java syntax AST correctness (`SyntaxGate`) and validates KMK statutory financial precision down to 0.0001% without rounding leaks (`FinancialIntegrityGate`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Verification gate rejects floating-point rounding leaks
    Given generated source code introducing float or double in financial packages
    When the FinancialIntegrityGate executes
    Then the verification gate fails and halts task promotion
    And returns an actionable diagnostic feedback message to the maker agent
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/harness/loop/verification_gates/`
  - `apps/development-time/SitePulse/harness/loop/loop_runner.py`
- **Verification & Tests:**
  - `test_financial_integrity_gate_detects_rounding_leak`
  - `test_syntax_gate_detects_unclosed_braces`

---

### STORY-05-05: Unified Automated Test Runner (`run-tests.sh`)
- **Status:** `COMPLETED`
- **Description:** Provide a single-command executable script that runs Python harness self-tests, task DAG closed-loop verification gates, and all backend JUnit service tests with zero manual setup.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Run all system verification tests in one command
    When engineer or CI pipeline runs ./apps/development-time/SitePulse/scripts/run-tests.sh
    Then execute 5 harness tests, 7 task DAG gates, and 9 backend unit tests
    And output green exit code 0 when all tests pass
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/scripts/run-tests.sh`
- **Verification & Tests:**
  - 100% assertions green on execution

---

### STORY-05-06: CMMI Bidirectional Requirements Traceability Matrix & Validator
- **Status:** `COMPLETED`
- **Description:** Implement an automated bi-directional traceability validator (`rtm_validator.py`) ensuring every business requirement traces down to code and test cases, and every code artifact traces back to a requirement.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Validate bidirectional traceability
    When running python3 harness/rtm_validator.py
    Then verify that all requirements in traceability-matrix.md have active task DAG links, existing source files, and test coverage
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/harness/rtm_validator.py`
  - `docs/cmmi-pipeline/traceability-matrix.md`
- **Verification & Tests:**
  - `test_rtm_validator_bidirectional_consistency`
