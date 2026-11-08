//! Identity normalization: one canonical form for email addresses.
//!
//! Every comparison of a request email with a stored email must normalize
//! **both** sides the same way; comparing `input.trim().to_lowercase()` with
//! `stored.to_lowercase()` misses stored values with surrounding whitespace.

use std::fmt;

use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum EmailError {
    #[error("Email address is required.")]
    Empty,
    #[error("Email address is not valid.")]
    Invalid,
}

/// A trimmed, lower-cased email address with a minimal structural check
/// (`local@domain`, no whitespace).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NormalizedEmail(String);

impl NormalizedEmail {
    /// Validates and normalizes a user-supplied address.
    pub fn parse(raw: &str) -> Result<Self, EmailError> {
        let normalized = Self::normalize(raw);
        if normalized.is_empty() {
            return Err(EmailError::Empty);
        }
        let mut parts = normalized.splitn(2, '@');
        let (Some(local), Some(domain)) = (parts.next(), parts.next()) else {
            return Err(EmailError::Invalid);
        };
        if local.is_empty()
            || domain.is_empty()
            || domain.contains('@')
            || normalized.chars().any(char::is_whitespace)
        {
            return Err(EmailError::Invalid);
        }
        Ok(Self(normalized))
    }

    /// The canonical form of any string, valid or not. Use it for lookups and
    /// comparisons against stored values, which predate validation.
    pub fn normalize(raw: &str) -> String {
        raw.trim().to_lowercase()
    }

    /// True when `stored` normalizes to this address.
    pub fn matches(&self, stored: &str) -> bool {
        Self::normalize(stored) == self.0
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

impl fmt::Display for NormalizedEmail {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl AsRef<str> for NormalizedEmail {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

/// True when two possibly unnormalized addresses denote the same identity.
pub fn same_email(a: &str, b: &str) -> bool {
    NormalizedEmail::normalize(a) == NormalizedEmail::normalize(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_case_and_surrounding_whitespace() {
        let email = NormalizedEmail::parse("  Admin@SitePulse.IO ").unwrap();
        assert_eq!(email.as_str(), "admin@sitepulse.io");
        assert!(email.matches("admin@sitepulse.io"));
        assert!(
            email.matches(" ADMIN@sitepulse.io\t"),
            "stored whitespace must not defeat matching"
        );
        assert!(!email.matches("other@sitepulse.io"));
    }

    #[test]
    fn rejects_structurally_invalid_addresses() {
        assert_eq!(NormalizedEmail::parse("   "), Err(EmailError::Empty));
        for bad in ["no-at-sign", "@domain.com", "local@", "a@b@c", "a b@c.com"] {
            assert_eq!(
                NormalizedEmail::parse(bad),
                Err(EmailError::Invalid),
                "{bad}"
            );
        }
    }

    #[test]
    fn same_email_normalizes_both_sides() {
        assert!(same_email(" A@B.COM ", "a@b.com "));
        assert!(!same_email("a@b.com", "a@c.com"));
    }
}
