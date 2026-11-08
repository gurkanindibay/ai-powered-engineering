# SitePulse Authentication, Authorization, and Audit Architecture

Reviewed and corrected: 2026-11-08 (second review pass). Status: implemented security baseline with operational guidance in §12. The review tables preserve the pre-implementation snapshot.

## Document map

| Section | Answers |
| --- | --- |
| 1. Recommendation and review findings | What to do, and what earlier drafts got wrong |
| 2. What SitePulse actually implements | Verified current state and newly found gaps |
| 3. Rust libraries and Spring Security | Whether a "Spring Security for Rust" exists and which option fits |
| 4. Authentication and credential lifecycle | Token validation, sessions, revocation, passwords, federation, data model |
| 5. Authorization | Role-permission matrix, route-policy inventory, Rust module and type structure, RLS |
| 6. Durable audit design | Transactional audit events, schema, immutability, privacy, event catalog |
| 7. Flutter and web clients | How the client consumes server-derived permissions |
| 8. Module boundaries and rollout | Phased plan with exit criteria |
| 9. Verification and acceptance criteria | Tests required before acceptance |
| 10. Threat model | Threats mapped to controls and tests |
| 11. Open decisions | Product and security choices that block implementation |
| 12. Implemented structure and operator guide | Current components, API contracts, deployment and verification |
| Appendix A. Configuration | Environment variables, current and proposed |

## 1. Recommendation and review findings

Keep SitePulse's Axum/Tower authentication stack, reuse its existing typed roles and permissions, and move resource authorization into application services backed by tenant-scoped repository operations. Persist mandatory business audit events in the same PostgreSQL transaction as each mutation. Add a durable outbox only when events must also reach another system.

The original report had material flaws:

| Finding | Risk | Correction |
| --- | --- | --- |
| An in-memory Tokio channel was the authoritative audit path | Queue saturation, process crashes, connection failures, and insert errors could lose evidence after a successful mutation | Commit the mutation and required audit event atomically; export asynchronously from durable storage |
| The example unit guard allowed every site manager without resolving the unit's site | Cross-tenant access if called without a separate site check | Resolve and constrain the actual resource, including its parent relationships, in one authorization operation |
| SaaS administrators bypassed every tenant check | Platform management privileges implicitly exposed tenant financial and personal data | Separate platform permissions from tenant data permissions; require explicit, scoped support elevation |
| A normal table was described as append-only and tamper-evident | Foreign-key deletion actions could rewrite evidence; privileged users could alter it | Preserve historical identifiers, enforce separate database privileges, and distinguish immutability from independently verifiable tamper evidence |
| New role/permission definitions duplicated existing types | Conflicting policy sources and serialization behavior | Extend `models::Permission` and its existing role mapping |
| A `RequirePermission` declaration had no extractor implementation | The advertised guard did not implement enforcement | Remove the incomplete implementation; define enforceable service contracts and route coverage requirements |
| Extractors were said to validate authorization at compile time | False assurance: a handler can omit a guard and policy checks still execute at runtime | Types enforce interfaces; runtime checks and negative integration tests establish access control |
| Library snippets and status claims were presented as ready to apply | Unverified middleware API compatibility and overstated security coverage | Distinguish verified repository facts, proposed design, and version-dependent integration work |
| No concrete role-permission matrix or route-to-permission inventory | "Apply RBAC" could not be implemented or tested route by route | Added §5.1 and §5.2 |
| No target code structure for the Rust backend | Each developer would invent different extractor, error and service contracts | Added §5.4 with module layout and type contracts |
| Session, role-assignment and support-grant storage was described but not modeled | Revocation and support elevation had no persistence design | Added §4.4 |
| Several fail-open behaviors in current code were not reported | Skipped tenant checks in database-only mode, unchecked non-JSON bodies, client-side role override | Added §2.1 |
| No threat model or decision log | Controls were not traceable to threats; blocking product decisions were implicit | Added §10 and §11 |

This report uses AAA to mean authentication, authorization, and audit. In other security contexts the final A commonly means accounting. Roles belong to authorization; authentication establishes identity.

## 2. Reviewed baseline before SPEC-008 implementation

Paths below are relative to `apps/development-time/SitePulse/`.

| Area | Evidence and current behavior | Remaining work |
| --- | --- | --- |
| Framework | `backend/Cargo.toml`: Axum 0.7, Tower HTTP 0.5, `jsonwebtoken` 9, `argon2` 0.5, deadpool/tokio-postgres | Check any new crate against this dependency graph; latest examples may target Axum 0.8 |
| Credentials | `backend/src/auth.rs`: salted Argon2 password hashes; HS256 access tokens valid for 12 hours; 30-second JWT leeway | Shorter access lifetime, explicit issuer/audience, revocation, bounded password hashing work, key lifecycle |
| JWT identity | `Claims` contains subject, email, role, one site, optional unit, issue time and expiry | Claims do not contain session ID, token ID, authorization version, issuer or audience |
| Google sign-in | `backend/src/services/auth_service.rs`: RS256 verification against Google JWKS, audience/issuer/expiry checks and verified email; mocks gated outside production | Review account linking, JWKS refresh on unknown key, timeouts and retry bounds; identity federation is separate from app authorization |
| Roles and permissions | `backend/src/models/mod.rs`: four roles and ten permissions, with `Permission::permissions_for_role` | `AuditLogRead` is proposed, not present; current route checks use broad role categories rather than this granular mapping |
| HTTP protection | `backend/src/app.rs`: `require_auth` attached to the router; CORS wraps it | Maintain an explicit method-and-route policy inventory and test effective layer order |
| Tenant checks | `backend/src/auth.rs`: selected path checks, query site pinning, recursive JSON field inspection; the existing manager unit check resolves the unit's site | These are useful defenses, not proof that every receipt, registration, project or nested resource is scoped correctly |
| Resource guard example | `backend/src/handlers/mod.rs`: registration approval/rejection use optional claim extensions and an in-memory lookup for the site check | Require authenticated context and enforce scope in the service/repository for every caller and storage mode |
| Session termination | No refresh/session-version/revocation mechanism found in reviewed backend routes and auth implementation; Flutter logout clears the in-memory API token | A copied JWT remains usable until expiry unless server-side invalidation is added |
| Client storage | `flutter/lib/domain/services/api_client.dart` keeps the access token in a static in-memory field | Do not claim it is currently stored in localStorage; choose platform-specific storage deliberately |
| Audit | No dedicated audit table, audit event service or outbox found in reviewed backend source/migrations | Design and implement the audit subsystem |
| Migrations | `backend/src/migrations.rs` explicitly registers V1–V17 and verifies checksums | A future V18 must also be registered; never edit an applied migration |

Site activity is checked during password sign-in, but the reviewed request middleware does not reload current account/site/membership state. Suspension, role changes and occupancy changes therefore need an explicit token invalidation or current-state authorization strategy. `Role::from_str_loose` also defaults unknown strings to `HomeOwner`; security-facing parsing should reject unknown roles.

The Graphify query could not run because `graphify-out/graph.json` is absent in this checkout. Findings above come from direct source inspection, not a full penetration test or exhaustive endpoint audit.

### 2.1 Additional gaps found in the second review

Each item was checked against source. Severity reflects impact if the gap is reachable; none has been exploited or confirmed by a penetration test.

