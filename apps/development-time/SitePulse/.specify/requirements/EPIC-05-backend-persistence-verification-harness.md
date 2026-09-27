# Epic: Backend Persistence, REST APIs & Verification Harness

> **Epic ID:** EPIC-05  
> **Module:** Core Infrastructure (`backend-db`, `backend-rust`, `harness`)  
> **Status:** COMPLETED (6 / 6 Stories Completed - 100%)  
> **Target Audience:** Engineering Team, Autonomous Agents, CI/CD Pipeline  
> **Business Value:** Guarantees strict financial correctness, zero rounding drift, automated verification gates, and full CMMI-compliant traceability.

---

## 1. Epic Overview

Establishes the enterprise-grade foundation of the SitePulse platform: PostgreSQL relational persistence with SQL migrations, Rust 2021 / Axum 0.7 domain models and REST endpoints with strict `rust_decimal::Decimal` precision, and the autonomous Closed-Loop Verification Harness (AST syntax, financial precision, and task DAG scheduling).

---

## 2. User Stories & Acceptance Criteria

### STORY-05-01: PostgreSQL Relational Schema & SQL Migrations
- **Status:** `COMPLETED`
- **Task Ref:** `task-05`
- **Description:** Implement PostgreSQL relational schema (`siteler`, `bloklar`, `bagimsiz_bolumler`, `aidat_borclari`, `tahsilat_hareketleri`) using versioned SQL migrations with strict `NUMERIC(15, 2)` monetary columns.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: SQL migrations execute with strict NUMERIC types
    When database migrations execute
    Then tables siteler, bloklar, bagimsiz_bolumler, aidat_borclari are created
    And all monetary balance columns are defined as NUMERIC(15,2)
    And no FLOAT or DOUBLE PRECISION types exist in the schema
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/migrations/V1__init_schema.sql`
- **Verification & Tests:**
  - `SqlSchemaGate.verify_numeric_precision`

---

### STORY-05-02: Rust Domain Models with High-Precision Decimals
- **Status:** `COMPLETED`
- **Task Ref:** `task-06`
- **Description:** Implement Rust domain models using `rust_decimal::Decimal` with optimistic concurrency versioning to prevent double-charging or race conditions.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Prevent concurrent balance modification race conditions
    Given two concurrent requests attempting to update the same unit balance
    When both commit simultaneously
    Then optimistic locking ensures sequence safety
    And no balance inconsistency or corruption occurs
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/models/mod.rs`
- **Verification & Tests:**
  - `FinancialIntegrityGate.verify_due_rounding`
  - `cargo test` integration suite

---

### STORY-05-03: Rust Axum REST API Handlers & Endpoints
- **Status:** `COMPLETED`
- **Task Ref:** `task-07`
- **Description:** Expose standard REST API handlers for resident dues (`/api/v1/residents/{unitId}/dashboard`), SaaS onboarding (`/api/v1/saas/tenants`), home owner provisioning (`/api/v1/site/home-owners`), and invitation approvals (`/api/v1/site/registration-requests/*`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: REST endpoint provides real-time calculated dues
    When client sends GET request to /api/v1/residents/d-14/dashboard
    Then return 200 OK with totalDue = 1423.33 and penalty = 23.33
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/backend/src/handlers/mod.rs`
- **Verification & Tests:**
  - `RestEndpointGate`
  - `cargo test` Axum integration tests

---

### STORY-05-04: Closed-Loop Verification Harness & Gate Enforcement
- **Status:** `COMPLETED`
- **Task Ref:** `task-01`, `task-02`
- **Description:** Implement an automated Maker-Checker verification harness that checks syntax AST correctness (`SyntaxGate`) and validates KMK statutory financial precision down to 0.0001% without rounding leaks (`FinancialIntegrityGate`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Verification gate rejects floating-point rounding leaks
    Given generated source code introducing float or double in financial packages
    When the FinancialIntegrityGate executes
    Then the verification gate fails and halts task promotion
    And returns an actionable diagnostic feedback message to the maker agent
  ```
- **Implementation Artifacts:**
  - `apps/development-time/SitePulse/harness/loop/verification_gates.py`
  - `apps/development-time/SitePulse/harness/loop/loop_runner.py`
- **Verification & Tests:**
  - `test_financial_integrity_gate_detects_rounding_leak`
  - `test_syntax_gate_detects_unclosed_braces`

---

### STORY-05-05: Unified Automated Test Runner (`run-tests.sh`)
- **Status:** `COMPLETED`
- **Description:** Provide a single-command executable script that runs Python harness self-tests, task DAG closed-loop verification gates, Rust cargo unit/integration tests, and Flutter client tests with zero manual setup.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Run all system verification tests in one command
    When engineer or CI pipeline runs ./apps/development-time/SitePulse/scripts/run-tests.sh
    Then execute harness tests, task DAG gates, Rust cargo tests, and Flutter client tests
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
