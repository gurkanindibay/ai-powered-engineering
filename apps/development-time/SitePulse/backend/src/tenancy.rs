//! Tenant scope: the typed, mandatory answer to "which site may this request
//! touch?".
//!
//! The authentication middleware (`auth::require_auth`) already rejects
//! foreign site ids it can find in paths, query strings and JSON bodies. That
//! check is heuristic (it only sees fields named `site_id`/`siteId`), so every
//! handler that acts on a site also takes a [`TenantScope`] and pins its input
//! through it. The scope is derived from the verified token only, never from
//! the request, and a missing token fails closed (401).
//!
//! * Site staff and residents are [`TenantScope::Site`]: a requested site must
//!   be their own; an omitted one becomes their own.
//! * SaaS administrators are [`TenantScope::Platform`]: they may name any site,
//!   and may omit it where the endpoint supports a platform-wide view.
//!
//! `scripts/tenant_isolation_lint.py` (gate `tenant-lint`) fails the build when
//! a handler accepts a site-bearing request type without a scope.

use axum::{
    extract::FromRequestParts,
    http::{request::Parts, StatusCode},
    response::{IntoResponse, Response},
    Json,
};

use crate::auth::{same_id, Claims};

/// A request was refused by the tenant scope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TenantDenied {
    pub status: StatusCode,
    pub message: String,
}

impl TenantDenied {
    fn forbidden() -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: "Site belongs to another tenant".to_string(),
        }
    }

    fn unauthenticated() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: "Missing tenant scope".to_string(),
        }
    }

    /// The `{"status":"ERROR","message":..}` body most handlers return.
    pub fn json(self) -> (StatusCode, Json<serde_json::Value>) {
        (
            self.status,
            Json(serde_json::json!({ "status": "ERROR", "message": self.message })),
        )
    }
}

impl IntoResponse for TenantDenied {
    fn into_response(self) -> Response {
        self.json().into_response()
    }
}

impl From<TenantDenied> for crate::error::AppError {
    fn from(d: TenantDenied) -> Self {
        crate::error::AppError::from((d.status, d.message))
    }
}

impl From<TenantDenied> for (StatusCode, String) {
    fn from(d: TenantDenied) -> Self {
        (d.status, d.message)
    }
}

/// Which tenant(s) the authenticated caller may act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TenantScope {
    /// Exactly one site (site manager, home owner, resident).
    Site {
        site_id: String,
        unit_id: Option<String>,
    },
    /// Every site (SaaS administrator, platform jobs).
    Platform,
}

impl TenantScope {
    pub fn from_claims(claims: &Claims) -> Self {
        if claims.is_saas_admin() {
            TenantScope::Platform
        } else {
            TenantScope::Site {
                site_id: claims.site_id.clone(),
                unit_id: claims.unit_id.clone(),
            }
        }
    }

    /// The platform scope, for internal jobs and tests (never from a request).
    pub fn platform() -> Self {
        TenantScope::Platform
    }

    /// A single-site scope, for internal jobs and tests (never from a request).
    pub fn site(site_id: impl Into<String>) -> Self {
        TenantScope::Site {
            site_id: site_id.into(),
            unit_id: None,
        }
    }

    pub fn is_platform(&self) -> bool {
        matches!(self, TenantScope::Platform)
    }

    /// The caller's own site, if the scope is a single site.
    pub fn own_site(&self) -> Option<&str> {
        match self {
            TenantScope::Site { site_id, .. } => Some(site_id),
            TenantScope::Platform => None,
        }
    }

    /// Whether the scope covers `site_id`.
    pub fn allows(&self, site_id: &str) -> bool {
        match self {
            TenantScope::Platform => true,
            TenantScope::Site { site_id: own, .. } => !own.is_empty() && same_id(own, site_id),
        }
    }