| # | Location | Current behavior | Risk | Required change |
| --- | --- | --- | --- | --- |
| G1 | `backend/src/handlers/mod.rs` `approve_registration` / `reject_registration` | The site check runs only when the registration is found in the in-memory list; on a miss it falls through to the service | High: in PostgreSQL-backed operation a manager may approve or reject another site's application | Load the registration from the repository with `site_id = authorized_site`; fail closed with a scoped 404 |
| G2 | Same handlers | Claims are taken as `Option<Extension<Claims>>` | Medium: a routing or layer-order change silently removes enforcement | Require the principal; absence is a 500 configuration error, never "allowed" |
| G3 | `backend/src/auth.rs` `require_auth` | Bodies that fail JSON parsing pass through without scope inspection; SaaS administrator bodies are never inspected | Low today, latent: every current protected body endpoint uses `Json`, which rejects non-JSON input, but a future multipart/CSV upload would bypass tenant pinning | Treat body pinning as defense in depth only; enforce scope in services; reject unexpected content types per route |
| G4 | `backend/src/auth.rs` `route_access` | Policy is derived from raw path string prefixes, separate from the router; unknown paths default to `SiteStaff` | Medium: drift between router and policy; a new resident route under an unlisted prefix is accidentally staff-only, or a new staff route under `/api/v1/units/` is open to residents | Key policy by Axum `MatchedPath` route template plus method, with a startup/test check that every registered route has exactly one policy entry |
| G5 | `backend/src/auth.rs` `same_id` | Strips `site-`, `d-` and `unit-` prefixes before numeric comparison | Low–medium: IDs of different entity kinds can compare equal (`unit-5` vs `site-5`); ambiguity invites mistakes | Parse into typed IDs (`SiteId`, `UnitId`) at the boundary; compare only same-kind values |
| G6 | `backend/src/auth.rs` `verify_token` / `require_auth` | 401 responses include the `jsonwebtoken` error text | Low: aids token-forgery probing | Return a generic message; log the cause without the token |
| G7 | `backend/src/auth.rs` `jwt_secret`, `issue_token`, `hash_password` | `panic!` / `.expect()` on configuration and crypto paths | Standards violation (workspace-root `docs/RUST_STANDARDS.md`: zero panics); a mid-request panic aborts the request instead of a controlled error | Validate configuration once at startup returning `Result`; return typed errors from token and hash functions |
| G8 | `backend/src/models/mod.rs` | `Permission::permissions_for_role` grants `SaasAdmin` `SiteManage`; route checks use `is_site_staff()` which includes `SaasAdmin` | High (policy): platform administrators hold tenant management rights everywhere | Remove tenant permissions from the platform role; add time-boxed support grants (§4.4) |
| G9 | `backend/src/models/mod.rs` | `Permission` is not `Copy`/`Hash`; no `has_permission` helper; the permission list in `AuthResponse` is informational only | Medium: granular permissions exist but nothing enforces them | Add an authorizer that evaluates permissions (§5.4) and use it from every protected service |
| G10 | `flutter/lib/ui/dashboard/dashboard_controller.dart` | Role is derived by substring matching (`contains('ADMIN')`), unknown roles default to home owner, and a UI-selected `targetRole` overrides the server role | Medium: UI shows functions the server will refuse, or hides functions the user holds; misleading for testing | Use the server `role` and `permissions` exactly; reject unknown values; remove the override outside demo builds |
| G11 | `backend/src/handlers/mod.rs` `reverse_payment` | Actor is recorded as a free-form string `user:<sub> <email>` | Low: unstructured audit attribution, email captured as identity | Pass a typed principal; record `actor_id`, `actor_kind` and session reference (§6.2) |
| G12 | `backend/src/app.rs` | No request-ID or trace layer; no explicit body-limit layer beyond the 2 MiB inspection cap | Low: audit events cannot be correlated with requests | Add a request-ID layer (generate when absent, propagate in responses) before audit work begins |

Positive controls confirmed: `/api/v1/system/*` destructive routes are only merged when not in production and `SITEPULSE_ENABLE_DEV_ROUTES=true` (`backend/src/app.rs`); `change_password` binds the request email to the authenticated claims; webhook signatures use constant-time HMAC comparison; one-time tokens are stored as SHA-256 digests.

## 3. Rust libraries and Spring Security

Spring Security's Servlet integration uses a filter chain; method security can use proxies. Describing all Spring security as reflection or bytecode weaving is inaccurate. Rust middleware offers a different composition model, not an automatic security or performance advantage. See the [Spring Security architecture reference](https://docs.spring.io/spring-security/reference/servlet/architecture.html).

For this app, the practical choices are:

