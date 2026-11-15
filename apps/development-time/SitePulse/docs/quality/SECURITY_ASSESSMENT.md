# SitePulse Security Assessment and Remediation Plan

**Date:** 2026-11-15 · **Revision assessed:** `7349075` (master) · **Method:** manual source review, a dependency audit against OSV, and the new static gate `security-lint`.

**Scope:** Rust backend (`backend/`), Flutter client (`flutter/`), Python tooling (`scripts/`, `harness/`, `e2e/`), Docker files, GitHub workflows, and the files tracked in the repository.

**Not covered:** a running deployment (no penetration test, no TLS or proxy configuration review), the git history beyond file names, and the Kuveyt Türk integration against the live bank. SQL injection was assessed in an earlier session; its result is summarised in section 4.

## 1. Summary

The backend is in good shape for its core controls: authentication, authorization, tenant isolation, password storage, webhook signatures and SQL handling all hold up (section 5). The problems are around it: a leaked credential, outdated dependencies, and several defaults that are safe only when the deployment is configured correctly.

| ID | Severity | Finding | Status |
|---|---|---|---|
| S1 | **Critical** | Kuveyt Türk API client secret committed to a public repository | File removed in this change; **rotation is still required** |
| S2 | High | 12 known advisories in pinned Rust dependencies | Open |
| S3 | Medium | The backend runs in development mode unless `APP_ENV` says production | Open |
| S4 | Medium | Login throttling has no per-client limit and can lock out other users | Open |
| S5 | Medium | Site invitation tokens have about 31 bits of entropy | Open |
| S6 | Medium | Handlers return internal error text to clients (36 places) | Open, ratcheted by CI |
| S7 | Medium | No HTTP security headers; API documentation is public in production | Open |
| S8 | Medium | CI actions are pinned to mutable tags; no automated dependency updates | Open |
| S9 | Low | Workflows ran with the default token permissions | Fixed in this change |
| S10 | Low | No request timeout or connection limit in the server | Open |
| S11 | Low | Audit log records the proxy address, not the client address | Open |
| S12 | Low | Bank webhook accepts replays of old signed bodies after the idempotency record is gone | Open |
| S13 | Low | Lawyer evidence pack token travels in the URL query string | Open |
| S14 | Low | `adminer:latest` and tag-only base images | Open, baselined |
| S15 | Low | Password policy checks length only | Open |
| S16 | Low | Flutter client shows a locally invented temporary password when the server sends none | Open |
| S17 | Low | Migration helper functions execute their arguments as SQL and are callable by `PUBLIC` | Open |

Severity reflects the impact on a production deployment that handles residents' personal and payment data.

## 2. Findings and how to fix them

### S1. Bank API client secret committed to a public repository (Critical)

`backend/.env.bak-20261107134407` was tracked by git since commit `359971d`. It holds `KT_CLIENT_ID` and a 73-character `KT_CLIENT_SECRET` for the Kuveyt Türk "prep" (sandbox) identity server, plus the key file paths. The repository `gurkanindibay/ai-powered-engineering` is public, so the secret must be treated as disclosed. The `.gitignore` rules (`.env`, `*.env`) did not match a name that ends in `.bak-<timestamp>`. The key files themselves (`keys/*.asc`) are not tracked.

Fix steps:

1. **Rotate the credential** in the Kuveyt Türk API portal: revoke the current client secret and issue a new one. Removing the file does not undo the disclosure. Do this even though it is a sandbox credential: it identifies the registered application and may be reused when the application is promoted.
2. Check the portal's access log for use of the client id that you do not recognise.
3. The file is removed from the tree in this change, and `.gitignore` now covers `.env.*` (except `.env.example`). Keep the new secret only in the untracked `backend/.env`.
4. Decide whether to purge the secret from history (`git filter-repo --path apps/development-time/SitePulse/backend/.env.bak-20261107134407 --invert-paths`, then a force push and fresh clones for everyone). After rotation this is optional; forks and caches may already hold the old value.
5. Enable **Secret scanning** and **Push protection** in the repository settings (free for public repositories). They also cover the git history, which `security-lint` does not.

CI check: `security-lint` rules `tracked-secret-file` and `hardcoded-secret`.