    /// Fails unless the scope covers `site_id`.
    pub fn ensure(&self, site_id: &str) -> Result<(), TenantDenied> {
        if self.allows(site_id) {
            Ok(())
        } else {
            Err(TenantDenied::forbidden())
        }
    }

    /// Pins an optional requested site: a single-site caller gets their own
    /// site (a foreign one is refused); the platform keeps what it asked for,
    /// including `None` for platform-wide views.
    pub fn pin_opt(&self, requested: &mut Option<String>) -> Result<(), TenantDenied> {
        let asked = requested
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty() && *s != "undefined" && *s != "null" && *s != "all");
        match self {
            TenantScope::Platform => {
                if asked.is_none() {
                    *requested = None;
                }
                Ok(())
            }
            TenantScope::Site { site_id: own, .. } => {
                if own.is_empty() {
                    return Err(TenantDenied::forbidden());
                }
                match asked {
                    Some(s) if !same_id(own, s) => Err(TenantDenied::forbidden()),
                    _ => {
                        *requested = Some(own.clone());
                        Ok(())
                    }
                }
            }
        }
    }

    /// Pins an optional requested site and returns it ("" when the platform
    /// asked for no particular site).
    pub fn pinned(&self, requested: Option<String>) -> Result<String, TenantDenied> {
        let mut r = requested;
        self.pin_opt(&mut r)?;
        Ok(r.unwrap_or_default())
    }

    /// Pins a required requested site (empty means "the caller's own site").
    pub fn pin(&self, requested: &mut String) -> Result<(), TenantDenied> {
        let mut opt = Some(std::mem::take(requested));
        self.pin_opt(&mut opt)?;
        *requested = opt.unwrap_or_default();
        Ok(())
    }

    /// Resolves the single site an operation acts on. The platform must name it.
    pub fn resolve(&self, requested: Option<&str>) -> Result<String, TenantDenied> {
        let mut opt = requested.map(str::to_string);
        self.pin_opt(&mut opt)?;
        opt.ok_or(TenantDenied {
            status: StatusCode::BAD_REQUEST,
            message: "site_id is required".to_string(),
        })
    }
}

impl<S: Send + Sync> FromRequestParts<S> for TenantScope {
    type Rejection = TenantDenied;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        parts
            .extensions
            .get::<Claims>()
            .map(TenantScope::from_claims)
            .ok_or_else(TenantDenied::unauthenticated)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn site_scope_pins_missing_and_refuses_foreign_sites() {
        let scope = TenantScope::site("1");
        let mut none = None;
        scope.pin_opt(&mut none).unwrap();
        assert_eq!(none.as_deref(), Some("1"));
        let mut same = Some("site-1".to_string());
        scope.pin_opt(&mut same).unwrap();
        assert_eq!(same.as_deref(), Some("1"));
        let mut other = Some("2".to_string());
        assert_eq!(
            scope.pin_opt(&mut other).unwrap_err().status,
            StatusCode::FORBIDDEN
        );
    }

    #[test]
    fn an_unit_id_never_passes_as_a_site_id() {
        let scope = TenantScope::site("site-5");
        assert!(!scope.allows("d-5"));
        assert!(scope.allows("5"));
    }

    #[test]
    fn empty_site_claim_fails_closed() {
        let scope = TenantScope::site("");
        assert!(!scope.allows("1"));
        assert!(scope.pin_opt(&mut None).is_err());
    }

    #[test]
    fn platform_keeps_its_request_and_must_name_a_site_to_resolve() {
        let scope = TenantScope::platform();
        let mut all = Some("all".to_string());
        scope.pin_opt(&mut all).unwrap();
        assert_eq!(all, None);
        assert!(scope.resolve(None).is_err());
        assert_eq!(scope.resolve(Some("7")).unwrap(), "7");
    }

    #[test]
    fn a_site_scope_never_allows_an_empty_or_zero_site() {
        assert!(!TenantScope::site("").allows(""));
        assert!(!TenantScope::site("1").allows(""));
    }
}
