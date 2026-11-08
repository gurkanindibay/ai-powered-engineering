# Unified Logging & Observability Standards Specification

> **Version:** 1.0.0  
> **Status:** Active Organizational Standard  
> **Scope:** Cross-Stack (SitePulse Rust Backend, Flutter Frontend, CI/Harness Verification)  
> **Governing Agents:** **Architect Agent**, **Developer Agent (Maker)**, **Tester Agent (Checker)**  
> **Enforcement Gate:** `logging-standards-lint` (`scripts/logging_standards_lint.py`)  

---

## 1. Executive Summary & Purpose

Diagnosing production anomalies, tracing financial transactions, and debugging distributed client-server interactions requires consistent, structured, and correlated logs. Unstructured, ad-hoc prints (`println!`, `print()`, unlabelled `debugPrint()`) create noise, leak sensitive credentials, break automated parsing, and disconnect client user actions from backend traces.

This standard establishes the non-negotiable requirements for logging across the entire engineering lifecycle:
1. **End-to-End Correlation:** Seamless propagation of `x-request-id` / `trace_id` from Flutter UI actions through Axum backend handlers down to database audit context and back in error envelopes.
2. **Standardized Severity Taxonomy:** Strict semantic usage of `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, and `FATAL`.
3. **Structured Context over Plaintext Strings:** Key-value pairs (`request_id`, `site_id`, `actor_id`, `action`, `duration_ms`, `error_code`) rather than interpolated strings.
4. **Security & PII Redaction:** Complete prohibition of logging raw passwords, bearer tokens, private keys, payment card PANs/CVVs, and unmasked national identification numbers.
5. **Automated Mechanical Enforcement:** Harness gate `logging-standards-lint` fails builds containing unauthorized raw prints or credential logging patterns.

---

## 2. Severity Level Taxonomy

Every log entry across both backend and frontend must use one of the six standard log severity levels:

| Level | Semantic Meaning | When to Use | Production Behavior |
|:---|:---|:---|:---|
| **TRACE** | Fine-grained internal mechanics | Loop iterations, raw byte counts, low-level parser transitions. | Disabled by default in production. |
| **DEBUG** | Diagnostic engineering information | Function entry/exit parameters, query execution plans, cache hit/miss details, outgoing HTTP request details. | Disabled in production, active in development/staging. |
| **INFO** | Normal system milestones & lifecycle | Service boot/shutdown, database migration applied, user successfully logged in, monthly dues accrual batch completed, payment receipt issued, HTTP request completed. | Enabled in all environments. |
| **WARN** | Handled anomalies or unexpected states | Handled network retries, non-fatal fallback applied, rate-limit reached, authentication failure (401), unauthorized access attempt (403), deprecation notice. | Enabled in all environments; monitored for spikes. |
| **ERROR** | Operation failed; user or system impact | Database transaction abort, unexpected 500 error, external bank integration timeout, invariant violation, unhandled exception in background worker. | Enabled in all environments; triggers alerts. |
| **FATAL** | System crash or unrecoverable state | Database schema mismatch on startup, inability to bind server port, corrupted persistence state preventing startup. | Immediate crash log, process termination. |

---

## 3. End-to-End Correlation Architecture

```
[Flutter Frontend]
  │
  ├─ 1. Generates or attaches `x-request-id` (UUIDv4)
  ├─ 2. Logs: AppLogger.debug("--> POST /api/v1/payments/record", traceId: "req-123")
  │
  ▼  HTTP Request Headers: { "x-request-id": "req-123" }
[Axum Rust Backend]
  │
  ├─ 3. `correlate` middleware extracts or creates `request_id` ("req-123")
  ├─ 4. Task-local `AuditContext` records `request_id = "req-123"`
  ├─ 5. Logs: tracing::info!(request_id = "req-123", method = "POST", path = "/api/v1/payments/record", "--> Incoming HTTP request")
  ├─ 6. Database checkout hook sets `sitepulse.audit_context` with "req-123"
  ├─ 7. If error occurs: AppError logs tracing::error!(trace_id = "req-123", ...)
  │
  ▼  HTTP Response Headers: { "x-request-id": "req-123" }
     JSON Error Envelope:   { "error": { "code": "...", "trace_id": "req-123", ... } }
