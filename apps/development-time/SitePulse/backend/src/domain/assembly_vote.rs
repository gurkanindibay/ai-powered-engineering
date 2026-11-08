//! Kat malikleri kurulu quorum and voting, SPEC-009 R12 (KMK 30, verify).
//!
//! * First call: the assembly convenes with a majority of the owners by count
//!   and by land share (arsa payı). Second call: whoever attends.
//! * `SIMPLE`: more YES than half of the votes cast by present owners (by count).
//! * `TWO_THIRDS`, `FOUR_FIFTHS`: that fraction of *all* units, by count and by
//!   land share.
//! * `UNANIMOUS`: every unit votes YES.

use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoteRule {
    Simple,
    TwoThirds,
    FourFifths,
    Unanimous,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum VoteError {
    #[error("unknown voting rule '{0}'")]
    UnknownRule(String),
    #[error("unknown vote '{0}' (YES, NO or ABSTAIN)")]
    UnknownVote(String),
}

impl VoteRule {
    pub fn as_str(self) -> &'static str {
        match self {
            VoteRule::Simple => "SIMPLE",
            VoteRule::TwoThirds => "TWO_THIRDS",
            VoteRule::FourFifths => "FOUR_FIFTHS",
            VoteRule::Unanimous => "UNANIMOUS",
        }
    }

    pub fn parse(raw: &str) -> Result<Self, VoteError> {
        match raw.trim().to_ascii_uppercase().as_str() {
            "SIMPLE" => Ok(VoteRule::Simple),
            "TWO_THIRDS" => Ok(VoteRule::TwoThirds),
            "FOUR_FIFTHS" => Ok(VoteRule::FourFifths),
            "UNANIMOUS" => Ok(VoteRule::Unanimous),
            other => Err(VoteError::UnknownRule(other.to_string())),
        }
    }

    /// The qualified fraction (numerator, denominator) of all units, if any.
    fn fraction(self) -> Option<(u64, u64)> {
        match self {
            VoteRule::TwoThirds => Some((2, 3)),
            VoteRule::FourFifths => Some((4, 5)),
            VoteRule::Unanimous => Some((1, 1)),
            VoteRule::Simple => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vote {
    Yes,
    No,
    Abstain,
}

impl Vote {
    pub fn parse(raw: &str) -> Result<Self, VoteError> {
        match raw.trim().to_ascii_uppercase().as_str() {
            "YES" | "KABUL" => Ok(Vote::Yes),
            "NO" | "RET" => Ok(Vote::No),
            "ABSTAIN" | "CEKIMSER" => Ok(Vote::Abstain),
            other => Err(VoteError::UnknownVote(other.to_string())),
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Vote::Yes => "YES",
            Vote::No => "NO",
            Vote::Abstain => "ABSTAIN",
        }
    }
}

/// The whole site: every unit and its land share.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Electorate {
    pub units: u64,
    pub land_share: u64,
}

/// Units present (in person or by proxy).
pub fn has_quorum(
    electorate: Electorate,
    present_units: u64,
    present_share: u64,
    call: u8,
) -> bool {
    if call >= 2 {
        return present_units > 0;
    }
    present_units * 2 > electorate.units && present_share * 2 > electorate.land_share
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Tally {
    pub yes: u64,
    pub no: u64,
    pub abstain: u64,
    pub yes_share: u64,
}

impl Tally {
    pub fn add(&mut self, vote: Vote, land_share: u64) {
        match vote {
            Vote::Yes => {
                self.yes += 1;
                self.yes_share += land_share;
            }
            Vote::No => self.no += 1,
            Vote::Abstain => self.abstain += 1,
        }
    }
}

/// Whether the motion passes.
pub fn passes(rule: VoteRule, tally: Tally, electorate: Electorate) -> bool {
    match rule.fraction() {
        None => tally.yes > tally.no && tally.yes * 2 > tally.yes + tally.no + tally.abstain,
        Some((num, den)) => {
            tally.yes * den >= electorate.units * num
                && tally.yes_share * den >= electorate.land_share * num
                && tally.yes > 0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SITE: Electorate = Electorate {
        units: 10,
        land_share: 1000,
    };

    #[test]
    fn first_call_needs_count_and_share_majorities() {
        assert!(has_quorum(SITE, 6, 501, 1));
        assert!(!has_quorum(SITE, 6, 500, 1));
        assert!(!has_quorum(SITE, 5, 900, 1));
        assert!(has_quorum(SITE, 1, 10, 2));
        assert!(!has_quorum(SITE, 0, 0, 2));
    }

    #[test]
    fn rules_count_votes_and_land_share() {
        let mut t = Tally::default();
        for _ in 0..4 {
            t.add(Vote::Yes, 100);
        }
        t.add(Vote::No, 100);
        t.add(Vote::Abstain, 100);
        assert!(passes(VoteRule::Simple, t, SITE), "4 of 6 present");
        assert!(!passes(VoteRule::TwoThirds, t, SITE), "4 of 10 units");

        let mut q = Tally::default();
        for _ in 0..7 {
            q.add(Vote::Yes, 100);
        }
        assert!(passes(VoteRule::TwoThirds, q, SITE));
        assert!(!passes(VoteRule::FourFifths, q, SITE));
        assert!(!passes(VoteRule::Unanimous, q, SITE));

        let mut small_share = Tally::default();
        for _ in 0..7 {
            small_share.add(Vote::Yes, 50);
        }
        assert!(
            !passes(VoteRule::TwoThirds, small_share, SITE),
            "land share 350 of 1000"
        );

        let mut tie = Tally::default();
        tie.add(Vote::Yes, 1);
        tie.add(Vote::No, 1);
        assert!(!passes(VoteRule::Simple, tie, SITE));
    }

    #[test]
    fn rules_and_votes_parse() {
        assert_eq!(VoteRule::parse("two_thirds"), Ok(VoteRule::TwoThirds));
        assert!(VoteRule::parse("x").is_err());
        assert_eq!(Vote::parse("kabul"), Ok(Vote::Yes));
        assert!(Vote::parse("maybe").is_err());
    }
}
