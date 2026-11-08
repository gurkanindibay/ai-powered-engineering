---
description: Mandatory cross-stack logging standards and correlation directives for Backend (Rust) and Frontend (Flutter).
globs: apps/development-time/SitePulse/**, **/*.rs, **/*.dart
---

# Unified Logging & Observability Directives

When authoring, reviewing, or modifying code in this workspace:

## 1. Authoritative Reference
- Follow the master specification in [docs/LOGGING_STANDARDS.md](file:///docs/LOGGING_STANDARDS.md).
- Logging compliance is verified mechanically by `scripts/logging_standards_lint.py` (gate `logging-standards-lint`).

## 2. Core Agent Obligations

### For Architect Agent:
1. **Traceability by Design:** Ensure every public HTTP endpoint and asynchronous task extracts or generates a correlation ID (`x-request-id` / `trace_id`), sets task-local context, and propagates it in all responses and error envelopes.
2. **Schema Uniformity:** Enforce standard key-value fields: `timestamp`, `level`, `trace_id`, `site_id`, `actor_id`, `module`, `action`, `duration_ms`, `status_code`, `error_code`.
3. **Redaction Policy:** Mandate zero-exposure of raw credentials (passwords, tokens, PANs, CVVs) and enforce masking of sensitive PII (TCKN, IBAN, email).

### For Developer Agent (The Maker):
1. **Zero Raw Prints in Production:**
   - **Rust Backend:** Never use `println!`, `eprintln!`, or `dbg!` in `src/`. Use `tracing::info!`, `tracing::warn!`, `tracing::error!`, `tracing::debug!`, or `tracing::trace!`.
   - **Flutter Frontend:** Never use `print(...)` in `lib/`. Use `AppLogger` (`lib/domain/logging/app_logger.dart`). Avoid unlabelled `debugPrint(...)`.
2. **Key-Value Logging over Interpolation:**
   - Prefer `tracing::info!(site_id = %site, count = %n, "Processed batch")` over string interpolation.
   - Prefer `AppLogger.info("Processed batch", tag: "Batch", context: {"site_id": site, "count": n})`.
3. **End-to-End Correlation:**
   - In Flutter: `ApiClient` automatically sends `x-request-id` header and captures response trace IDs into `ApiException`.
   - In Rust: Axum middleware `correlate` and request logger ensure request ID is logged on incoming requests, outgoing responses, and attached to error responses.
4. **Detailed Debug Logging:**
   - Log at `DEBUG` for function parameters, parser decisions, matching criteria evaluation, and state transitions to allow rapid troubleshooting in development.
   - Log at `INFO` for milestone lifecycle events (user login, dues accrual, receipt allocation, database migrations).
   - Log at `WARN` for handled exceptions, client 4xx rejections, and fallback paths.
   - Log at `ERROR` for system failures, unhandled errors, and database persistence errors with `trace_id`.

### For Tester Agent (The Checker):
1. Verify that `logging-standards-lint` passes without regression.
2. Verify that `test_logging_standards_lint.py` covers all edge cases.
3. Validate that end-to-end integration tests check for `x-request-id` propagation.
