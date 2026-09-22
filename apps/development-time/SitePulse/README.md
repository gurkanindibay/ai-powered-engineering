# SitePulse: AI-Manufactured Residential Site Management Platform

> **Domain:** Apsiyon-style Apartman & Site Yönetim Platformu (KMK Compliance, Financial Integrity)  
> **Interface:** Android Native (Kotlin 2.x + Jetpack Compose Material 3)  
> **Methodology:** Spec-Driven Development (Spec Kit) + Closed-Loop Harness (Loops & Graphs)  

---

## 📋 Requirements Hierarchy & Completion Status

- **[Full Application Completion Status (96.4% Complete)](COMPLETION_STATUS.md)**: Live traceability dashboard tracking all 28 User Stories, automated verification gates, test coverage, and role matrices.
- **[Requirements Repository (.specify/requirements/)](.specify/requirements/README.md)**:
  - [EPIC-01: Resident Dues Management & Financial Transparency](.specify/requirements/EPIC-01-resident-dues-financial-management.md)
  - [EPIC-02: Site Manager Financial Oversight & Operations](.specify/requirements/EPIC-02-site-manager-operations.md)
  - [EPIC-03: SaaS Multi-Tenancy & Autonomous Site Onboarding](.specify/requirements/EPIC-03-saas-multi-tenancy-onboarding.md)
  - [EPIC-04: Digital Resident Self-Registration & Approval Queue](.specify/requirements/EPIC-04-invitation-approval-workflow.md)
  - [EPIC-05: Backend Persistence, REST APIs & Verification Harness](.specify/requirements/EPIC-05-backend-persistence-verification-harness.md)

---

## 1. Multi-Agent Team & System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    1. Discovery & Design Layer (Spec Kit)                       │
│                                                                                 │
│   .specify/constitution.md         <── Platform Rules (KMK, BigDecimal)         │
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
│   .specify/agents/developer-agent.md <── Developer Agent (Maker: Kotlin/Compose)│
│   .specify/agents/tester-agent.md    <── Tester Agent (Checker: xUnit/JUnit)    │
│   harness/loop/verification_gates    <── Syntax, Financial & Test Gates         │
│   harness/loop/loop_runner.py        <── 3-Iteration Closed Feedback Loop       │
└──────────────────────────────────────┬──────────────────────────────────────────┘
                                       │ Passes Gate
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    4. Verified Full-Stack Deliverables                          │
│                                                                                 │
│   A. Android Native Client (Kotlin / Jetpack Compose / M3)                      │
│      - android/app/.../domain/     (Daire, AidatBorcu, CalculateDuesUseCase)    │
│      - android/app/.../ui/         (DashboardScreen, ViewModel, M3 Theme)       │
│                                                                                 │
│   B. Backend Application (Java 21 / Spring Boot 3.3.4 / REST)                   │
│      - backend/src/.../domain/     (JPA Entities with @Version optimistic lock) │
│      - backend/src/.../service/    (AidatCalculationService - KMK Art. 20)      │
│      - backend/src/.../controller/ (ResidentDashboardController REST API)       │
│                                                                                 │
│   C. Database (PostgreSQL 16+ / Flyway Migrations)                              │
│      - backend/src/.../migration/  (V1__init_schema.sql with NUMERIC(15,2))     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. AI Tooling Instructions (GitHub Copilot & Antigravity)

### GitHub Copilot
- **Spec-Grounded Code Generation**: When creating Kotlin use cases or Spring Boot services, prompt Copilot with the spec context:
  `"Read apps/development-time/SitePulse/.specify/constitution.md and implement the domain logic ensuring BigDecimal is used for all monetary calculations and KMK delay interest is 5% monthly."`
- **Checker Test Generation**: Use Copilot to write tests before implementation:
  `"Generate JUnit tests for CalculateDuesUseCase checking boundary conditions: zero days delay, partial payments, and multiple overdue months."`

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

## 4. Backend & Database Development Environment (Docker)

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
| **Spring Boot App** | `localhost:8080` | `GET /api/v1/residents/d-14/dashboard` |

To tear down the containers:
```bash
./apps/development-time/SitePulse/scripts/dev-db-down.sh
```

---

## 5. Interactive UI/UX Visual Prototype
To preview the Android mobile interface in your browser before running on a device:
- Open [prototype.html](.specify/specs/001-resident-dashboard/assets/prototype.html) in any web browser.
- Supports interactive state toggling between **Borçlu (Gecikmeli)** and **Borçsuz (Ödenmiş)** states.

---

## 6. Running the Android Application

To build, install, and execute the native Jetpack Compose Android app on an emulator or connected device:

```bash
# Standard run (compiles, boots emulator if needed, installs APK, and launches MainActivity)
./apps/development-time/SitePulse/scripts/run-android.sh

# Skip recompilation and run the existing APK
./apps/development-time/SitePulse/scripts/run-android.sh --skip-build

# Run and automatically launch the interactive Web Live Viewer (http://localhost:9090)
./apps/development-time/SitePulse/scripts/run-android.sh --viewer

# Capture a screenshot right after launching
./apps/development-time/SitePulse/scripts/run-android.sh --screenshot
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
   - `POST /api/v1/saas/sites`: Registers a new tenant and provisions site admin credentials.
   - `GET /api/v1/saas/sites`: Fetches all registered tenant sites, metrics, and primary contact details.




