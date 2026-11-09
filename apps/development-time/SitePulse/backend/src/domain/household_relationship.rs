//! A household member's relationship to the unit's occupant (person module F5).
//!
//! Stored and returned as a fixed English code; the app shows a localized label.
//! Input also accepts the Turkish labels older clients sent, so existing screens
//! and links keep working while every stored value stays one of the codes.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum HouseholdRelationship {
    Spouse,
    Child,
    Parent,
    Relative,
    Other,
}

impl HouseholdRelationship {
    pub const ALL: [Self; 5] = [
        Self::Spouse,
        Self::Child,
        Self::Parent,
        Self::Relative,
        Self::Other,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Spouse => "SPOUSE",
            Self::Child => "CHILD",
            Self::Parent => "PARENT",
            Self::Relative => "RELATIVE",
            Self::Other => "OTHER",
        }
    }

    /// Reads a code or a legacy label; an empty value means `OTHER`.
    /// Returns `None` for text that is neither, so it is refused, not guessed.
    pub fn from_input(value: &str) -> Option<Self> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Some(Self::Other);
        }
        let upper = trimmed.to_uppercase();
        if let Some(code) = Self::ALL.into_iter().find(|r| r.as_str() == upper) {
            return Some(code);
        }
        let folded = crate::domain::text::fold_turkish(trimmed);
        match folded.as_str() {
            "esi" | "es" | "esim" => Some(Self::Spouse),
            "cocugu" | "cocuk" | "oglu" | "kizi" => Some(Self::Child),
            "anne/baba" | "annesi" | "babasi" | "ebeveyni" | "ebeveyn" => Some(Self::Parent),
            "kardesi" | "kardes" | "akrabasi" | "akraba" | "family" => Some(Self::Relative),
            "diger" | "ev arkadasi" | "ev sakini" | "household_member" | "resident" => {
                Some(Self::Other)
            }
            _ => None,
        }
    }
}

/// The refusal for an unknown relationship value.
pub const UNKNOWN_RELATIONSHIP: &str =
    "Relationship must be one of SPOUSE, CHILD, PARENT, RELATIVE, OTHER.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_round_trip() {
        for r in HouseholdRelationship::ALL {
            assert_eq!(HouseholdRelationship::from_input(r.as_str()), Some(r));
            assert_eq!(
                HouseholdRelationship::from_input(&r.as_str().to_lowercase()),
                Some(r)
            );
        }
    }

    #[test]
    fn legacy_turkish_labels_map_to_codes() {
        use HouseholdRelationship::*;
        for (label, code) in [
            ("Eşi", Spouse),
            ("Çocuğu", Child),
            ("Anne/Baba", Parent),
            ("Kardeşi", Relative),
            ("Akrabası", Relative),
            ("Ev Arkadaşı", Other),
            ("Diğer", Other),
            ("Ev Sakini", Other),
            ("", Other),
        ] {
            assert_eq!(
                HouseholdRelationship::from_input(label),
                Some(code),
                "{label}"
            );
        }
    }

    #[test]
    fn unknown_text_is_refused() {
        assert_eq!(HouseholdRelationship::from_input("Landlord's cousin"), None);
    }
}