[Flutter Frontend]
  │
  ├─ 8. ApiClient captures `x-request-id` & `trace_id`
  ├─ 9. If non-2xx: throws ApiException(traceId: "req-123", ...)
  └─ 10. Logs: AppLogger.error("<-- 400 POST /api/v1/payments/record FAILED", traceId: "req-123")
```

### Correlation Rules:
1. **Frontend Initiation:** When `ApiClient` sends an HTTP request, if no `x-request-id` header is present, it generates a standard UUIDv4 identifier and attaches it.
2. **Backend Adoption:** Axum's `correlate` middleware inspects the `x-request-id` header. If valid ASCII string (1..=64 chars), it adopts it as the request's correlation ID; otherwise, it generates a fresh UUIDv4.
3. **Response Guarantee:** The server **must** return `x-request-id: <id>` on every response (success, redirect, client error, or internal error).
4. **Error Envelope Mirroring:** Every JSON error envelope returned by the backend (`ErrorEnvelope`) **must** include `trace_id` matching the correlation ID.
5. **Client Exception Binding:** When `ApiClient.decode()` constructs an `ApiException`, the `traceId` property is bound from the JSON envelope or the response header, enabling user feedback and crash reports to quote the exact correlation ID.

---

## 4. Structured Key-Value Fields & Schema

Logs must be structured so that automated ingestion systems (Vector, Datadog, CloudWatch, OpenTelemetry) can index them without regular expressions.

### Standard Field Names:
| Field Name | Type | Description | Example |
|:---|:---|:---|:---|
| `timestamp` | ISO-8601 String | UTC timestamp with millisecond precision | `2026-11-08T18:24:00.123Z` |
| `level` | String | Log level in uppercase | `INFO`, `ERROR` |
| `trace_id` / `request_id` | String | Correlation identifier | `b49f992a-3e81-42cb-b1b7-72fa998a44b1` |
| `tag` / `module` | String | Component or architectural layer | `sitepulse::api::payments`, `ApiClient` |
| `action` | String | Specific business or system action | `record_payment`, `accrue_dues` |
| `site_id` | String / int | Residential site / tenant identifier | `site-101` |
| `actor_id` | String | User ID performing the action | `usr_981` |
| `actor_role` | String | Role of the caller | `SiteManager`, `Auditor` |
| `duration_ms` | Number | Execution time in milliseconds | `42.5` |
| `status_code` | Number | HTTP response status code | `200`, `404`, `500` |
| `error_code` | String | Domain error code | `DUPLICATE_PAYMENT_SUBMISSION` |

---

## 5. Security & PII Redaction Rules

Logs must never compromise user privacy or security credentials:

1. **Passwords & Secrets (Strict Prohibition):**
   - Raw passwords, password hashes, secrets, JWT signing keys, and session cookies must **never** be logged under any level, even `TRACE`.
   - Pattern forbidden in logs: `password`, `admin_password`, `temp_password`, `secret`, `access_token`, `refresh_token`, `google_id_token`.
2. **Payment Card Industry (PCI) Rule:**
   - Primary Account Numbers (PAN), CVVs, and expiration dates must **never** enter application logs.
3. **Turkish Banking & KVKK Privacy Protection:**
   - Full 26-character Turkish IBANs in production logs must be masked to protect homeowner banking privacy:
     - Canonical mask format: `TR12 •••• •••• •••• •••• ••12 34` (keep bank identifier and last 4 digits).
   - Email addresses should be masked when logged in diagnostic contexts:
     - Format: `g***y@example.com`.
   - Turkish Identification Numbers (TCKN) must be masked to the last 4 digits: `*******1234`.

---

## 6. Backend Engineering Standards (Rust & Axum)

### 6.1 Prohibited Primitives
- ❌ **NEVER** use `println!`, `eprintln!`, or `dbg!` in production source code (`backend/src/`).
- ❌ **NEVER** use string interpolation inside log descriptions when structured fields apply:
  - Wrong: `tracing::info!("Payment {} processed for site {} in {}ms", id, site, elapsed);`
  - Correct: `tracing::info!(payment_id = %id, site_id = %site, elapsed_ms = %elapsed, "Payment processed successfully");`

### 6.2 Recommended Tracing Idioms
```rust
// 1. Structured operational milestone
tracing::info!(
    site_id = %site_id,
    period = %period,
    accrued_count = %units.len(),
    total_amount = %total,
    "Monthly dues accrued"
);

