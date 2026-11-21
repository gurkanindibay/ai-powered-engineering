//! Conversion helpers for person keys used when a person has no login account.

/// Returns the synthetic key used for a person without a user account.
pub fn person_key(person_id: i64) -> String {
    format!("person-{person_id}")
}

/// Parses a synthetic person key without accepting other entity-id prefixes.
pub fn parse_person_key(key: &str) -> Option<i64> {
    key.strip_prefix("person-")
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|person_id| *person_id > 0)
}

#[cfg(test)]
mod tests {
    use super::{parse_person_key, person_key};

    #[test]
    fn person_keys_round_trip_and_reject_other_ids() {
        assert_eq!(person_key(27), "person-27");
        assert_eq!(parse_person_key("person-27"), Some(27));
        for invalid in ["27", "user-27", "person-0", "person--1", "person-nope"] {
            assert_eq!(parse_person_key(invalid), None, "{invalid}");
        }
    }
}