### S2. Known advisories in pinned dependencies (High)

`scripts/dependency_audit.py` reports 12 advisories for `backend/Cargo.lock`. `flutter/pubspec.lock` has none.

| Package | Advisory | Severity | Fixed in | Relevance |
|---|---|---|---|---|
| `lopdf` 0.31.0 | GHSA-6fj4-rcr3-r7rr | High | 0.42.0 | Stack overflow when *parsing* nested PDFs. Pulled in by `printpdf` 0.7, which SitePulse uses only to *write* receipts, so the vulnerable path is not reachable today. |
| `jsonwebtoken` 9.3.1 | GHSA-h395-gr6q-cpjc | Moderate | 10.3.0 | Type confusion that can skip claim validation. `verify_token` requires `exp`, `iss`, `aud`, `sub` and deserializes into typed claims, which limits the exposure, but access tokens and Google ID tokens both pass through this crate. |
| `rustls` 0.23.45 | GHSA-c8m5-c952-6cm4, GHSA-h2v8-394m-p7vv, GHSA-vp88-798v-h67f, GHSA-w44r-93j7-qv28 | Moderate / Low | 0.23.46 | TLS client for PostgreSQL, Google and the bank. |
| `rustls-webpki` 0.103.15 | RUSTSEC-2026-0382 | n/a | 0.103.16 | May accept distrusted intermediates. |
| `webpki-root-certs` 1.0.9 | RUSTSEC-2026-0383 | n/a | 1.0.10 | Trusts distrusted emSign intermediates. |
| `ctutils` 0.4.3 | RUSTSEC-2026-0385 | n/a | 0.4.4 | Non-constant-time comparison helper. |
| `tokio` 1.53.1 | RUSTSEC-2026-0386 | Unsound | 1.53.3 | `AsyncFd` constructors; not used directly. |
| `proc-macro-error` 1.0.4 | RUSTSEC-2024-0370 | Unmaintained | none | Build-time only, through `printpdf` (`allsorts`). |
| `ttf-parser` 0.19.2 | RUSTSEC-2026-0192 | Unmaintained | none | Through `printpdf`. |

Fix steps:

1. Patch-level updates, no code change expected: `cargo update -p rustls -p rustls-webpki -p webpki-root-certs -p ctutils -p tokio`, then the full gate run (`run_tests.py`). This clears 8 of the 12.
2. Upgrade `jsonwebtoken` to 10.3 or later. It is a major version: check `auth.rs` (`issue_token_for_session`, `verify_token`) and `auth_service.rs` (`verify_google_id_token`, JWK handling) against the 10.x API, and keep the existing token tests green.
3. Upgrade `printpdf` to a release that depends on `lopdf` 0.42 or later; verify the receipt PDF tests and the embedded DejaVu font subset. Check with the audit whether the upgrade also drops `ttf-parser` and `proc-macro-error`, which come in through the same crate.
4. For anything deliberately left open, add an entry with a reason and an expiry date to `scripts/dependency_audit_allowlist.json`.

CI check: workflow `Security audit` (`dependency_audit.py`), on lock file changes and weekly.

### S3. Development mode is the default (Medium)

`AppStateInner::is_production()` returns true only when `APP_ENV` or `ENVIRONMENT` is `production`, `prod` or `live`. Any other value, a typo, or a missing variable selects development behaviour:

- the sandbox payment provider is enabled, and `POST /api/v1/payment-provider/sandbox/checkout/:reference/complete` is public: anyone who knows a payment reference can mark the intent captured without paying;
- a missing `SITEPULSE_JWT_SECRET` is replaced by a random one instead of stopping the process, and a missing webhook secret is tolerated;
- CORS accepts any `http://localhost:*` origin;
- startup runs `init_db`, re-hashes legacy plaintext passwords and creates the bootstrap administrator instead of only verifying the schema; `DB_SSLMODE=disable` is accepted;
- `SITEPULSE_ENABLE_DEV_ROUTES=true` exposes the `/api/v1/system/*` routes that wipe and reseed data, and `SITEPULSE_SEED_TEST_DATA=true` creates fixture accounts with known passwords (`mehmet123`, `ahmet123`).

Fix steps:

1. Make the mode explicit and fail closed: accept only `APP_ENV=development` or `APP_ENV=production`, and refuse to start on anything else (in `auth::validate_configuration`).
2. Treat production as the default inside `is_production()` so that every guard is restrictive unless development was requested.
3. Set `APP_ENV=production` in the runtime image (`ENV APP_ENV=production` in `backend/Dockerfile`); the compose file for local work overrides it through `.env`.
4. Add a startup test for each case (unset, unknown value, development, production).

CI check: `security-lint` rule `dev-route-guard` keeps the `/api/v1/system/*` routes behind the `Development` policy and the production check in `dev_routes_enabled()`.

### S4. Login throttling (Medium)

`auth::require_auth` limits the public auth and registration routes to 10 requests per minute per account key and 300 per minute in total, in process memory.

- There is no per-client limit. An attacker who varies the `email` field is bounded only by the global limit.
- The global limit is shared by all users: 300 requests per minute from one client block login, token refresh and registration for everyone.
- Ten requests with a victim's email block that account for a minute, repeatable indefinitely.
- The counters are per process, so they reset on restart and multiply with replicas.
- The other public routes (`/public/receipts/verify`, `/public/collection-cases/pack`, both webhooks) are not limited.

Fix steps:

1. Add a per-client-address limit as the first tier (needs the real client address, see S11), and keep the per-account limit as the second.
2. Replace the hard global cap with per-address limits plus a much higher global circuit breaker.
3. Count failed logins per account in PostgreSQL (a small table or `users.failed_login_count` with a timestamp) with exponential back-off, so the limit survives restarts and holds across replicas.
4. Apply the per-address limit to every `Public` route.
5. Add tests: distinct emails from one address are limited; a locked account does not affect another account.

### S5. Site invitation token entropy (Medium)

`RegistrationApprovalService::generate_registration_link` builds `SP-INV-` plus 6 alphanumeric characters converted to upper case: 36^6, about 2.2 billion values (31 bits), valid for 7 days. The unit invitation uses 24 characters, and activation and lawyer tokens are long random values. A site invitation leads to a pending registration that a manager must approve, which limits the impact, but the token is the only proof that the applicant was invited.

Fix steps:

1. Generate the site token like the unit token (24 or more random alphanumeric characters, case preserved).
2. Store only its SHA-256 digest (`auth::token_digest`), as the activation tokens already do, if it is persisted in clear text today.
3. Existing links expire within 7 days; no migration is needed.

### S6. Internal error text returned to clients (Medium)

36 handler statements return a 5xx status together with the underlying error text, for example `format!("Database write failed: {}", e)` in `handlers/dues.rs`, `handlers/payments.rs` and `handlers/reconciliation.rs`. PostgreSQL errors can reveal table, column and constraint names and sometimes the offending value. Per file: `reconciliation.rs` 11, `system.rs` 10 (development routes), `dues.rs` 6, `payments.rs` 5, `payments_phase2.rs` 2, `payments_phase3.rs` 2.

Fix steps:

1. Log the error with `tracing::error!(error = %e, ...)` (the request id is already in the span) and return a fixed message; `AppError::Internal` already carries the `trace_id` the client can quote.
2. Convert the handlers that return `(StatusCode, String)` to `AppError`, so the envelope and the sanitising happen in one place (`error.rs`).
3. Lower the per-file counts in `scripts/security_lint_baseline.json` as files are cleaned.

CI check: `security-lint` rule `internal-error-leak` (per-file ratchet: the count may only go down).

### S7. Security headers and public API documentation (Medium)

No response carries `Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` or `Content-Security-Policy`. The backend serves HTML itself (`/swagger-ui`, `/docs`, `/scalar`, the sandbox checkout page), and the Swagger page loads scripts from `cdn.jsdelivr.net` without Subresource Integrity. The OpenAPI document and both documentation UIs are `Public` in production and describe every route, including the administrative ones. `flutter/web/index.html` has no CSP either.

Fix steps:

