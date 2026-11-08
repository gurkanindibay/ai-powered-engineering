//! Notification delivery with a KVKK-enforcing log, SPEC-009 R4.
//!
//! Every message (sent, blocked or failed) is a row in `notifications`,
//! deduplicated per site by `dedupe_key`, so a retried job never sends twice.
//! A debt message only reaches the debtor's personal channel
//! (`domain::kvkk::check_delivery`); a refused delivery is logged as `BLOCKED`.
//!
//! The sender is a port: `LOG` records the message without contacting anyone
//! (development and tests). A real SMS, push or e-mail vendor is a new
//! [`NotificationSender`] selected with `SITEPULSE_NOTIFICATION_SENDER`.

use chrono::Utc;

use crate::db::finance_store::FinanceStore;
use crate::finance_book::col;
use crate::domain::kvkk::{check_delivery, DeliveryChannel};
use crate::models::{IndependentUnit, Notification, Role, NOTIFY_BLOCKED, NOTIFY_FAILED, NOTIFY_SENT};
use crate::services::finance_common::{debtor_user, invalid, Caller, FinanceResult};
use crate::state::AppState;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct SendError(pub String);

/// Where a message goes.
#[derive(Debug, Clone)]
pub struct Recipient {
    pub reference: String,
    pub name: String,
    pub email: Option<String>,
    pub phone: Option<String>,
    /// A signed-in app user can receive push messages.
    pub has_app: bool,
}

pub trait NotificationSender: Send + Sync {
    fn name(&self) -> &'static str;
    /// Delivers the message and returns the provider's reference.
    fn send(
        &self,
        channel: DeliveryChannel,
        to: &Recipient,
        subject: &str,
        body: &str,
    ) -> Result<String, SendError>;
}

/// Records messages without delivering them.
pub struct LogSender;

impl NotificationSender for LogSender {
    fn name(&self) -> &'static str {
        "LOG"
    }
    fn send(
        &self,
        channel: DeliveryChannel,
        to: &Recipient,
        subject: &str,
        _body: &str,
    ) -> Result<String, SendError> {
        tracing::info!(
            channel = channel.as_str(),
            recipient = %to.reference,
            "[notification] {}",
            subject
        );
        Ok(format!("LOG-{}", uuid::Uuid::new_v4().simple()))
    }
}

/// The deployment's sender. Without a real vendor, production records the
/// message as FAILED instead of pretending it was delivered.
pub fn configured_sender() -> Result<Box<dyn NotificationSender>, SendError> {
    let name = std::env::var("SITEPULSE_NOTIFICATION_SENDER").unwrap_or_else(|_| "LOG".into());
    match name.trim().to_ascii_uppercase().as_str() {
        "LOG" if !crate::state::AppStateInner::is_production() => Ok(Box::new(LogSender)),
        "LOG" => Err(SendError(
            "No notification vendor is configured for production".into(),
        )),
        other => Err(SendError(format!(
            "Notification sender '{}' is not integrated in this build",
            other
        ))),
    }
}

/// What to send.
#[derive(Debug, Clone)]
pub struct Message {
    pub site_id: String,
    pub unit_id: Option<String>,
    pub channel: DeliveryChannel,
    pub category: &'static str,
    pub subject: String,
    pub body: String,
    pub dedupe_key: String,
    /// A legal notice that does not depend on consent.
    pub mandatory: bool,
}

impl Message {
    fn carries_debt(&self) -> bool {
        matches!(
            self.category,
            "DEBT_REMINDER" | "DEBT_NOTICE" | "COLLECTION" | "AUTOPAY" | "PLAN"
        )
    }
}

pub struct NotificationService {
    store: FinanceStore,
}