- **Existing JWT stack plus Axum extractors:** the smallest change for SitePulse. Authenticate once, attach a verified principal, and use a required extractor to obtain it. Authorization still needs current state and resource checks. Axum 0.7 custom extractor syntax differs from 0.8, which removed the `async_trait` requirement; follow the [Axum migration guidance](https://tokio.rs/blog/2025-01-01-announcing-axum-0-8-0).
- **`axum-login` with `tower-sessions`:** a session-based alternative offering authentication backends and permission checks. The application implements credential verification and user loading; the crate does not supply a complete password security policy. Select a compatible version and durable session store before adoption. See [`axum-login` documentation](https://docs.rs/axum-login/latest/axum_login/).
- **`casbin` (`casbin-rs`):** an authorization engine for policies that need dynamic configuration. It does not authenticate users, discover resource ownership, or create durable business audit records. Evaluate its adapter, policy synchronization and cache invalidation needs before adoption. See the [`casbin` API](https://docs.rs/casbin/latest/casbin/).

Actix and Poem permission macros belong to those frameworks and are not drop-in Axum middleware. The original `CasbinAxumLayer` and generic `has_permissions` snippets were not established as compatible with this repository and have been removed. Do not add a dependency based on those snippets.

**Decision:** use typed permissions and application-service authorization first. Consider Casbin when tenant-customizable policies become a real requirement. Consider session auth when choosing the browser credential model; it is an alternative architecture, not a prerequisite for RBAC.

## 4. Authentication and credential lifecycle

### 4.1 Validate identity once per request

The authentication boundary must parse the authorization header strictly, reject missing/empty/ambiguous credentials, allow only configured signing algorithms, validate signature and expiry, and validate the expected issuer and API audience. Authentication scheme matching is case-insensitive. Never accept a raw token as a fallback for an invalid Bearer scheme.

Return a generic 401 with an appropriate `WWW-Authenticate: Bearer` challenge. Keep cryptographic error details in protected diagnostics, excluding the token itself. Authenticated callers lacking permission receive 403, or a consistent scoped 404 where hiding resource existence is appropriate. Dependency outages must not be disguised as an authorized request or an ordinary missing record.

| Condition | Status | Client-visible body | Audit/security event |
| --- | --- | --- | --- |
| Missing, malformed or ambiguous `Authorization` header | 401 + `WWW-Authenticate: Bearer` | Generic "authentication required" | Security event, aggregated |
| Invalid signature, algorithm, issuer, audience or expiry | 401 + `WWW-Authenticate: Bearer error="invalid_token"` | Generic | Security event, aggregated |
| Revoked session, disabled user or suspended site | 401 | Generic; client re-authenticates | Security event |
| `must_change_password` set and route is not the change-password route | 403 with a stable machine code | "Password change required" | None |
| Authenticated but permission missing | 403 | Generic denial with stable code | `DENIED` event |
| Resource outside the caller's scope | 404 (scoped) or 403, chosen per resource and applied consistently | Indistinguishable from a missing resource when 404 | `DENIED` event |
| Business-state conflict (already approved, reversed) | 409 | Domain message | `FAILURE` event if the action is audited |
| Authorization dependency unavailable (database, membership lookup) | 503 | Generic | Operational alert; never treated as allowed |
| Required audit write fails | 500/503 and the mutation is rolled back | Generic | Operational alert |

For `jsonwebtoken` 9, explicitly configure issuer, audience, required supported claims and time validation. Validate application-specific claims such as session ID and authorization version separately: listing arbitrary names in `set_required_spec_claims` does not enforce them. See the [versioned validation API](https://docs.rs/jsonwebtoken/9.3.1/jsonwebtoken/struct.Validation.html).

Use a stable user identifier as `sub`. Treat email and token claims as sensitive metadata, not proof of current site/unit membership. Reject inactive users, suspended sites and revoked sessions before granting protected access. Bound any authorization cache lifetime and invalidate it on security changes; require fresh state for role grants, tenant suspension and financial mutations.

### 4.2 Access tokens, renewal and revocation

Proposed defaults are a 5–15 minute access token and a separately managed renewal credential, subject to product requirements. If persistent login is needed:

1. Store a server-side session with user, tenant context, expiry, revocation state and authorization version.
2. Generate high-entropy refresh tokens, store only their digests, and rotate them atomically on use.
3. Detect refresh-token reuse and revoke the affected session family. Define behavior for concurrent refresh requests and client retries.
4. Revoke sessions on logout, password reset, account disablement and security-sensitive role/membership changes. Check revocation/version during access authorization if immediate invalidation is required; refresh revocation alone leaves existing access tokens valid until expiry.
5. Provide current-session and all-sessions logout semantics. Audit both; update Flutter to call the backend before clearing local state, with defined offline logout behavior.

HS256 can remain appropriate for a single issuer/verifier service if the secret is strong and protected. Use asymmetric signing when independently deployed services must verify without minting tokens. Define key rotation, bounded overlap, emergency invalidation, and a trusted key-ID mapping. Never fetch keys from arbitrary token-supplied URLs.

### 4.3 Passwords, federation and public endpoints

Run costly Argon2 operations on bounded blocking workers, with tuned memory/time parameters and request-size limits. Add login and reset rate limits by account and source, generic credential errors, MFA or step-up authentication for privileged operations, and server enforcement of `must_change_password`. Provision bootstrap credentials through a secret channel rather than ordinary logs.

Password reset and invitations need random, hashed, expiring, single-use tokens consumed atomically with the resulting account change. Invite scope and role come from server records. Never let a registration body grant its own role or tenant. Review email verification and email-change flows separately.

Google identity should be bound by issuer and subject. Linking an existing account should require explicit proof of control under an account-linking policy rather than email matching alone. Authorization Code with PKCE, state and nonce are relevant when implementing a redirect-based OIDC flow; do not mistake an ID token for a SitePulse API access token.

Maintain a narrow method-specific public allowlist. Public registration and login still require validation, rate limits and security events. A webhook is exempt from user JWT auth but authenticated by its own mechanism: verify the raw-body signature, enforce replay controls supported by the provider, and deduplicate provider events durably. A valid HMAC alone does not prevent replay.

### 4.4 Identity, session and role-assignment data model

Illustrative SQL for a future migration (not applied). It replaces the single `users.role` / `users.site_id` pair as the source of authority over time; keep the existing columns readable during migration and stop writing them only after every reader has moved.

```sql
-- One row per signed-in device/session. Access tokens carry session_id and auth_version.
CREATE TABLE auth_sessions (
    session_id UUID PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    active_site_id BIGINT,                 -- context selected at sign-in, validated server side
    auth_version INTEGER NOT NULL,         -- copied from users.auth_version at issue time
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    revoked_reason TEXT,
    user_agent TEXT,
    source_ip INET
);

-- Refresh tokens are stored only as digests and rotated on every use.
CREATE TABLE auth_refresh_tokens (
    token_digest TEXT PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES auth_sessions (session_id) ON DELETE CASCADE,
    family_id UUID NOT NULL,               -- reuse of a consumed token revokes the family
    issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    replaced_by TEXT
);

-- Bumped on password change, disablement, role or membership change: invalidates tokens.
ALTER TABLE users ADD COLUMN auth_version INTEGER NOT NULL DEFAULT 1;

-- Tenant-scoped role grants with effective dates (replaces users.role + users.site_id).
CREATE TABLE site_role_assignments (
    assignment_id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (id),
    site_id BIGINT NOT NULL REFERENCES sites (id),
    role VARCHAR(30) NOT NULL
        CHECK (role IN ('SITE_MANAGER', 'HOME_OWNER', 'HOME_RESIDENT')),
    unit_id BIGINT REFERENCES units (id),
    valid_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_to TIMESTAMPTZ,
    granted_by BIGINT REFERENCES users (id),
    CHECK (role = 'SITE_MANAGER' OR unit_id IS NOT NULL),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

-- Platform roles are separate from tenant roles.
CREATE TABLE platform_role_assignments (
    user_id BIGINT PRIMARY KEY REFERENCES users (id),
    role VARCHAR(30) NOT NULL CHECK (role IN ('SAAS_ADMIN')),
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    granted_by BIGINT REFERENCES users (id)
);

-- Time-boxed, reasoned, audited access by a platform operator to one tenant's data.
CREATE TABLE support_grants (
    grant_id UUID PRIMARY KEY,
    operator_user_id BIGINT NOT NULL REFERENCES users (id),
    site_id BIGINT NOT NULL REFERENCES sites (id),
    allowed_permissions TEXT[] NOT NULL,
    reason TEXT NOT NULL,
    ticket_reference TEXT,
    approved_by BIGINT REFERENCES users (id),
    starts_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    CHECK (expires_at > starts_at),
    CHECK (approved_by IS NULL OR approved_by <> operator_user_id)
);
```

Verify the key types against the deployed schema before writing the migration (`users.id`, `sites.id`, `units.id`). Use the next free migration version and register it in `backend/src/migrations.rs`. Index active rows (`WHERE revoked_at IS NULL`, `WHERE valid_to IS NULL`) for the per-request lookup, and bound session lookup cost with a short-lived cache keyed by `session_id` that is invalidated on revocation.

Proposed access-token claims: `sub` (stable user ID), `sid` (session ID), `ver` (auth version), `site` (active site context), `iss`, `aud`, `iat`, `exp`, `jti`. Do not put permissions, unit lists or email in the token; resolve them from the session and current assignments, so a change takes effect at the next request.

## 5. Authorization: permission, scope, relationship and state

The decision is:

`active identity AND permitted action AND authorized tenant AND authorized resource relationship AND valid business state`

Use explicit permissions rather than ordering roles as if every higher role inherits every lower role. Preserve the current `Role` and `Permission` enums and extend their existing mapping. Reject unknown values. Do not duplicate policy in Flutter, JWT generation, middleware and handlers.

Proposed additions are listed in the §5.1 matrix. Define their serialization and assignment explicitly; these permissions are not implemented by this report. For financial reversals and privileged role grants, consider separate approval and step-up requirements.

Role scope must be explicit:

- **Home owner/resident:** allow configured unit actions only for current authorized relationships. Ownership and occupancy may have different historical receipt, household-management and personal-data rights. The current identical permission lists need product validation.
- **Site manager:** allow configured management actions only in assigned active sites. Resolve the target unit, registration, receipt or project and verify its site. Manager status never bypasses this lookup.
- **SaaS administrator:** allow platform site/subscription management. Access to tenant content needs a separate, time-limited support grant with tenant, reason, allowed actions and audit evidence. Implement this as a deliberate behavior change from current broad bypasses.
- **Worker or webhook identity:** grant only named machine actions. Do not impersonate a human administrator.

A future multi-site/multi-unit model should represent user-site role assignments and unit relationships with effective dates. The current single-site/single-unit claims cannot represent every ownership arrangement. Load authoritative membership and issue tokens for an explicitly selected context; never trust a client-selected site on its own.

### 5.1 Role-permission matrix

`C` = current mapping in `Permission::permissions_for_role`; `P` = proposed; `—` = not granted; `G` = only through an active support grant. Scope column states what each grant is bounded by.

| Permission | Scope | Home owner | Home resident | Site manager | SaaS admin |
| --- | --- | --- | --- | --- | --- |
| `UnitRead` | Own current unit(s) | C | C | P (site units) | G |
| `UnitPay` | Own current unit(s) | C | C (product decision, §11) | — | — |
| `UnitInviteCoResident` | Own unit | C | C → P: owner only (§11) | — | — |
| `UnitManageHousehold` | Own unit | C | C → P: owner only (§11) | — | — |
| `SiteManage` | Assigned site | — | — | C | C → **remove**; G |
| `ResidentInviteSite` | Assigned site | — | — | C | G |
| `ResidentApprove` | Assigned site | — | — | C | G |
| `LedgerManageAll` | Assigned site | — | — | C | G |
| `AnnouncementBroadcast` | Assigned site | — | — | C | C → P: platform notices only |
| `TenantManage` | Platform | — | — | — | C |
| `PaymentRecordManual` (new) | Assigned site | — | — | P | G |
| `PaymentReverse` (new) | Assigned site; step-up | — | — | P | — |
| `BankAccountManage` (new) | Assigned site; step-up | — | — | P | G |
| `ReconciliationConfirm` (new) | Assigned site | — | — | P | G |
| `RoleGrant` (new) | Assigned site; cannot grant `SITE_MANAGER` to self | — | — | P | P (platform roles) |
| `AuditLogRead` (new) | Assigned site / platform events | — | — | P | P (platform events); G (tenant events) |
| `AuditLogExport` (new) | As read; separately audited | — | — | P | G |
| `SupportAccess` (new) | Platform; creates support grants | — | — | — | P (requires second approver) |
| `PlatformIntegrationConfigure` (new) | Platform (bank integration settings) | — | — | — | P |

`LedgerManageAll` currently covers dues, penalties, manual payments, reversals and reconciliation. Splitting it, as above, allows step-up authentication and separate approval for reversals without blocking routine dues work. If the split is rejected, record the decision in §11 and keep `LedgerManageAll` with step-up applied to reversals by action.

The matrix lives in one place: `Permission::permissions_for_role` (or its successor in `authorization::policy`). A unit test asserts the matrix table above row by row so the document and code cannot drift silently.

### 5.2 Route-policy inventory

Current access is the `route_access` result in `backend/src/auth.rs`. Proposed policy names the permission and the scope resolver the service must apply. Families are grouped; the implementation inventory must list every method and route template individually.

| Route family (method) | Current access | Proposed permission | Scope resolver |
| --- | --- | --- | --- |
| `/health`, `/api/v1/health` (GET) | Public | none | none |
| `/api/v1/auth/login`, `/google`, `/register` (POST) | Public | none; rate limited | none |
| `/api/v1/auth/me` (GET), `/change-password` (POST) | Authenticated | self | `principal.user_id` |
| `/api/v1/registration/submit/:slug` (POST) | Public | none; rate limited | slug → site, server side |
| `/api/v1/home-residents/register` (POST) | Public | none; invite token required | token → unit, server side |
| `/api/v1/bank/webhook/incoming-transfer` (POST) | Public (HMAC) | machine: `BankWebhook` | signed payload → virtual IBAN → unit → site |
| `/api/v1/site-admin/banks` (GET) | Public | none (static catalog) | none |
| `/api/v1/residents/:unit_id/*`, `/api/v1/units/:id/virtual-iban` (GET) | Authenticated + unit check (all methods) | `UnitRead` | unit → site; caller relationship to unit |
| `/api/v1/residents/:unit_id/matching-criteria/*` (POST/DELETE) | Authenticated + unit check | `UnitPay` or owner-only `UnitManageHousehold` (§11) | unit → site; caller relationship to unit |
| `/api/v1/payments/receipts/:id` (GET) | Authenticated | `UnitRead` or `LedgerManageAll` | receipt → unit → site (not covered by `path_unit_id` today) |
| `/api/v1/home-residents/invite-link/:unit_id`, `/members/:unit_id` | Authenticated + unit check | `UnitInviteCoResident` / `UnitManageHousehold` (or site-scoped `SiteManage` for household administration) | unit → site; owner relationship, or assigned site administration |
| `/api/v1/capital-projects*` (GET) | Authenticated | `UnitRead` (residents) or `SiteManage` | project → site |
| `/api/v1/capital-projects*` (POST/PUT/DELETE) | SiteStaff | `SiteManage` | project → site |
| `/api/v1/registration/invite-link`, `/pending` (GET) | SiteStaff | `ResidentInviteSite` / `ResidentApprove` | active site |
| `/api/v1/registration/approve/:id`, `/reject/:id` (POST) | SiteStaff + fail-open lookup (G1) | `ResidentApprove` | registration → site, in repository query |
| `/api/v1/payments/record`, `/record-manual`, `/match-all` (POST) | SiteStaff | `PaymentRecordManual` | body unit/site → site |
| `/api/v1/payments/reverse` (POST) | SiteStaff + handler check | `PaymentReverse` + step-up | payment → site |
| `/api/v1/payments/inter-ledger-transfer` (POST) | SiteStaff | `LedgerManageAll` | both ledgers → same site |
| `/api/v1/payments/stream`, `/debt-aging*`, `/homeowner-records` | SiteStaff | `LedgerManageAll` | active site |
| `/api/v1/dues/periods`, `/dues/accrue-period`, `/capital-projects/:id/accrue-installment` | SiteStaff | `LedgerManageAll` | period/project → site |
| `/api/v1/bank/remembered-ibans` | SiteStaff | `ReconciliationConfirm` | active site |
| `/api/v1/bank/statements/*` | SiteStaff | `ReconciliationConfirm` | statement/match → site |
| `/api/v1/site-admin/bank-account/:site_id*` | SiteStaff + site check | `BankAccountManage` + step-up | path site = active site |
| `/api/v1/site-admin/units/:id/transfer-ownership` (POST) | SiteStaff + unit check | `SiteManage` + step-up | unit → site |
| `/api/v1/site-admin/*` (other) | SiteStaff | `SiteManage` | active site |
| `/api/v1/bank/kuveyt-turk/configure` (POST) | SaasAdmin | `PlatformIntegrationConfigure` | platform |
| `/api/v1/bank/kuveyt-turk/status`, `/test-connection` | SiteStaff | `BankAccountManage` | active site, or platform (§11) |
| `/api/v1/saas/*` | SaasAdmin | `TenantManage` | platform |
| `/api/v1/saas/sites/:id/reset-admin-password` (POST) | SaasAdmin | `TenantManage` + step-up; audited; revokes target sessions | platform |
| `/api/v1/system/*` (dev only) | SaasAdmin; not routed in production | dev-only `SystemReset`; never in production builds | none |
| Any unlisted route | SiteStaff (default) | **deny** until listed | — |

### 5.3 Place enforcement at application-service boundaries

Keep a default-deny route policy and a required authenticated-principal extractor. Have protected services require an authorization context, so jobs and alternate transports follow the same rules. A service should load a resource through a tenant-scoped repository, authorize the action and current relationship, then mutate it under transaction/locking or optimistic version checks.

The following is an implementation contract, **not compilable Rust or an existing API**:

```text
approve_registration(principal, registration_id, request_context):
    load current account, session, site membership and permission state
    require ResidentApprove in the authorized site context
    begin database transaction
    load registration WHERE id = registration_id AND site_id = authorized_site
        with an appropriate lock or expected-version check
    require registration is pending and target site remains active
    perform approval and related membership changes
    insert redacted audit event using the same transaction
    commit
    update or invalidate in-memory projections after commit
    return committed result
```

Bind parameters in SQL. Scope reads, updates and deletes with both the resource ID and authorized tenant. Resolve indirect IDs through joins, including receipt-to-unit-to-site and project-to-site. Verify that nested IDs belong to the declared parent; check every item in bulk operations. Query/body pinning is supplementary and cannot establish these relationships.

List, search, count, export and download endpoints need the same scope. Verify pagination and error behavior do not disclose another tenant's records. Avoid raw user-supplied field names for policy or SQL construction.

Where authorization must remain valid until commit, serialize relevant membership/state changes or use an appropriate isolation/version strategy. A permission check before a transaction does not alone eliminate time-of-check/time-of-use races.

These principles follow [OWASP authorization guidance](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html); SitePulse-specific scope and permission choices above are proposed policy.

### 5.4 Target Rust code structure

Proposed layout inside `backend/src/`. It extends the existing crate; nothing here requires a new framework.

```text
backend/src/
├── auth/                      # authentication only (split from today's auth.rs)
│   ├── mod.rs                 # re-exports; no policy decisions
│   ├── token.rs               # issue/verify access tokens; typed AuthError, no panics
│   ├── password.rs            # Argon2 hashing on spawn_blocking; parameters from config
│   ├── session.rs             # session lookup, refresh rotation, revocation
│   ├── middleware.rs          # authenticate request → insert Principal; no route policy
│   └── extract.rs             # FromRequestParts for Principal (required, never Option)
├── authorization/
│   ├── mod.rs
│   ├── permission.rs          # Permission enum (moved from models) + serde + Display
│   ├── policy.rs              # role → permission matrix (§5.1), single source of truth
│   ├── route_policy.rs        # (Method, MatchedPath) → RoutePolicy table (§5.2)
│   ├── context.rs             # AuthzContext: principal + active site + grants + request id
│   ├── authorizer.rs          # require(permission, scope) → Result<Authorized<T>, AuthzError>
│   └── scope.rs               # SiteId/UnitId newtypes and resource-to-site resolvers
├── audit/
│   ├── event.rs               # AuditEvent builder with allowlisted fields
│   ├── writer.rs              # insert using the caller's Transaction
│   └── security_log.rs        # bounded path for authn failures and denials
├── services/                  # take &AuthzContext; perform state checks and mutations
└── db/                        # tenant-scoped queries; accept a Transaction where audited
```

Type contracts (sketch for Axum 0.7; not compiled, names are proposals):

```rust
/// Verified identity, inserted by the authentication middleware.
#[derive(Debug, Clone)]
pub struct Principal {
    pub user_id: UserId,
    pub session_id: SessionId,
    pub kind: ActorKind,            // User | Service
    pub active_site: Option<SiteId>,
}

/// Everything a service needs to authorize and audit one request.
pub struct AuthzContext {
    pub principal: Principal,
    pub permissions: PermissionSet, // resolved from current assignments, not from the token
    pub support_grant: Option<SupportGrant>,
    pub request_id: RequestId,
}

#[derive(Debug, thiserror::Error)]
pub enum AuthzError {
    #[error("authentication required")]
    Unauthenticated,
    #[error("permission denied")]
    Forbidden { permission: Permission },
    #[error("resource not found")]
    NotInScope,                     // mapped to scoped 404 or 403 per resource policy
    #[error("authorization dependency unavailable")]
    Unavailable,                    // 503; never treated as allowed
}

impl AuthzContext {
    /// Fails closed. Returns proof that the permission was checked for this site.
    pub fn require(&self, permission: Permission, site: SiteId)
        -> Result<SiteAuthorized, AuthzError>;
}

/// Only constructible by `AuthzContext::require`; services that mutate tenant data
/// take this as a parameter, so a call site cannot skip the check by accident.
pub struct SiteAuthorized { site: SiteId, permission: Permission }

/// Handler shape: the principal is required; the service performs the resource check.
pub async fn approve_registration(
    ctx: AuthzContext,                       // FromRequestParts; rejects if absent
    Path(id): Path<RegistrationId>,
    State(state): State<AppState>,
) -> Result<Json<ApprovalResultResponse>, ApiError> {
    let result = RegistrationApprovalService::new(state)
        .approve(&ctx, id)                   // require + scoped load + audit in one tx
        .await?;
    Ok(Json(result))
}
```

The `SiteAuthorized` proof token makes omission harder at the interface; it does not prove the right site was checked. Negative integration tests remain the evidence (§9). `thiserror` is not currently a dependency; either add it (checking the version against `backend/Cargo.toml`) or implement `Display` manually. In Axum 0.7, custom `FromRequestParts` implementations use `#[async_trait]`; drop it when upgrading to 0.8.

Route-policy enforcement middleware reads `axum::extract::MatchedPath`, which is available because `Router::layer` runs after route matching. Requests with no `MatchedPath` reach the fallback and are denied. Axum offers no public API to list registered routes, so declare routes once as data (method, template, handler, `RoutePolicy`) and build both the router and the policy table from it; a unit test then asserts that every entry has a policy and that no template is duplicated.

### 5.5 PostgreSQL row-level security as an additional boundary

RLS can limit damage from missing tenant predicates. Use both read visibility (`USING`) and write checks (`WITH CHECK`), a non-owner/non-superuser application role without `BYPASSRLS`, and `FORCE ROW LEVEL SECURITY` where appropriate. Set validated tenant context transaction-locally on the same pooled connection used by the queries; test missing context and cross-request leakage.

A shared application role that can set its own tenant context remains a trusted boundary. RLS does not repair incorrect context derivation or a fully compromised service. Platform work and support elevation need narrowly controlled paths. Owners and privileged roles have special bypass behavior; see [PostgreSQL row security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html).

## 6. Durable audit design

### 6.1 Separate mandatory evidence from telemetry

For payments, reversals, approvals, role changes and configuration changes, write the domain mutation and audit event using the **same database transaction and connection**. If the required event cannot be persisted, roll back the mutation and return an error. Do not mutate only the in-memory state and then append an event in a separate database transaction.

If external delivery is required, insert an outbox row in that same transaction. A supervised worker reads committed rows, retries with backoff and exposes failed delivery. Use stable event IDs and idempotent consumers for at-least-once delivery; do not promise exactly-once transport. A crash after delivery but before acknowledgement must be safe to retry.

A Tokio channel may wake a worker or carry best-effort diagnostics. It is not the source of truth for required audit evidence. Monitor backlog age, retry count, database errors and worker health. Support graceful shutdown and recovery on restart.

Authentication failures and denied actions occur outside successful business transactions. Record them through a separate bounded security-event path so a rolled-back transaction does not erase the denial record. Define outage handling explicitly: deny privileged mutations when mandatory evidence cannot be stored, keep authentication failures denied, and alert on unavailable security logging. Rate-limit/aggregate attack traffic with counters so logging cannot exhaust the service.

### 6.2 Proposed event schema

This is illustrative SQL for a future migration, not an applied migration. Confirm the next available version and register it in `backend/src/migrations.rs` before implementation. Historical identifiers intentionally have no live-entity foreign keys, so deleting a user, unit or site cannot rewrite or remove evidence.

```sql
CREATE TABLE audit_events (
    event_id UUID PRIMARY KEY,
    schema_version SMALLINT NOT NULL DEFAULT 1,
    occurred_at TIMESTAMPTZ NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    request_id TEXT NOT NULL,
    trace_id TEXT,
    actor_kind TEXT NOT NULL
        CHECK (actor_kind IN ('USER', 'SERVICE', 'ANONYMOUS')),
    actor_id TEXT,
    actor_role TEXT,
    initiator_id TEXT,
    session_reference TEXT,
    site_id BIGINT,
    unit_id BIGINT,
    action TEXT NOT NULL,
    permission TEXT,
    policy_version TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    outcome TEXT NOT NULL
        CHECK (outcome IN ('SUCCESS', 'DENIED', 'FAILURE')),
    reason_code TEXT,
    source_ip INET,
    user_agent TEXT,
    support_grant_id TEXT,
    changes JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    CHECK (actor_kind <> 'USER' OR actor_id IS NOT NULL),
    CHECK (unit_id IS NULL OR site_id IS NOT NULL)
);

CREATE INDEX audit_events_site_time
    ON audit_events (site_id, recorded_at DESC, event_id);
CREATE INDEX audit_events_actor_time
    ON audit_events (actor_id, recorded_at DESC, event_id);
CREATE INDEX audit_events_request ON audit_events (request_id);
```

Use a server-generated event ID for deduplication and carry the request correlation ID from ingress; do not generate a new trace for each handler audit event. Preserve an initiator when a service acts on a user's behalf. Anonymous events have no authenticated actor; a submitted username is not an authenticated identity. Platform events may have a null site, with an explicit platform-only read policy.

For committed operations, success means the transaction committed. Expected denials, failed attempts, external payment initiation and eventual provider settlement are distinct event types. A durable ledger remains the financial source of truth; audit is not a replacement for ledger integrity or payment idempotency.

Before insertion, validate IDs and bounded field lengths. Never convert invalid site/unit IDs into null using `.parse().ok()`. Use existing boundary parsing or typed IDs and return a validation error. Serialize money as exact decimal strings and persist monetary fields with the established decimal types; never introduce floating-point amounts.

### 6.3 Append-only permissions and tamper evidence

Use a migration owner distinct from runtime roles. Give the application only required insert access to audit storage, and authorized readers only scoped access. Remove update/delete/truncate privileges, including inherited or `PUBLIC` grants, and prevent runtime DDL ownership. Test permissions with the actual deployed role. Merely commenting out `REVOKE` statements does nothing.

An append-only application role does not prevent a database owner, superuser or compromised backup operator from altering history. If tamper evidence is required, export signed batches or manifests to independently controlled immutable storage and verify them regularly. A hash chain stored beside the events is insufficient if an attacker can rewrite both. Define signing-key custody, ordering/concurrency, retention and independent verification before claiming tamper evidence.

### 6.4 Redaction, privacy and audit access

Store allowlisted changes, such as registration status or role assignment, rather than entire serialized user objects. Exclude passwords and hashes, authorization headers, cookies, access/refresh/reset/invite tokens, private keys, bank credentials and payment-card security data. Minimize personal data and protect backups. Bound/sanitize client strings; trust forwarded IP headers only from configured proxies.

Record authentication outcomes, role/membership changes, support elevation, sensitive mutations and audit reads/exports. Authorize audit queries by tenant, permission and field visibility; use bounded filters and pagination. Residents must not obtain site-wide audit access through a unit permission. Audit export itself should have a separate permission and evidence record.

Document retention by event class, legal hold, archival, deletion authority and verification. Retention expiry is a controlled maintenance operation outside the runtime writer role. Define treatment of retained personal data and subject requests under the applicable policy; this report does not prescribe a universal legal retention period. These controls are informed by the [OWASP logging guidance](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html).

### 6.5 Audit event catalog

Initial catalog. Each event has a stable `action` string, a required permission (where applicable) and an allowlist of `changes` fields. Adding a new audited action means adding a row here and a redaction test.

| Action | Path | Trigger | Allowlisted `changes` |
| --- | --- | --- | --- |
| `AUTH_LOGIN_SUCCEEDED` / `AUTH_LOGIN_FAILED` | Security log | Password or Google sign-in | provider, reason code (never the submitted password or token) |
| `AUTH_SESSION_REVOKED` | Transactional | Logout, password change, disablement, reuse detection | session ID, reason |
| `AUTH_PASSWORD_CHANGED` / `AUTH_PASSWORD_RESET_BY_ADMIN` | Transactional | Change-password; SaaS reset of a site administrator | target user ID |
| `AUTHZ_DENIED` | Security log | Any 403 / scoped 404 from the authorizer | permission, resource type, resource ID |
| `REGISTRATION_APPROVED` / `REGISTRATION_REJECTED` | Transactional | Registration review | registration ID, status before/after, assigned role, unit ID |
| `ROLE_GRANTED` / `ROLE_REVOKED` | Transactional | Role assignment change | target user, site, unit, role, validity window |
| `HOUSEHOLD_MEMBER_ADDED` / `_REMOVED` | Transactional | Household management | unit ID, member user ID |
| `UNIT_OWNERSHIP_TRANSFERRED`, `UNIT_MOVE_IN`, `UNIT_MOVE_OUT` | Transactional | Occupancy changes | unit ID, previous/new party IDs, effective date |
| `PAYMENT_RECORDED_MANUAL`, `PAYMENT_REVERSED`, `LEDGER_TRANSFER` | Transactional | Ledger mutations | payment/ledger IDs, amount as decimal string, currency, reason code, idempotency key |
| `RECONCILIATION_CONFIRMED` | Transactional | Bank statement match | statement line ID, matched unit ID, amount as decimal string |
| `BANK_ACCOUNT_CHANGED`, `BANK_INTEGRATION_CONFIGURED` | Transactional | Bank settings | masked IBAN (last four digits), bank code; never credentials |
| `SITE_CREATED`, `SITE_SUSPENDED`, `SUBSCRIPTION_CHANGED` | Transactional | SaaS tenant management | site ID, status before/after |
| `SUPPORT_GRANT_CREATED` / `_USED` / `_REVOKED` | Transactional | Support elevation | grant ID, site, permissions, expiry, reason |
| `AUDIT_LOG_EXPORTED` | Transactional | Audit export | filter summary, row count |

## 7. Apply the structure in Flutter and web clients

Load a server-derived profile and effective permissions for navigation and button visibility. Treat client role selection as presentation state only; every API operation must enforce backend authorization. On 401, attempt at most one coordinated refresh if renewal exists, then clear identity and prompt sign-in. Do not repeatedly refresh a 403. Avoid blindly retrying financial mutations; reuse their idempotency key.

Keep short-lived access credentials in memory where practical. For persistent mobile login, store renewal credentials in platform-protected storage. For browsers, consider a backend session/BFF with Secure, HttpOnly cookies. Cookie authentication requires CSRF protection, suitable SameSite settings and origin checks; CORS alone does not prevent CSRF. Avoid long-lived credentials in localStorage because script execution can read them. See [OWASP session management guidance](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html).

Concrete Flutter changes, in order:

1. Parse `user.role` with an exact match and treat unknown values as an error, not as `homeOwner` (G10).
2. Keep `permissions` from the login and `/api/v1/auth/me` responses in the session object and gate navigation on permissions, not on role names.
3. Restrict the demo `targetRole` / `adminPath` override to a demo build flag; production builds use only server values.
4. Centralize 401 handling in `ApiClient`: clear the token, stop polling, return to sign-in. Show 403 as "not permitted" without signing out.
5. Call a server logout endpoint once it exists, then clear local state.

Restrict CORS to approved deployment origins and support preflight without bypassing authorization for business methods. Test CORS headers on rejected requests. If adding credentialed cookies, configure credential handling explicitly. Protect transport with TLS and ensure tokens never appear in URLs or logs.

## 8. Suggested module boundaries and rollout

Proposed boundaries preserve the existing application rather than requiring a framework replacement:

- `auth`: token/credential validation and required principal extraction.
- `authorization`: permission evaluation, membership and resource access decisions.
- Application services: business state transitions using a principal and request context.
- Repositories: tenant-scoped reads/writes and shared transaction support.
- `audit`: event construction/redaction and transaction-bound inserts; a separate durable exporter when needed.
- Flutter: server-derived session/profile state and user interaction.

Implementation phases. Each phase ships independently and leaves the system no less secure than before.

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| 0. Inventory and quick fixes | Route-policy inventory (§5.2) as data; fix G1, G2, G6, G7, G10; add request-ID layer (G12); reject unknown roles in `Role` parsing | Negative tests for cross-site registration approval pass in PostgreSQL mode; zero panics on auth paths; Clippy `-D warnings` clean |
| 1. Authorizer | `authorization` module (§5.4); permission matrix test (§5.1); services take `AuthzContext`; typed IDs replace `same_id` (G5); policy keyed by `MatchedPath` (G4) | Every route has one policy entry; matrix test passes; cross-tenant suite (§9) passes; existing middleware still in place as defense in depth |
| 2. Platform/tenant separation | Remove `SiteManage` from `SaasAdmin` (G8); support grants (§4.4); `is_site_staff()` no longer admits `SaasAdmin` | SaaS admin cannot read tenant data without an active grant; grant creation and use are audited |
| 3. Sessions and revocation | `auth_sessions`, refresh rotation, `auth_version`; shorter access tokens; logout endpoint | Revoked session and bumped version fail at the next request; reuse detection revokes the family; 12-hour tokens retired after one transition window |
| 4. Durable audit | Audit migration, restricted roles, transactional writes for the §6.5 catalog; security log path | Audit failure rolls back the mutation; runtime role cannot update/delete audit rows; redaction tests pass |
| 5. Audit access and operations | Query/export endpoints, Flutter audit view, retention jobs, alerting, optional outbox | Residents cannot read site audit; export is audited; alerts fire on writer failure |

Rollback rule: a rollback must not silently restore broad tenant bypasses or disable mandatory evidence. Keep feature flags for new enforcement off-by-default only during development; production enables them before release.

## 9. Verification and acceptance criteria

Before implementation is accepted, verify:

- Invalid signature, disallowed algorithm, expiry, wrong issuer/audience, malformed headers, missing required claims, revoked sessions, disabled users and suspended sites fail safely.
- Refresh rotation, reuse detection, concurrent renewal, logout and credential changes invalidate sessions as designed.
- Every method/route has an explicit policy; public endpoints remain narrow; CORS preflight does not authorize a business request.
- Cross-site and cross-unit IDs fail in paths, queries, JSON, nested IDs, bulk inputs, receipts, downloads, exports, counts and searches. Omitted/empty tenant context and stale membership cannot broaden access.
- SaaS administrators have only agreed platform rights; support grants expire, are bounded, and are audited. Roles cannot self-escalate through registration or profile editing.
- Concurrent approval/reversal and membership changes preserve business rules and scope. Jobs and direct service calls cannot omit authorization context.
- Audit insert failure rolls back the mutation; transaction failure leaves no success audit event. Denials survive business rollback. Crash/retry tests cover outbox duplication and restart recovery.
- Actual database roles cannot update/delete/truncate evidence or read another tenant's audit rows. Tenant context does not leak through pooled connections.
- Registration approval and rejection for another site's application fail in both in-memory and PostgreSQL modes (G1). Handlers cannot run without a principal (G2).
- IDs of different entity kinds never compare equal; malformed IDs return 400, not a widened match (G5). 401 bodies contain no library error text (G6).
- The permission-matrix test matches §5.1 exactly; every registered route has one policy entry; an unlisted route is denied.
- Flutter rejects unknown roles and builds without the role override in production mode.
- Events preserve request IDs, historical identifiers and exact decimal values. Redaction tests prove credentials and sensitive fields cannot enter events or exporter diagnostics.

Use real PostgreSQL integration tests for transactions, privileges, migrations and RLS; in-memory mocks cannot establish those properties. Run relevant Rust tests and Clippy with `-D warnings`, Flutter tests for session/permission flows, and the workspace gates after code implementation. The SitePulse full gate is `DB_PASS=... python3 apps/development-time/SitePulse/scripts/run_tests.py`; `--skip-db` must report skipped database gates rather than count them as passed. Follow the workspace's required harness and DevFactory suites when changing development-time code, synchronize Graphify when available, and restart the development stack after application fixes.

## 10. Threat model

| Threat | Example in SitePulse | Controls | Verified by |
| --- | --- | --- | --- |
| Cross-tenant access (IDOR) | Manager of site A approves site B's registration (G1); resident reads another unit's receipt | Repository queries scoped by site; resource-to-site resolvers; RLS as second layer | §9 cross-tenant suite |
| Privilege escalation | Self-registration body sets a role; manager grants self a role; client role override | Server-side role assignment; `RoleGrant` constraints; exact role parsing | §9 escalation tests |
| Stale authority | Moved-out resident or suspended site keeps a 12-hour token | Session lookup and `auth_version`; short access tokens | §9 revocation tests |
| Token theft and replay | Copied JWT; replayed refresh token; replayed webhook | Short TTL, refresh rotation with reuse detection, webhook dedup and timestamps | §9 token tests |
| Credential attacks | Password spraying, slow-hash exhaustion | Rate limits, bounded Argon2 workers, generic errors, MFA for privileged roles | Load and rate-limit tests |
| Platform overreach | SaaS admin browses tenant finances | Platform/tenant separation; support grants with second approver | §9 support-grant tests |
| Repudiation | Disputed payment reversal or approval | Transactional audit with typed actor and session | §9 audit tests |
| Evidence tampering | Runtime role deletes audit rows | Insert-only grants; external signed manifests if tamper evidence is required | Database privilege tests |
| Data leakage in logs | Tokens, IBANs or passwords in events or diagnostics | Allowlisted fields; masking; redaction tests | §9 redaction tests |
| Availability of controls | Database outage during authorization | Fail closed (503); alerting | Fault-injection tests |

## 11. Decisions and deployment choices

The implementation choices and retained deployment decisions are recorded in §12.4 and SPEC-008. The table below preserves the alternatives considered during review.

| # | Decision | Options | Recommendation | Blocks |
| --- | --- | --- | --- | --- |
| D1 | Do home residents (tenants) have the same rights as owners? | Same; residents read-only; residents pay but cannot manage household | Residents pay and read; owners alone manage household and invites | §5.1 rows for residents |
| D2 | Split `LedgerManageAll`? | Keep; split as §5.1 | Split, so reversals and bank changes can require step-up | Phase 1 |
| D3 | Response for out-of-scope resources | 403 everywhere; scoped 404 everywhere; per resource | Scoped 404 for resource IDs, 403 for missing permission | Error mapping in §4.1 |
| D4 | Browser credential model | Bearer tokens in memory with refresh; BFF with HttpOnly cookies | BFF with cookies for web; bearer plus secure storage for mobile | Phase 3 |
| D5 | Multiple sites or units per user | Single context per token; context switch endpoint | Single active context per session, switchable server side | §4.4 adoption |
| D6 | Support-grant approval | Self-service with audit; second approver | Second approver for tenant financial data | Phase 2 |
| D7 | Tamper evidence requirement | Append-only role only; signed external manifests | Decide from legal and contractual requirements | §6.3 |
| D8 | Audit retention periods | By event class | Requires legal input; not prescribed here | §6.4 |
| D9 | Bank integration status and test-connection scope | Per site; platform only | Per site for status; platform for configuration | §5.2 |

## 12. Implemented structure and operator guide (SPEC-008)

The security baseline is implemented in this repository. Sections 2 and 2.1 preserve the reviewed pre-implementation findings; the executable behavior is described here and in `../.specify/specs/007-authentication-authorization-audit/spec.md`.

### 12.1 Components and guarantees

- `backend/src/app.rs` declares every method/template/handler/policy together in `ROUTES`. Unregistered routes and methods do not receive a permissive default. Public routes remain individually listed.
- `backend/src/auth.rs` validates algorithm, signature, issuer, audience, expiry and required credential fields, then authenticates the stored session and resolves the current user/site/unit relationships. JWTs contain only `sub`, `sid`, `ver`, `iss`, `aud`, `iat`, `exp` and `jti`; cached roles, email and permissions cannot grant authority.
- `backend/src/security.rs` persists sessions and hashed refresh credentials. Access tokens last 600 seconds and session/refresh expiry is seven days. Refresh is single-use and transactional; replay revokes its session family. Logout, password changes, account disablement and credential/role changes invalidate access. Sensitive operations require password step-up within five minutes.
- `backend/src/authorization.rs` owns typed site/unit IDs, the required `AuthzContext` extractor, resource resolvers, role changes, support grants and audit queries. `models::Permission::permissions_for_role` remains the one role-permission mapping. Owners can manage their own household; residents read and pay. Site managers administer household records through their explicitly site-scoped `SiteManage` permission, without inheriting owner invitation rights. Platform administrators have platform permissions, with no implicit tenant access.
- Resource checks resolve current unit, registration, receipt, project and house-type scope from PostgreSQL when configured. Database misses/errors do not fall back to cached tenant authority. Registration review is a scoped transaction; indirect resources are checked before handlers run. Receipt access follows the current unit relationship rather than a cached first-unit claim. Project shares are limited to the project's site and, for residents, their authorized units.
- `backend/migrations/V19__authentication_authorization_audit.sql` adds session/refresh/support/audit storage. Database triggers insert redacted audit events in the transaction that changes the audited row. Failure to write evidence aborts that transaction. Payment/reversal and registration transactions therefore cannot commit their changes without their evidence. Invitations, account creation and household membership also commit atomically; a failed account/membership write restores the invitation for retry.
- Audited rows include tenant/user/unit changes, ownership/occupancy/memberships, invitations, sessions, support grants, liabilities, periods, payment entries/receipts/allocations, advance ledger entries, reconciliation, bank accounts, webhook claims and capital project records. Secondary changes use `table.OPERATION` action names; key actions use the event catalog names. Each event records the historical resource identifiers without live-entity foreign keys.
- `backend/src/audit.rs` generates server-owned request IDs, carries verified actor/session/support-grant context, and resets connection attribution on **every** checkout, including background work. Direct peer IP and a bounded user agent are recorded; forwarded IP headers are not trusted. Verified bank webhooks and scheduled work use service identities, rather than human administrator identities.
- Audit evidence rejects update, delete and truncate. RLS bounds non-owner reads by tenant and audit permission; native platform readers see platform events. Support access requires a different active platform administrator's approval, explicit permissions, an active site, and an expiry of at most 60 minutes. Successful support use is recorded before returning protected data; unavailable required evidence fails closed.
- Password hashing/verification uses bounded blocking workers. Authentication and step-up attempts are bounded per process. Excess security failure telemetry is aggregated after 1,000 events per minute; mandatory domain evidence and successful support usage are not discarded by this limit.
- Flutter consumes exact server roles and permission lists. Demo role switching requires `isTestMode`; production login cannot override the server role. Access/refresh credentials remain in memory, concurrent 401 responses share one refresh, and a late refresh cannot revive logout or replay an old request under a different account. A second 401 clears the session; 403 does not refresh or sign out. Release credentials are sent only to the configured HTTPS API origin (local HTTP is allowed in explicit E2E builds).

The audit table is append-only for the runtime boundary. This is not a claim that a privileged database administrator cannot alter evidence. External signed/immutable archival is a separate deployment control. The triggers preserve the application's existing transaction boundaries; this does not turn every legacy batch workflow into one global HTTP transaction.

### 12.2 App usage

Sign in normally. The returned server profile determines navigation and granted actions. For a sensitive action, open **Profile → Security and audit**, verify the current password, return to the action and retry within five minutes. This covers reversals, bank configuration changes, role grants, ownership transfers, support approval and administrator password resets.

The same full-screen page lists audit events when `AUDIT_LOG_READ` is granted. It supports older-page loading and a separately authorized export view of up to 100 recent events. The API supports up to 1,000 events per page. Owners and residents do not receive site-wide audit access.

A provisioned temporary account must change its password before protected business actions are accepted. Logout calls the backend and clears local credentials. Offline logout clears the device's credentials; the server session remains bounded by its normal expiry if the revocation request cannot reach the server.

### 12.3 Added and changed API contracts

Every protected endpoint uses `Authorization: Bearer <access_token>`. Never place credentials in URLs. Login, registration, refresh and password change return the new access and refresh credentials; replace both together. Keep refresh tokens private and never retry the same refresh credential after an uncertain outcome.

| Method and path | Contract / authority |
| --- | --- |
| `POST /api/v1/auth/refresh` | `{ "refresh_token": "..." }`; returns rotated credentials; replay returns 401 and revokes the family |
| `POST /api/v1/auth/logout` | Revokes the authenticated session |
| `POST /api/v1/auth/logout-all` | Revokes all sessions belonging to the authenticated user |
| `POST /api/v1/auth/step-up` | `{ "password": "..." }`; records five-minute recent verification on the session |
| `POST /api/v1/auth/link-google` | `{ "id_token": "..." }`; verified Google identity plus recent password step-up, for the current user only; issues replacement credentials |
| `POST /api/v1/site-admin/roles` | `{ "user_id": "...", "role": "HOME_OWNER" }` or `HOME_RESIDENT`; own site only, no self-grant or manager/platform escalation; requires `ROLE_GRANT` and step-up |
| `POST /api/v1/saas/platform-roles` | `{ "user_id": "...", "enabled": true }`; platform administrator plus `ROLE_GRANT` and step-up; grants platform status or disables another platform account, revoking sessions |
| `POST /api/v1/support/grants` | `{ "site_id": "1", "operator_user_id": "...", "permissions": ["UNIT_READ"], "reason": "Support ticket investigation", "minutes": 30 }`; operator must be the caller; returns a pending grant ID |
| `POST /api/v1/support/grants/approve` | `{ "id": "..." }`; a different active platform administrator must approve after step-up |
| `POST /api/v1/support/grants/revoke` | `{ "id": "..." }`; authorized platform administration after step-up |
| `GET /api/v1/audit/events?limit=100&before=123` | Tenant/platform-scoped events in descending event ID order; `before` is an exclusive cursor |
| `GET /api/v1/audit/export?limit=100` | Same scoping, separate `AUDIT_LOG_EXPORT` permission, and an export evidence record |

For approved support work, include `X-SitePulse-Support-Grant: <grant_id>` on each tenant request. The grant replaces the platform role's effective tenant permissions for that request. It does not grant payment reversal or unit payment rights. Revocation, expiry, inactive approvers or site suspension invalidate it immediately.

Authentication errors expose no JWT-library detail. Security errors carry stable codes including `AUTHENTICATION_REQUIRED`, `PERMISSION_DENIED`, `STEP_UP_REQUIRED`, `PASSWORD_CHANGE_REQUIRED` and `SECURITY_UNAVAILABLE`. Missing identity at a required extractor is a configuration error. Out-of-scope resources use 404. Existing unrelated business endpoints retain their established response contracts.

### 12.4 Production deployment

Production uses separate migration-owner and application-runtime connections. With the owner credentials loaded securely, run the normal backend with `SITEPULSE_MIGRATIONS_ONLY=true`; it initializes/upgrades the schema and exits. Then start with `SITEPULSE_MIGRATIONS_ONLY=false` and a non-owner runtime login. Production startup verifies the applied migration checksums read-only and refuses an owner, superuser, `BYPASSRLS`, `CREATEDB` or `CREATEROLE` runtime identity. Do not grant the runtime login membership in the migration owner role.

Provision the runtime login and its password through deployment secret management. After owner migrations, grant the application's required schema/table/sequence permissions; an example privilege setup for an already provisioned login is:

```sql
GRANT USAGE ON SCHEMA public TO sitepulse_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO sitepulse_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO sitepulse_runtime;
REVOKE UPDATE, DELETE, TRUNCATE ON audit_events FROM sitepulse_runtime;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
```

Audit RLS is enabled and forced; a runtime login must not own the table or be able to assume its owner's role. Apply the necessary grants for future tables after future owner migrations as well. Production still requires the configured signing/webhook secrets, verified database TLS (`DB_SSLMODE=require`), approved CORS origins and HTTPS at the application ingress. Changing the signing key rejects old access tokens; valid stored refresh credentials can obtain credentials signed with the new key. There is no previous-key acceptance setting in this implementation.

Selected decisions: D1–D3 use the report's recommended permission split and scoped 404 behavior; D4 keeps bearer credentials in memory rather than introducing a BFF; D5 uses the user's current primary site/role as the active context, with current unit relationships resolved server-side. `user_site_roles` is kept in sync by role-management transactions for compatibility; multi-site context switching is not exposed. D6 requires a distinct support approver; D9 makes bank status site-scoped and integration configuration/test-connection platform-scoped. D7–D8 remain deployment policy choices: no external immutable store or automatic evidence deletion is enabled. Configure distributed edge rate limits before horizontally scaling; the built-in limiter is per process. Google client registration and native/browser provider credential acquisition remain deployment/client integration concerns; the backend verifies Google credentials and supports explicit account linking.

### 12.5 Verification and maintenance

```text
python3 apps/development-time/SitePulse/scripts/run_tests.py --from-dev-container
cargo fmt --manifest-path apps/development-time/SitePulse/backend/Cargo.toml --check
dotnet test factory/DevFactory
```

`--from-dev-container` loads the local development container's database settings without printing credentials. Use explicit `DB_PASS`/connection settings for another database. The API and schema gates operate on disposable databases; they do not seed or erase the live application database. GUI fixture resets preserve audit evidence and use pre-provisioned permanent test accounts; temporary-account scenarios create their own accounts. GUI builds are cached only while source, dependency inputs, assets and API origin match their recorded fingerprint.

SPEC-008 API checks cover refresh replay/logout, audit attribution and rollback injection, non-owner RLS/immutability, database-only tenant review, support approval/use/revocation, and concurrent invitation consumption with account/membership rollback. The earlier ledger and financial fixture checks remain in the gate run. The pre-integration local non-browser run passed all 12 gates (the GUI gate was explicitly skipped there and run separately), including warning-free Clippy and Flutter analysis/tests; formatting and whitespace checks passed. DevFactory passed all 15 tests. The pre-integration full Chromium run completed successfully: 98 cases, 63 passed and 35 existing expected failures, with zero unexpected failures/errors (859.6 seconds). It used a rebuilt final Flutter bundle and disposable PostgreSQL database on isolated ports 8183/9193. Expected failures remain tracked pre-existing application defects; they are not counted as passing tests. After integrating master's payments and modular controller changes, all 14 non-browser gates passed, including the added Rust standards and Flutter reuse gates. All 28 API scenarios pass, with ledger integrity checked after every scenario. Local gate results do not fabricate CI evidence or mark historical unverified tasks as verified.


### 12.6 Master integration

Master's immutable `V18__payments_phase2.sql`, SPEC-007 and task-28 are retained. Security uses `V19__authentication_authorization_audit.sql`, SPEC-008 and task-29. The integration preserves the extracted backend handlers, shared domain primitives, Flutter components and modular dashboard controller. New payment, budget, PDF and provider routes have explicit authorization policies; payment/budget rows receive transaction-bound audit evidence, with verified provider notifications attributed to a restricted machine identity.

A database that has applied the earlier feature-branch V18 security migration must not be pointed at this canonical history or have its checksums bypassed. That earlier isolated development database is retained separately. The normal master database can apply V19 after its existing payments V18 without replacing that migration or erasing tenant records. Local connection settings and secrets remain ignored by Git.


## Appendix A. Configuration

| Variable | Status | Purpose |
| --- | --- | --- |
| `SITEPULSE_JWT_SECRET` | Current; required in production, at least 32 characters | HS256 signing key |
| `SITEPULSE_BANK_WEBHOOK_SECRET` | Current; required in production | Webhook HMAC key |
| `SITEPULSE_CORS_ORIGINS` | Current | Comma-separated allowed origins |
| `SITEPULSE_ENABLE_DEV_ROUTES` | Current; ignored in production | Mounts `/api/v1/system/*` |
| `APP_ENV` / `ENVIRONMENT` | Current | `production`, `prod` or `live` enables production rules |
| `SITEPULSE_JWT_ISSUER`, `SITEPULSE_JWT_AUDIENCE` | Current | Expected `iss` / `aud` |
| `SITEPULSE_ACCESS_TOKEN_TTL_SECONDS`, `SITEPULSE_REFRESH_TOKEN_TTL_SECONDS` | Not read | Current lifetimes are constants: 600 seconds and seven days |
| `SITEPULSE_JWT_PREVIOUS_SECRET` | Not read | Rotate the current key; old access credentials must refresh |
| `SITEPULSE_TRUSTED_PROXIES` | Not read | Only the directly connected peer IP is recorded |
| `SITEPULSE_SUPPORT_GRANT_MAX_MINUTES` | Not read | The implemented hard limit is 60 minutes |
| `SITEPULSE_MIGRATIONS_ONLY` | Current | Owner migration/initialization mode; exits before serving requests |

The original two review passes identified the baseline gaps in §2.1. Implementation and local verification are documented in §12; this is not a production security certification.
