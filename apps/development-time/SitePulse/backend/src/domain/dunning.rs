//! Dunning schedule, SPEC-009 R4: which reminder or notice is due for an overdue
//! liability, given the days past due and the steps already executed.

use thiserror::Error;

use super::kvkk::DeliveryChannel;

/// What a step produces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DunningKind {
    /// A friendly reminder; respects the resident's opt-out.
    Reminder,
    /// A written warning that announces legal action.
    WrittenWarning,
    /// The ihtarname draft (sent by registered mail or a notary, outside the app).
    Ihtarname,
}

impl DunningKind {
    pub fn as_str(self) -> &'static str {
        match self {
            DunningKind::Reminder => "REMINDER",
            DunningKind::WrittenWarning => "WRITTEN_WARNING",
            DunningKind::Ihtarname => "IHTARNAME",
        }
    }

    pub fn parse(raw: &str) -> Result<Self, DunningError> {
        match raw.trim().to_ascii_uppercase().as_str() {
            "REMINDER" => Ok(DunningKind::Reminder),
            "WRITTEN_WARNING" => Ok(DunningKind::WrittenWarning),
            "IHTARNAME" => Ok(DunningKind::Ihtarname),
            other => Err(DunningError::UnknownKind(other.to_string())),
        }
    }

    /// Legal notices go out regardless of an opt-out.
    pub fn is_mandatory(self) -> bool {
        !matches!(self, DunningKind::Reminder)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DunningStep {
    pub day_offset: u32,
    pub channel: DeliveryChannel,
    pub kind: DunningKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DunningError {
    #[error("a dunning policy needs between 1 and 10 steps")]
    StepCount,
    #[error("step {0}: day offsets must increase strictly")]
    NotIncreasing(usize),
    #[error("step {0}: a dunning step must use a personal channel (KVKK)")]
    GroupChannel(usize),
    #[error("step {0}: day offset must be between 1 and 365")]
    Offset(usize),
    #[error("unknown dunning step kind '{0}'")]
    UnknownKind(String),
}

/// D+3 push, D+10 SMS, D+30 written warning by e-mail, D+45 ihtarname letter.
pub fn default_steps() -> Vec<DunningStep> {
    vec![
        DunningStep {
            day_offset: 3,
            channel: DeliveryChannel::Push,
            kind: DunningKind::Reminder,
        },
        DunningStep {
            day_offset: 10,
            channel: DeliveryChannel::Sms,
            kind: DunningKind::Reminder,
        },
        DunningStep {
            day_offset: 30,
            channel: DeliveryChannel::Email,
            kind: DunningKind::WrittenWarning,
        },
        DunningStep {
            day_offset: 45,
            channel: DeliveryChannel::Letter,
            kind: DunningKind::Ihtarname,
        },
    ]
}

pub fn validate_steps(steps: &[DunningStep]) -> Result<(), DunningError> {
    if steps.is_empty() || steps.len() > 10 {
        return Err(DunningError::StepCount);
    }
    for (i, s) in steps.iter().enumerate() {
        if !(1..=365).contains(&s.day_offset) {
            return Err(DunningError::Offset(i));
        }
        if !s.channel.is_personal() {
            return Err(DunningError::GroupChannel(i));
        }
        if i > 0 && s.day_offset <= steps[i - 1].day_offset {
            return Err(DunningError::NotIncreasing(i));
        }
    }
    Ok(())
}

/// The step to execute now: the latest step whose offset has passed and that was
/// not executed yet. Earlier missed steps are skipped (a resident who is 40 days
/// late gets the written warning, not four messages at once). Returns `None` when
/// nothing is due.
pub fn step_due(steps: &[DunningStep], days_past_due: i64, executed: &[usize]) -> Option<usize> {
    let latest = steps
        .iter()
        .enumerate()
        .filter(|(_, s)| i64::from(s.day_offset) <= days_past_due)
        .map(|(i, _)| i)
        .next_back()?;
    // Once a later step ran, an earlier one never runs again.
    if executed.iter().any(|&e| e >= latest) {
        return None;
    }
    Some(latest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_latest_passed_step_runs_once() {
        let steps = default_steps();
        assert_eq!(step_due(&steps, 2, &[]), None);
        assert_eq!(step_due(&steps, 3, &[]), Some(0));
        assert_eq!(step_due(&steps, 5, &[0]), None);
        assert_eq!(step_due(&steps, 12, &[0]), Some(1));
        assert_eq!(
            step_due(&steps, 40, &[]),
            Some(2),
            "missed steps are skipped"
        );
        assert_eq!(step_due(&steps, 40, &[2]), None);
        assert_eq!(step_due(&steps, 90, &[0, 1, 2]), Some(3));
        assert_eq!(step_due(&steps, 90, &[3]), None);
        assert_eq!(step_due(&steps, -5, &[]), None);
    }

    #[test]
    fn policies_are_validated() {
        assert!(validate_steps(&default_steps()).is_ok());
        assert_eq!(validate_steps(&[]), Err(DunningError::StepCount));
        let mut steps = default_steps();
        steps[1].day_offset = 3;
        assert_eq!(validate_steps(&steps), Err(DunningError::NotIncreasing(1)));
        let mut steps = default_steps();
        steps[0].channel = DeliveryChannel::WhatsAppGroup;
        assert_eq!(validate_steps(&steps), Err(DunningError::GroupChannel(0)));
        let mut steps = default_steps();
        steps[0].day_offset = 0;
        assert_eq!(validate_steps(&steps), Err(DunningError::Offset(0)));
    }

    #[test]
    fn only_reminders_respect_an_opt_out() {
        assert!(!DunningKind::Reminder.is_mandatory());
        assert!(DunningKind::WrittenWarning.is_mandatory());
        assert_eq!(DunningKind::parse("ihtarname"), Ok(DunningKind::Ihtarname));
        assert!(DunningKind::parse("x").is_err());
    }
}