impl NotificationService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
        }
    }

    /// The recipient for a unit's debtor (`OWNER` / `TENANT`).
    pub async fn debtor_recipient(&self, unit: &IndependentUnit, debtor: &str) -> Recipient {
        let found = self
            .store
            .read(|inner| debtor_user(inner, unit, debtor).cloned())
            .await;
        match found {
            Some(u) => Recipient {
                reference: u.id.clone(),
                name: u.full_name.clone(),
                email: Some(u.email.clone()).filter(|e| !e.trim().is_empty()),
                phone: Some(u.phone.clone()).filter(|p| !p.trim().is_empty()),
                has_app: true,
            },
            None => Recipient {
                reference: format!("unit:{}:{}", unit.id, debtor),
                name: if debtor == "TENANT" {
                    "Kiracı".into()
                } else {
                    "Kat Maliki".into()
                },
                email: None,
                phone: None,
                has_app: false,
            },
        }
    }

    /// Sends (or blocks) one message and returns its log row. A message with
    /// the same `dedupe_key` is returned as it was, without sending again.
    pub async fn deliver(&self, message: Message, to: &Recipient) -> FinanceResult<Notification> {
        if message.dedupe_key.trim().is_empty() {
            return Err(invalid("A notification needs a dedupe key"));
        }
        let existing = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .notifications
                    .iter()
                    .find(|n| {
                        crate::auth::same_id(&n.site_id, &message.site_id)
                            && n.dedupe_key == message.dedupe_key
                    })
                    .cloned()
            })
            .await;
        if let Some(n) = existing {
            return Ok(n);
        }
        let opted_out = self
            .store
            .read(|inner| {
                inner.finance.consents.iter().any(|c| {
                    c.user_ref == to.reference
                        && c.channel == message.channel.as_str()
                        && !c.granted
                })
            })
            .await;
        let has_contact = match message.channel {
            DeliveryChannel::Email => to.email.is_some(),
            DeliveryChannel::Sms | DeliveryChannel::WhatsApp => to.phone.is_some(),
            DeliveryChannel::Push => to.has_app,
            _ => true,
        };
        let now = Utc::now();
        let mut row = Notification {
            id: 0,
            site_id: message.site_id.clone(),
            unit_id: message.unit_id.clone(),
            recipient_ref: to.reference.clone(),
            recipient_name: to.name.clone(),
            channel: message.channel.as_str().to_string(),
            category: message.category.to_string(),
            subject: message.subject.clone(),
            body: message.body.clone(),
            status: NOTIFY_SENT.to_string(),
            block_reason: None,
            provider_ref: None,
            dedupe_key: message.dedupe_key.clone(),
            created_at: now,
            sent_at: None,
        };
        match check_delivery(
            message.channel,
            message.carries_debt(),
            message.mandatory,
            opted_out,
            has_contact,
        ) {
            Err(refusal) => {
                row.status = NOTIFY_BLOCKED.to_string();
                row.block_reason = Some(refusal.to_string());
            }
            Ok(()) => match configured_sender()
                .and_then(|s| s.send(message.channel, to, &message.subject, &message.body))
            {
                Ok(reference) => {
                    row.provider_ref = Some(reference);
                    row.sent_at = Some(now);
                }
                Err(e) => {
                    row.status = NOTIFY_FAILED.to_string();
                    row.block_reason = Some(e.to_string());
                }
            },
        }
        Ok(self
            .store
            .insert(row, col::notifications)
            .await?)
    }

    /// E-mails every site manager (not personal data about a debtor).
    pub async fn notify_staff(
        &self,
        site_id: &str,
        category: &'static str,
        subject: &str,
        body: &str,
        dedupe_key: &str,
    ) -> FinanceResult<Vec<Notification>> {
        let managers: Vec<Recipient> = self
            .store
            .read(|inner| {
                inner
                    .users
                    .iter()
                    .filter(|u| {
                        u.role == Role::SiteManager && crate::auth::same_id(&u.site_id, site_id)
                    })
                    .map(|u| Recipient {
                        reference: u.id.clone(),
                        name: u.full_name.clone(),
                        email: Some(u.email.clone()),
                        phone: Some(u.phone.clone()).filter(|p| !p.is_empty()),
                        has_app: true,
                    })
                    .collect()
            })
            .await;
        let mut out = Vec::new();
        for m in managers {
            let message = Message {
                site_id: site_id.to_string(),
                unit_id: None,
                channel: DeliveryChannel::Email,
                category,
                subject: subject.to_string(),
                body: body.to_string(),
                dedupe_key: format!("{}:{}", dedupe_key, m.reference),
                mandatory: true,
            };
            out.push(self.deliver(message, &m).await?);
        }
        Ok(out)
    }

    /// A site-wide announcement. A debt category on a group channel is refused
    /// and logged (KVKK 2026/348).
    pub async fn broadcast(
        &self,
        caller: &Caller,
        channel: &str,
        category: &str,
        subject: &str,
        body: &str,
    ) -> FinanceResult<Notification> {
        let channel = DeliveryChannel::parse(channel).map_err(|e| invalid(e.to_string()))?;
        let category = crate::models::NOTIFICATION_CATEGORIES
            .into_iter()
            .find(|c| c.eq_ignore_ascii_case(category.trim()))
            .ok_or_else(|| invalid(format!("Unknown notification category '{}'", category)))?;
        let to = Recipient {
            reference: format!("site:{}:all", caller.site_id),
            name: "Tüm sakinler".into(),
            email: None,
            phone: None,
            has_app: true,
        };
        let message = Message {
            site_id: caller.site_id.clone(),
            unit_id: None,
            channel,
            category,
            subject: subject.trim().to_string(),
            body: body.trim().to_string(),
            dedupe_key: format!("broadcast:{}", uuid::Uuid::new_v4().simple()),
            mandatory: false,
        };
        self.deliver(message, &to).await
    }

    /// Staff see the site's log; a resident sees the messages addressed to them.
    pub async fn list(&self, caller: &Caller, limit: usize) -> Vec<Notification> {
        self.store
            .read(|inner| {
                let mut rows: Vec<Notification> = inner
                    .finance
                    .notifications
                    .iter()
                    .filter(|n| crate::auth::same_id(&n.site_id, &caller.site_id))
                    .filter(|n| {
                        caller.is_staff()
                            || caller.is_auditor() && n.category == "SYSTEM"
                            || crate::auth::same_id(&n.recipient_ref, &caller.user_id)
                    })
                    .cloned()
                    .collect();
                rows.sort_by(|a, b| b.created_at.cmp(&a.created_at));
                rows.truncate(limit.clamp(1, 500));
                rows
            })
            .await
    }
}

