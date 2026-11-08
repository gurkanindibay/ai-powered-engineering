# SPEC-008 — Authentication, Authorization and Audit

Implement the latest ROLE_BASED_AUTH_AND_AUDIT_ARCHITECTURE_REPORT.md as the security baseline.
This is an independent remediation task against the existing application, not a child of unverified historical feature tasks.

## Decisions
Owners can read/pay/invite/manage their own household; residents can read/pay only.
Site managers operate only inside their active site; platform administrators have platform rights only.
Resource scope failures use scoped 404; missing permissions use 403. Keep bearer credentials in memory for web/mobile for now.
Require a recent password verification for sensitive operations. Support access requires a different platform administrator's approval and expires.
Access credentials expire after 10 minutes. Sessions are persistent with rotating 7-day refresh credentials and immediate revocation.
Retain audit evidence indefinitely until an approved retention policy exists. No external immutable storage or BFF is provisioned by this task.

## Acceptance
- One method/template registry defines all routes and their policies; unknown routes have no access.
- Signature, issuer, audience, expiry, session, current account/site and membership are checked on every protected request.
- Cross-tenant resources are denied for path/query/body and indirect identifiers; site managers cannot act as platform admins.
- Session refresh rotates once; replay revokes the family; logout/password changes invalidate old credentials.
- Mandatory domain writes and their audit events commit/rollback together; secrets never enter event changes.
- Audit reads/exports are permission- and tenant-scoped, bounded, and recorded.
- Flutter accepts exact server roles/permissions, handles expired sessions centrally and calls server logout.
- Security unit/integration tests, Clippy, Flutter and workspace gates establish behavior; database gates are never reported passed when skipped.