1. Add a `tower_http::set_header` layer in `app::build_router` for `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, and in production `Strict-Transport-Security: max-age=31536000; includeSubDomains`.
2. Send a strict `Content-Security-Policy` on the HTML responses; add `integrity` and `crossorigin` attributes to the CDN scripts, or serve the assets from the binary.
3. In production, register the documentation routes only when an explicit setting enables them, or require authentication.
4. Add a CSP to the Flutter web host page, or set it at the web server that serves the bundle.

CI check: `security-lint` rule `public-route` requires every unauthenticated route to be on the reviewed list.

### S8. CI supply chain (Medium)

All actions are referenced by tag (`actions/checkout@v5`, `dtolnay/rust-toolchain@stable`, `Swatinem/rust-cache@v2`, `subosito/flutter-action@v2`). A tag can be moved to different code. There is no Dependabot or Renovate configuration, so dependency and action updates depend on someone remembering.

Fix steps:

1. Pin third-party actions to a full commit SHA with the version in a comment.
2. Add `.github/dependabot.yml` for `cargo`, `pub` and `github-actions` (weekly). It keeps SHA pins current and opens pull requests for S2-type findings.
3. Protect `master`: require the SitePulse CI checks and the security audit, and block force pushes.

### S9. Workflow token permissions (Low, fixed)

`sitepulse-ci.yml` and `engineering-harness-ci.yml` had no `permissions:` block, so `GITHUB_TOKEN` kept the repository default scope. No job pushes or calls the API. Both now declare `contents: read`.

CI check: `security-lint` rules `workflow-permissions` and `workflow-untrusted`.

### S10. No request timeout or connection limit (Low)

The server has no `TimeoutLayer` and no concurrency limit. Bodies are capped (2 MiB by axum's default and by the scope check; 16 KiB on the auth routes), and password hashing is bounded by a semaphore. A slow or stalled client can still hold a connection indefinitely.

Fix steps: add `tower_http::timeout::TimeoutLayer` (for example 30 s) and a global `ConcurrencyLimitLayer`; set timeouts and body limits at the reverse proxy as well.

### S11. Audit source address (Low)

`audit::correlate` records the TCP peer address. Behind a load balancer or reverse proxy every audit event and every future per-address limit sees the proxy.

Fix steps: add a setting for trusted proxy addresses and take the client address from `X-Forwarded-For` only when the peer is one of them. Never trust the header from an arbitrary peer.

### S12. Webhook replay window (Low)

The bank and payment provider webhooks verify an HMAC-SHA256 signature over the body in constant time. No timestamp is signed, so a captured request stays valid forever; replays are caught by the idempotency claim on the transaction id. That is sufficient while the claims are retained.

Fix steps: if the bank can sign a timestamp header, include it in the MAC and reject bodies older than a few minutes. Otherwise document that webhook idempotency records must never be purged by retention jobs.

### S13. Lawyer pack token in the URL (Low)

`/api/v1/public/collection-cases/pack?token=...` carries a bearer token in the query string. The token is strong (two UUIDv4 values, stored as a digest, time-limited), and the backend logs only the path. Proxies, browser history and `Referer` headers may still record it.

Fix steps: send `Referrer-Policy: no-referrer` and `Cache-Control: no-store` on this response (covered by S7), make sure proxy access logs drop the query string for `/api/v1/public/*`, and consider exchanging the link token for a short-lived session on first use.

### S14. Container images (Low)

`docker-compose.yml` uses `adminer:latest` (local tools profile only). The Dockerfile and compose images are pinned by tag, not by digest. The runtime image is otherwise sound: multi-stage, non-root user, no secrets, `--locked` build.

Fix steps: pin Adminer to a version, and pin the base images by digest (`image@sha256:...`) so Dependabot can update them deliberately.

CI check: `security-lint` rule `unpinned-image` (the Adminer line is in the baseline until it is fixed).

### S15. Password policy (Low)

`validate_new_password` requires 10 to 1024 characters and nothing else. Length-only is acceptable under NIST SP 800-63B, which also asks for a check against known-compromised passwords.

Fix steps: reject passwords that equal the account's email or name, and check new passwords against a breached-password list (a bundled top list, or the k-anonymity range API).

### S16. Invented temporary password in the client (Low)

`dashboard_controller_auth.dart` (lines 576 and 828) and `dashboard_controller_residents.dart` (line 1207) build a temporary password from the current timestamp. It is meant for the offline test mode, but line 598 also uses it as a fallback when the server response has no `temporary_password`. The administrator would then be shown a password that does not exist on the server.

Fix steps: generate the placeholder only when `isTestMode` is true, and show an error when a live response lacks the password.

### S17. Migration helper functions (Low)

`sp_add_constraint` and `sp_set_fk` in `backend/db/baseline_schema.sql` execute their text arguments as SQL. Only migrations call them, with fixed values. Fix: `REVOKE EXECUTE ... FROM PUBLIC` in a new migration, so the runtime role cannot call them.

## 3. Remediation order

| Step | Items | Effort | Notes |
|---|---|---|---|
| 1. Today | S1 rotation, secret scanning and push protection | minutes | Manual, in the bank portal and the repository settings |
| 2. This week | S2 patch updates; S3 fail-closed mode | hours | S2 step 1 is a lock file change plus a gate run |
| 3. Next | S2 major upgrades (`jsonwebtoken`, `printpdf`); S4; S5 | days | Behaviour changes: add scenarios and record a test run (AGENTS.md rule 13) |
| 4. Then | S6, S7, S8, S11 | days | S6 is mechanical and ratcheted |
| 5. Backlog | S10, S12 to S17 | hours each | |

## 4. SQL injection (earlier assessment)

No SQL injection risk was found. Every query passes user input as bound parameters through `tokio_postgres`. SQL text that is assembled at runtime (`person_service.rs`, `person_directory_service.rs`, `finance_records.rs`, `payment_repository.rs`, `sync.rs`, the site purge in `handlers/system.rs`, `tenant_guard.rs`) is built only from constants in the code. There is no user-controlled sort column or direction. The one hardening step is S17.

## 5. Controls verified as sound

- **Route policy.** Every route declares a policy in `app.rs`; a request that matches no declared route is rejected. Policies map to permissions per role.
- **Tokens.** HS256 with a secret of at least 32 bytes, required in production; issuer, audience, expiry and subject are enforced; access tokens live 10 minutes; refresh tokens are stored as digests and rotated; sessions can be revoked; sensitive permissions need a recent step-up.
- **Passwords.** Argon2id with per-password salts, hashing bounded by a semaphore, legacy formats never verify, temporary passwords force a change.
- **Google sign-in.** RS256 signature checked against Google's keys, with issuer, audience and `email_verified`; mock tokens need an explicit flag and are refused in production.
- **Tenant isolation.** The middleware pins `site_id` in the query and body, checks unit and resource ownership, and PostgreSQL row-level security backs it up (`tenant-lint` gate).
- **Webhooks.** Constant-time HMAC verification; a missing secret rejects every request; durable idempotency.
- **Transport to the database.** `DB_SSLMODE=require` is mandatory in production, with certificate verification.
- **CORS.** Explicit origin list; localhost only outside production; no wildcard.
- **Output handling.** The person export neutralises spreadsheet formulas; the sandbox page escapes HTML; request ids are validated before they are logged.
- **Flutter client.** Tokens are kept in memory only; release builds require an HTTPS API origin; requests are sent only to the configured origin.
- **Python tooling.** No `shell=True`, `verify=False`, unsafe YAML or pickle loading.

## 6. CI checks added with this assessment

| Check | Where it runs | What it catches |
|---|---|---|
| `security-lint` (`scripts/security_lint.py`) | Every PR, in the `lint` group of `sitepulse-ci.yml` and in `run_tests.py` | Tracked credential files, hard-coded secrets, workflows without least-privilege permissions or with untrusted input in scripts, unpinned images, new unauthenticated routes, unguarded development routes, permissive CORS, weak crypto, client-side token storage, unsafe Python calls, and growth in leaked error text |
| `dependency_audit.py` | Workflow `Security audit`: on lock file changes, every Monday, and on demand | Published advisories for the pinned crates and pub packages |

Accepted findings are listed in `scripts/security_lint_baseline.json`; accepted advisories go in `scripts/dependency_audit_allowlist.json` with a reason and an expiry date. Until S2 is resolved or allowlisted, the weekly `Security audit` run fails by design.

What the checks do not cover: secrets in git history (use GitHub secret scanning), runtime behaviour (S3, S4, S7 need tests when they are fixed), and logic flaws that only a review finds.
