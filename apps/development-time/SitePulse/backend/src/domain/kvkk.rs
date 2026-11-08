//! KVKK (6698) rules for financial data, SPEC-009 R2.
//!
//! Decision 2026/348 of the Kişisel Verileri Koruma Kurulu: a resident's debt is
//! personal data. A debt notice is sent only to the debtor's personal channel,
//! never to a group chat or a notice board, and a named debtor list is never
//! shown to people who do not need it.

use thiserror::Error;

/// Where a message is delivered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeliveryChannel {
    Email,
    Sms,
    Push,
    /// A direct WhatsApp message to the debtor's own number.
    WhatsApp,
    /// A letter (ihtarname, registered mail).
    Letter,
    GroupChat,
    NoticeBoard,
    WhatsAppGroup,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ChannelError {
    #[error("unknown delivery channel '{0}'")]
    Unknown(String),
}

impl DeliveryChannel {
    pub const ALL: [DeliveryChannel; 8] = [
        DeliveryChannel::Email,
        DeliveryChannel::Sms,
        DeliveryChannel::Push,
        DeliveryChannel::WhatsApp,
        DeliveryChannel::Letter,
        DeliveryChannel::GroupChat,
        DeliveryChannel::NoticeBoard,
        DeliveryChannel::WhatsAppGroup,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            DeliveryChannel::Email => "EMAIL",
            DeliveryChannel::Sms => "SMS",
            DeliveryChannel::Push => "PUSH",
            DeliveryChannel::WhatsApp => "WHATSAPP",
            DeliveryChannel::Letter => "LETTER",
            DeliveryChannel::GroupChat => "GROUP_CHAT",
            DeliveryChannel::NoticeBoard => "NOTICE_BOARD",
            DeliveryChannel::WhatsAppGroup => "WHATSAPP_GROUP",
        }
    }

    pub fn parse(raw: &str) -> Result<Self, ChannelError> {
        let upper = raw.trim().to_ascii_uppercase();
        Self::ALL
            .into_iter()
            .find(|c| c.as_str() == upper)
            .ok_or(ChannelError::Unknown(raw.trim().to_string()))
    }

    /// Reaches only the addressee.
    pub fn is_personal(self) -> bool {
        matches!(
            self,
            DeliveryChannel::Email
                | DeliveryChannel::Sms
                | DeliveryChannel::Push
                | DeliveryChannel::WhatsApp
                | DeliveryChannel::Letter
        )
    }

    /// Channels a resident can opt out of (electronic messages). A letter is the
    /// legal fallback and needs no consent.
    pub fn is_consentable(self) -> bool {
        matches!(
            self,
            DeliveryChannel::Email
                | DeliveryChannel::Sms
                | DeliveryChannel::Push
                | DeliveryChannel::WhatsApp
        )
    }
}

/// Why a message may not be sent.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DeliveryRefusal {
    #[error("KVKK 2026/348: a debt notice is never sent to a group channel ({0})")]
    GroupChannelForDebt(&'static str),
    #[error("the recipient opted out of {0} messages")]
    OptedOut(&'static str),
    #[error("the recipient has no {0} contact")]
    NoContact(&'static str),
}

/// Decides whether a message of this kind may go out on `channel`.
///
/// * `carries_debt`: the message names a debt (reminder, warning, collection).
/// * `mandatory`: a legal notice that does not depend on consent (written warning,
///   ihtarname). Reminders respect an opt-out; legal notices do not.
/// * `opted_out`: the recipient withdrew consent for this channel.
/// * `has_contact`: the recipient has an address for this channel.
pub fn check_delivery(
    channel: DeliveryChannel,
    carries_debt: bool,
    mandatory: bool,
    opted_out: bool,
    has_contact: bool,
) -> Result<(), DeliveryRefusal> {
    if carries_debt && !channel.is_personal() {
        return Err(DeliveryRefusal::GroupChannelForDebt(channel.as_str()));
    }
    if opted_out && channel.is_consentable() && !mandatory {
        return Err(DeliveryRefusal::OptedOut(channel.as_str()));
    }
    if !has_contact && channel != DeliveryChannel::Letter {
        return Err(DeliveryRefusal::NoContact(channel.as_str()));
    }
    Ok(())
}

/// Masks a person's name for people who may see that a debt exists but not
/// whose it is: every word keeps its first letter ("Ayşe Yılmaz" -> "A*** Y***").
pub fn mask_name(name: &str) -> String {
    let masked: Vec<String> = name
        .split_whitespace()
        .filter_map(|w| w.chars().next())
        .map(|first| format!("{}***", first))
        .collect();
    if masked.is_empty() {
        "***".to_string()
    } else {
        masked.join(" ")
    }
}

/// Masks all but the last four characters of an identifier (IBAN, phone, TCKN).
pub fn mask_identifier(value: &str) -> String {
    let chars: Vec<char> = value.chars().filter(|c| !c.is_whitespace()).collect();
    if chars.len() <= 4 {
        return "*".repeat(chars.len());
    }
    let visible: String = chars[chars.len() - 4..].iter().collect();
    format!("{}{}", "*".repeat(chars.len() - 4), visible)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debt_notices_never_reach_group_channels() {
        for c in [
            DeliveryChannel::GroupChat,
            DeliveryChannel::NoticeBoard,
            DeliveryChannel::WhatsAppGroup,
        ] {
            assert_eq!(
                check_delivery(c, true, true, false, true),
                Err(DeliveryRefusal::GroupChannelForDebt(c.as_str()))
            );
            assert!(check_delivery(c, false, false, false, true).is_ok());
        }
        assert!(check_delivery(DeliveryChannel::Sms, true, false, false, true).is_ok());
    }

    #[test]
    fn opt_out_stops_reminders_but_not_legal_notices() {
        assert_eq!(
            check_delivery(DeliveryChannel::Sms, true, false, true, true),
            Err(DeliveryRefusal::OptedOut("SMS"))
        );
        assert!(check_delivery(DeliveryChannel::Email, true, true, true, true).is_ok());
        assert!(check_delivery(DeliveryChannel::Letter, true, false, true, false).is_ok());
        assert_eq!(
            check_delivery(DeliveryChannel::Push, true, false, false, false),
            Err(DeliveryRefusal::NoContact("PUSH"))
        );
    }

    #[test]
    fn names_and_identifiers_are_masked() {
        assert_eq!(mask_name("Ayşe Yılmaz"), "A*** Y***");
        assert_eq!(mask_name("  İsmail  "), "İ***");
        assert_eq!(mask_name(""), "***");
        assert_eq!(mask_identifier("TR33 0006 1005"), "********1005");
        assert_eq!(mask_identifier("123"), "***");
    }

    #[test]
    fn channels_round_trip() {
        for c in DeliveryChannel::ALL {
            assert_eq!(DeliveryChannel::parse(c.as_str()), Ok(c));
        }
        assert!(DeliveryChannel::parse("fax").is_err());
        assert_eq!(DeliveryChannel::parse(" sms "), Ok(DeliveryChannel::Sms));
    }
}
