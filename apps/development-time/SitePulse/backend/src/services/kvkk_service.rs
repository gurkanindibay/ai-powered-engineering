//! KVKK financial-data controls, SPEC-009 R2: privacy notices and their
//! acknowledgement, channel consents, the financial access log, the masked
//! debtor export and the retention policy.

use chrono::{Months, Utc};
use rust_decimal::Decimal;

use crate::db::finance_store::FinanceStore;
use crate::domain::kvkk::{mask_name, DeliveryChannel};
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::state::AppState;

/// Default retention per category, in months (verify with counsel: VUK 253 /
/// TTK 82 keep books and vouchers for 10 years; logs are kept 2 years).
pub fn default_retention_months(category: &str) -> i32 {
    match category {
        "FINANCIAL_RECORDS" | "STATEMENTS" => 120,
        "SENDER_IBANS" => 60,
        _ => 24,
    }
}

pub struct KvkkService {
    store: FinanceStore,
}

impl KvkkService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
        }
    }

    /// Writes one access-log row (VIEW, EXPORT or BLOCKED).
    pub async fn log_access(
        &self,
        caller: &Caller,
        action: &str,
        resource: &str,
        unit_id: Option<&str>,
        detail: Option<String>,
    ) -> FinanceResult<FinancialAccessLogEntry> {
        let entry = FinancialAccessLogEntry {
            id: 0,
            site_id: Some(caller.site_id.clone()).filter(|s| !s.is_empty()),
            actor: caller.actor(),
            actor_role: caller.role.as_str().to_string(),
            action: action.to_string(),
            resource: resource.to_string(),
            subject_unit_id: unit_id.map(str::to_string),
            detail,
            occurred_at: Utc::now(),
        };
        Ok(self.store.insert(entry, col::access_log).await?)
    }

    pub async fn access_log(&self, caller: &Caller, limit: usize) -> Vec<FinancialAccessLogEntry> {
        self.store
            .read(|inner| {
                let mut rows: Vec<_> = inner
                    .finance
                    .access_log
                    .iter()
                    .filter(|e| {
                        e.site_id
                            .as_deref()
                            .is_some_and(|s| crate::auth::same_id(s, &caller.site_id))
                    })
                    .cloned()
                    .collect();
                rows.sort_by_key(|a| std::cmp::Reverse(a.occurred_at));
                rows.truncate(limit.clamp(1, 1000));
                rows
            })
            .await
    }

    pub async fn publish_notice(
        &self,
        caller: &Caller,
        req: PublishPrivacyNoticeRequest,
    ) -> FinanceResult<PrivacyNotice> {
        let title = non_empty(&req.title, 3, "title")?;
        let body = non_empty(&req.body, 20, "body")?;
        let version = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .privacy_notices
                    .iter()
                    .filter(|n| crate::auth::same_id(&n.site_id, &caller.site_id))
                    .map(|n| n.version)
                    .max()
                    .unwrap_or(0)
                    + 1
            })
            .await;
        let notice = PrivacyNotice {
            id: 0,
            site_id: caller.site_id.clone(),
            version,
            title,
            body,
            published_at: Utc::now(),
            published_by: caller.actor(),
        };
        Ok(self.store.insert(notice, col::privacy_notices).await?)
    }

    async fn current_notice(&self, site_id: &str) -> Option<PrivacyNotice> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .privacy_notices
                    .iter()
                    .filter(|n| crate::auth::same_id(&n.site_id, site_id))
                    .max_by_key(|n| n.version)
                    .cloned()
            })
            .await
    }

    pub async fn status(&self, caller: &Caller) -> PrivacyStatus {
        let notice = self.current_notice(&caller.site_id).await;
        self.store
            .read(|inner| {
                let ack = notice.as_ref().and_then(|n| {
                    inner
                        .finance
                        .privacy_acknowledgements
                        .iter()
                        .find(|a| a.notice_id == n.id && a.user_ref == caller.user_id)
                });
                let consents = [
                    DeliveryChannel::Email,
                    DeliveryChannel::Sms,
                    DeliveryChannel::Push,
                    DeliveryChannel::WhatsApp,
                ]
                .into_iter()
                .map(|c| ConsentUpdate {
                    channel: c.as_str().to_string(),
                    granted: !inner.finance.consents.iter().any(|r| {
                        r.user_ref == caller.user_id && r.channel == c.as_str() && !r.granted
                    }),
                })
                .collect();
                PrivacyStatus {
                    acknowledged: ack.is_some(),
                    acknowledged_at: ack.map(|a| a.acknowledged_at),
                    current_notice: notice.clone(),
                    consents,
                }
            })
            .await
    }

    pub async fn acknowledge(&self, caller: &Caller) -> FinanceResult<PrivacyStatus> {
        let notice = self
            .current_notice(&caller.site_id)
            .await
            .ok_or_else(|| not_found("The site has not published a privacy notice yet"))?;
        let already = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .privacy_acknowledgements
                    .iter()
                    .any(|a| a.notice_id == notice.id && a.user_ref == caller.user_id)
            })
            .await;
        if !already {
            let ack = PrivacyAcknowledgement {
                id: 0,
                notice_id: notice.id,
                site_id: caller.site_id.clone(),
                user_ref: caller.user_id.clone(),
                acknowledged_at: Utc::now(),
            };
            self.store
                .insert(ack, col::privacy_acknowledgements)
                .await?;
        }
        Ok(self.status(caller).await)
    }

    pub async fn update_consents(
        &self,
        caller: &Caller,
        req: UpdateConsentsRequest,
    ) -> FinanceResult<PrivacyStatus> {
        for update in req.consents {
            let channel =
                DeliveryChannel::parse(&update.channel).map_err(|e| invalid(e.to_string()))?;
            if !channel.is_consentable() {
                return Err(invalid(format!(
                    "{} is not an electronic message channel",
                    channel.as_str()
                )));
            }
            let existing = self
                .store
                .read(|inner| {
                    inner
                        .finance
                        .consents
                        .iter()
                        .find(|c| {
                            c.user_ref == caller.user_id
                                && c.channel == channel.as_str()
                                && crate::auth::same_id(&c.site_id, &caller.site_id)
                        })
                        .cloned()
                })
                .await;
            let record = CommunicationConsent {
                id: existing.as_ref().map(|c| c.id).unwrap_or(0),
                site_id: caller.site_id.clone(),
                user_ref: caller.user_id.clone(),
                channel: channel.as_str().to_string(),
                granted: update.granted,
                updated_at: Utc::now(),
            };
            self.store.upsert(record, col::consents).await?;
        }
        Ok(self.status(caller).await)
    }

    /// Open amounts per debtor. Names are shown to site staff only; everyone
    /// else gets masked names. Writes an EXPORT row to the access log.
    pub async fn debtor_export(&self, caller: &Caller) -> FinanceResult<DebtorExport> {
        let masked = !caller.is_staff();
        let export = self
            .store
            .read(|inner| {
                let today = site_today(inner, &caller.site_id);
                let mut rows = Vec::new();
                for unit in site_units(inner, &caller.site_id) {
                    for debtor in [dues_ledger::DEBTOR_OWNER, dues_ledger::DEBTOR_TENANT] {
                        let items: Vec<&DuesLiability> = inner
                            .dues
                            .iter()
                            .filter(|d| {
                                crate::auth::same_id(&d.unit_id, &unit.id)
                                    && d.debtor_type.as_str() == debtor
                                    && is_open(d)
                            })
                            .collect();
                        if items.is_empty() {
                            continue;
                        }
                        let open: Decimal = items.iter().map(|d| dues_ledger::outstanding(d)).sum();
                        let overdue: Decimal = items
                            .iter()
                            .filter(|d| d.due_date < today)
                            .map(|d| dues_ledger::outstanding(d))
                            .sum();
                        let name = debtor_name(inner, unit, debtor);
                        rows.push(DebtorExportRow {
                            unit_label: unit_label(inner, unit),
                            debtor_type: debtor.to_string(),
                            debtor_name: if masked { mask_name(&name) } else { name },
                            open_amount: open,
                            overdue_amount: overdue,
                            oldest_due_date: items.iter().map(|d| d.due_date).min(),
                        });
                    }
                }
                rows.sort_by(|a, b| a.unit_label.cmp(&b.unit_label));
                DebtorExport {
                    site_id: caller.site_id.clone(),
                    masked,
                    generated_at: Utc::now(),
                    total_open: rows.iter().map(|r| r.open_amount).sum(),
                    rows,
                }
            })
            .await;
        self.log_access(
            caller,
            ACCESS_EXPORT,
            "DEBTOR_EXPORT",
            None,
            Some(format!("{} rows, masked={}", export.rows.len(), masked)),
        )
        .await?;
        Ok(export)
    }

    pub async fn set_retention(
        &self,
        caller: &Caller,
        req: SetRetentionPolicyRequest,
    ) -> FinanceResult<RetentionPolicy> {
        let category = RETENTION_CATEGORIES
            .into_iter()
            .find(|c| c.eq_ignore_ascii_case(req.category.trim()))
            .ok_or_else(|| invalid(format!("Unknown retention category '{}'", req.category)))?;
        if !(1..=600).contains(&req.retention_months) {
            return Err(invalid("retention_months must be between 1 and 600"));
        }
        if matches!(category, "FINANCIAL_RECORDS" | "STATEMENTS") && req.retention_months < 120 {
            return Err(conflict(
                "Books and vouchers are kept for at least 10 years (VUK 253, TTK 82; verify)",
            ));
        }
        let existing = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .retention_policies
                    .iter()
                    .find(|p| {
                        crate::auth::same_id(&p.site_id, &caller.site_id) && p.category == category
                    })
                    .map(|p| p.id)
            })
            .await;
        let record = RetentionPolicy {
            id: existing.unwrap_or(0),
            site_id: caller.site_id.clone(),
            category: category.to_string(),
            retention_months: req.retention_months,
            updated_by: caller.actor(),
            updated_at: Utc::now(),
        };
        Ok(self.store.upsert(record, col::retention_policies).await?)
    }

    /// Counts the records past retention; with `purge`, deletes the access-log
    /// and notification rows that are past it (ledger data is never purged here).
    pub async fn retention_review(
        &self,
        caller: &Caller,
        purge: bool,
    ) -> FinanceResult<RetentionReview> {
        let now = Utc::now();
        let (rows, stale_logs, stale_notifications) = self
            .store
            .read(|inner| {
                let months_of = |category: &str| {
                    inner
                        .finance
                        .retention_policies
                        .iter()
                        .find(|p| {
                            crate::auth::same_id(&p.site_id, &caller.site_id)
                                && p.category == category
                        })
                        .map(|p| p.retention_months)
                        .unwrap_or_else(|| default_retention_months(category))
                };
                let cutoff = |category: &str| {
                    let months = u32::try_from(months_of(category)).unwrap_or(24);
                    now.checked_sub_months(Months::new(months)).unwrap_or(now)
                };
                let in_site = |s: &Option<String>| {
                    s.as_deref()
                        .is_some_and(|s| crate::auth::same_id(s, &caller.site_id))
                };
                let stale_logs: Vec<i64> = inner
                    .finance
                    .access_log
                    .iter()
                    .filter(|e| in_site(&e.site_id) && e.occurred_at < cutoff("ACCESS_LOG"))
                    .map(|e| e.id)
                    .collect();
                let stale_notifications: Vec<i64> = inner
                    .finance
                    .notifications
                    .iter()
                    .filter(|n| {
                        crate::auth::same_id(&n.site_id, &caller.site_id)
                            && n.created_at < cutoff("NOTIFICATIONS")
                    })
                    .map(|n| n.id)
                    .collect();
                let receipts_past = inner
                    .payment_receipts
                    .iter()
                    .filter(|r| {
                        crate::auth::same_id(&r.site_id, &caller.site_id)
                            && r.issued_at < cutoff("FINANCIAL_RECORDS")
                    })
                    .count();
                let rows = RETENTION_CATEGORIES
                    .iter()
                    .map(|c| RetentionReviewRow {
                        category: c.to_string(),
                        retention_months: months_of(c),
                        records_past_retention: match *c {
                            "ACCESS_LOG" => stale_logs.len(),
                            "NOTIFICATIONS" => stale_notifications.len(),
                            "FINANCIAL_RECORDS" => receipts_past,
                            _ => 0,
                        },
                        purgeable: matches!(*c, "ACCESS_LOG" | "NOTIFICATIONS"),
                    })
                    .collect::<Vec<_>>();
                (rows, stale_logs, stale_notifications)
            })
            .await;
        let mut purged = 0;
        if purge {
            self.store.delete(&stale_logs, col::access_log).await?;
            self.store
                .delete(&stale_notifications, col::notifications)
                .await?;
            purged = stale_logs.len() + stale_notifications.len();
        }
        Ok(RetentionReview {
            site_id: caller.site_id.clone(),
            rows,
            purged,
        })
    }
}
