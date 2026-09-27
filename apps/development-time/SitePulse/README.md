# SitePulse: AI-Manufactured Residential Site Management Platform

> **Domain:** Apsiyon-style Apartman & Site Yönetim Platformu (KMK Compliance, Financial Integrity)  
> **Interface:** Cross-Platform Mobile & Web (Flutter / Dart Material 3)  
> **Backend:** High-Performance Rust Service (Axum 0.7 + Tokio + rust_decimal)  
> **Methodology:** Spec-Driven Development (Spec Kit) + Closed-Loop Harness (Loops & Graphs)  

---

## 📋 Requirements Hierarchy & Completion Status

- **[Full Application Completion Status (100% Complete)](COMPLETION_STATUS.md)**: Live traceability dashboard tracking all 34 User Stories, automated verification gates, test coverage, and role matrices.
- **[Requirements Repository (.specify/requirements/)](.specify/requirements/README.md)**:
  - [EPIC-01: Resident Dues Management & Financial Transparency](.specify/requirements/EPIC-01-resident-dues-financial-management.md)
  - [EPIC-02: Site Manager Financial Oversight & Operations](.specify/requirements/EPIC-02-site-manager-operations.md)
  - [EPIC-03: SaaS Multi-Tenancy & Autonomous Site Onboarding](.specify/requirements/EPIC-03-saas-multi-tenancy-onboarding.md)
  - [EPIC-04: Digital Resident Self-Registration & Approval Queue](.specify/requirements/EPIC-04-invitation-approval-workflow.md)
  - [EPIC-05: Backend Persistence, REST APIs & Verification Harness](.specify/requirements/EPIC-05-backend-persistence-verification-harness.md)
  - [EPIC-06: Identity, Authentication & Scoped Permission Model](.specify/requirements/EPIC-06-identity-access-auth.md)

---

## 1. Multi-Agent Team & System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    1. Discovery & Design Layer (Spec Kit)                       │
│                                                                                 │
│   .specify/constitution.md         <── Platform Rules (KMK, Decimal Invariants) │
│   .specify/agents/pm-agent.md      <── PM Agent: User Stories & Acceptance Tests│
│   .specify/agents/uiux-agent.md    <── UI/UX Agent: M3 Tokens & HTML Prototypes │
└──────────────────────────────────────┬──────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    2. Architectural Planning & Graph Layer                      │
│                                                                                 │
│   .specify/agents/architect-agent.md <── Architect Agent: Clean Arch & Contracts│
│   .specify/tasks/task-dag.json       <── Topological Task Dependency Graph      │
│   harness/graph/task_dag.py          <── Graph Engine & Task Scheduler          │
└──────────────────────────────────────┬──────────────────────────────────────────┘
                                       │ Schedules Next Task Node
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    3. Closed-Loop Execution Harness (Maker-Checker)             │
│                                                                                 │
│   .specify/agents/developer-agent.md <── Developer Agent (Maker: Flutter/Rust)  │
│   .specify/agents/tester-agent.md    <── Tester Agent (Checker: cargo/flutter)  │
│   harness/loop/verification_gates    <── Syntax, Financial & Test Gates         │
│   harness/loop/loop_runner.py        <── 3-Iteration Closed Feedback Loop       │
└──────────────────────────────────────┬──────────────────────────────────────────┘
                                       │ Passes Gate
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    4. Verified Full-Stack Deliverables                          │
│                                                                                 │
│   A. Cross-Platform Flutter Client (Dart / Material 3)                          │
│      - flutter/lib/domain/         (CalculateDuesUseCase, Money)                │
│      - flutter/lib/controllers/    (DashboardController with ChangeNotifier)    │
│      - flutter/lib/screens/        (DashboardScreen, Modals, Dialogs)           │
│      - flutter/lib/theme/          (SitePulse Parametric Dual-Theme)            │
│                                                                                 │
│   B. High-Performance Backend Application (Rust / Axum 0.7 / Tokio / REST)      │
│      - backend/src/models/         (Domain models with rust_decimal precision)  │
│      - backend/src/services/       (KMK Art. 20 Engine, Auth, SaaS Tenant)      │
│      - backend/src/handlers/       (Axum REST route handlers)                   │
│                                                                                 │
│   C. Database (PostgreSQL 16+ / SQL Migrations)                                 │
│      - backend/migrations/         (V1__init_schema.sql with NUMERIC(15,2))     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. AI Tooling Instructions (GitHub Copilot & Antigravity)