// 2. Warn on handled/client error
tracing::warn!(
    request_id = %ctx.request_id,
    actor_id = ?ctx.actor_id,
    attempted_site = %requested_site,
    "Access denied: user not authorized for requested site"
);

// 3. Error on system/database fault
tracing::error!(
    request_id = %ctx.request_id,
    error = %e,
    table = "finance_payment_receipts",
    "Database write failed during payment receipt persistence"
);
```

### 6.3 HTTP Request/Response Tracing
Axum services must run the standard request-tracing middleware that logs:
- **Incoming Request (DEBUG):** Method, URI path, Client IP, Correlation ID.
- **Outgoing Response (INFO if <400, WARN if 4xx, ERROR if 5xx):** Method, URI path, Status Code, Latency in ms, Correlation ID, Actor ID (if authenticated).

---

## 7. Frontend Engineering Standards (Flutter & Dart)

### 7.1 Prohibited Primitives
- ❌ **NEVER** use raw `print(...)` in Flutter code (`flutter/lib/`).
- ❌ **NEVER** use untagged, unstructured `debugPrint('error: $e')` for error handling.

### 7.2 Standardized `AppLogger`
All frontend logging is routed through `AppLogger` (`lib/domain/logging/app_logger.dart`):

```dart
// 1. Debug level logging
AppLogger.debug('Initiating bank reconciliation parser', tag: 'Reconciliation', context: {
  'file_name': file.name,
  'byte_size': file.bytes.length,
});

// 2. Info milestone
AppLogger.info('User session established', tag: 'Auth', traceId: session.traceId, context: {
  'role': session.role,
  'site_id': session.siteId,
});

// 3. Warning
AppLogger.warn('Network request timed out, falling back to cached state', tag: 'Dashboard', error: e);

// 4. Error with stack trace
AppLogger.error('Failed to parse bank statement', tag: 'Reconciliation', error: e, stackTrace: stack);
```

### 7.3 ApiClient Automatic Network Logging
All requests made through `ApiClient` automatically generate:
- `[DEBUG] [ApiClient] --> POST /api/v1/auth/login [trace: a1b2c3d4]`
- `[INFO]  [ApiClient] <-- 200 OK /api/v1/auth/login (124ms) [trace: a1b2c3d4]`
- `[ERROR] [ApiClient] <-- 401 UNAUTHORIZED /api/v1/dues/periods (82ms) [trace: a1b2c3d4, code: AUTHENTICATION_REQUIRED]`

---

## 8. Harness Verification & Enforcement

The logging standards are continuously verified by the Maker-Checker closed loop:

1. **Gate `logging-standards-lint` (`scripts/logging_standards_lint.py`):**
   - Automatically scans `backend/src/` for forbidden `println!`, `eprintln!`, `dbg!`.
   - Scans `flutter/lib/` for forbidden raw `print(`.
   - Scans for sensitive credential logging expressions (`password: $password`, `secret = %`, etc.).
   - Tracks and ratchets down ad-hoc `debugPrint` occurrences toward zero.
2. **Harness Self-Tests (`apps/development-time/SitePulse/harness/tests/test_logging_standards_lint.py`):**
   - Verifies that any breach of logging rules fails the gate with actionable diagnostics.
   - Verifies that clean structured logging passes with zero warnings.