### GitHub Copilot
- **Spec-Grounded Code Generation**: When creating Flutter use cases or Rust Axum services, prompt Copilot with the spec context:
  `"Read apps/development-time/SitePulse/.specify/constitution.md and implement the domain logic ensuring rust_decimal is used for all monetary calculations and KMK delay interest is 5% monthly."`
- **Checker Test Generation**: Use Copilot to write tests before implementation:
  `"Generate tests for CalculateDuesUseCase checking boundary conditions: zero days delay, partial payments, and multiple overdue months."`

### Antigravity
- See workspace rule: [.agents/rules/development-time-inference.md](file:///.agents/rules/development-time-inference.md).
- To inspect task status:
  ```bash
  python3 apps/development-time/SitePulse/harness/harness_cli.py status
  ```
- To verify a completed task:
  ```bash
  python3 apps/development-time/SitePulse/harness/harness_cli.py verify --task <task-id>
  ```

---

## 3. Running the Tests & Harness

### Run Complete Test & Verification Suite
```bash
./apps/development-time/SitePulse/scripts/run-tests.sh
```

### View Task DAG & Progress
```bash
python3 apps/development-time/SitePulse/harness/harness_cli.py status
```

### Find Next Runnable Tasks
```bash
python3 apps/development-time/SitePulse/harness/harness_cli.py next
```

### Verify a Task in the Closed Loop
```bash
python3 apps/development-time/SitePulse/harness/harness_cli.py verify --task task-01
```

### Run Harness Self-Tests Directly
```bash
python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests
```

---

## 4. Backend & Database Development Environment

To run the PostgreSQL 16 database and Adminer web GUI locally:

```bash
# Start PostgreSQL & Adminer with pre-seeded test data
./apps/development-time/SitePulse/scripts/dev-db-up.sh

# Or directly via Docker Compose in backend/
cd apps/development-time/SitePulse/backend && docker compose up -d postgres adminer
```

| Service | Host / Port | Credentials / Purpose |
| :--- | :--- | :--- |
| **PostgreSQL 16** | `localhost:5432` | DB: `sitepulse`, User: `sitepulse_user`, Pass: `sitepulse_secret` |
| **Adminer Web GUI** | `http://localhost:8081` | Web database management client |
| **Rust Axum Backend** | `localhost:8080` | `GET /api/v1/health`, `POST /api/v1/saas/tenants` |

To tear down the containers:
```bash
./apps/development-time/SitePulse/scripts/dev-db-down.sh
```

---

## 5. Running the Backend Service

To run the high-performance Rust backend:

```bash
./apps/development-time/SitePulse/scripts/run-backend.sh
```
Listening on `0.0.0.0:8080` with CORS enabled.

---

## 6. Running the Flutter Application

To build and execute the cross-platform Flutter application:

```bash
# Run Flutter Web Server on port 9090
./apps/development-time/SitePulse/scripts/run-flutter.sh web

# Run on Google Chrome
./apps/development-time/SitePulse/scripts/run-flutter.sh chrome

# Run on connected Android device or emulator
./apps/development-time/SitePulse/scripts/run-flutter.sh android
```

---

## 7. SaaS Multi-Tenancy & Site Admin Auto-Provisioning

SitePulse supports multi-tenant operations where multiple residential sites operate under an isolated SaaS architecture.

### SaaS Super Admin Workflow:
1. **New Site Sale & Registration**:
   - The SaaS Administrator accesses the `SaaS Süper Yönetici` view from the profile bottom sheet.
   - Taps **"+ Yeni Site Kaydet & Yönetici Tanımla"**.
   - Inputs Site Name, City, Unit Count, Plan Type, and Primary Site Admin details (Full Name & Email).
2. **Automated Site Admin Credential Provisioning**:
   - The backend service creates the tenant record and auto-generates a secure temporary password (`SP-XXXX-YYYY`).
   - The credentials dialog is presented to the SaaS Admin with a one-click copyable format to transmit to the customer.
3. **Backend Endpoints**:
   - `POST /api/v1/saas/tenants`: Registers a new tenant and provisions site admin credentials.
   - `GET /api/v1/saas/tenants`: Fetches all registered tenant sites, metrics, and primary contact details.
