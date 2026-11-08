//! Dunning schedule per site, SPEC-009 R4.
//!
//! The daily run looks at every overdue liability and executes the step of the
//! site's policy that is due (`domain::dunning::step_due`), once per liability
//! and step. A liability that is disputed, inside an active payment plan, or in
//! a collection case past `NOTICE_SENT` is paused: the lawyer or the plan
//! governs it, and reminders would contradict them.

use chrono::{NaiveDate, Utc};

use crate::db::finance_store::FinanceStore;
use crate::domain::dunning::{default_steps, step_due, validate_steps, DunningKind, DunningStep};
use crate::domain::kvkk::DeliveryChannel;
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::services::notification_service::{Message, NotificationService};
use crate::services::receipt_document::{try_amount, DocSection, TextDocument};
use crate::state::{AppState, AppStateInner};

fn to_domain(steps: &[DunningStepDto]) -> FinanceResult<Vec<DunningStep>> {
    steps
        .iter()
        .map(|s| {
            Ok(DunningStep {
                day_offset: s.day_offset,
                channel: DeliveryChannel::parse(&s.channel).map_err(|e| invalid(e.to_string()))?,
                kind: DunningKind::parse(&s.kind).map_err(|e| invalid(e.to_string()))?,
            })
        })
        .collect()
}

fn to_dto(steps: &[DunningStep]) -> Vec<DunningStepDto> {
    steps
        .iter()
        .map(|s| DunningStepDto {
            day_offset: s.day_offset,
            channel: s.channel.as_str().to_string(),
            kind: s.kind.as_str().to_string(),
        })
        .collect()
}

/// Whether reminders on a liability are paused, and why.
pub fn pause_reason(inner: &AppStateInner, due: &DuesLiability) -> Option<&'static str> {
    let book = &inner.finance;
    if book
        .disputes
        .iter()
        .any(|d| d.due_id == due.id && d.status == DISPUTE_OPEN)
    {
        return Some("disputed");
    }
    if book
        .plans
        .iter()
        .any(|p| p.status == PLAN_ACTIVE && p.due_ids.contains(&due.id))
    {
        return Some("in an active payment plan");
    }
    if book.cases.iter().any(|c| {
        c.due_ids.contains(&due.id)
            && matches!(
                c.status.as_str(),
                "MEDIATION" | "LAWYER_ASSIGNED" | "ICRA_FILED"
            )
    }) {
        return Some("with the lawyer");
    }
    None
}

pub struct DunningService {
    state: AppState,
    store: FinanceStore,
}

impl DunningService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: FinanceStore::new(state),
        }
    }

    /// The site's policy, or the default schedule (not stored until changed).
    pub async fn policy(&self, site_id: &str) -> DunningPolicy {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .dunning_policies
                    .iter()
                    .find(|p| crate::auth::same_id(&p.site_id, site_id))
                    .cloned()
            })
            .await
            .unwrap_or_else(|| DunningPolicy {
                id: 0,
                site_id: site_id.to_string(),
                enabled: true,
                steps: to_dto(&default_steps()),
                updated_by: "default".into(),
                updated_at: Utc::now(),
            })
    }

    pub async fn set_policy(
        &self,
        caller: &Caller,
        req: SetDunningPolicyRequest,
    ) -> FinanceResult<DunningPolicy> {
        let steps = to_domain(&req.steps)?;
        validate_steps(&steps).map_err(|e| invalid(e.to_string()))?;
        let mut policy = self.policy(&caller.site_id).await;
        policy.site_id = caller.site_id.clone();
        policy.enabled = req.enabled;
        policy.steps = to_dto(&steps);
        policy.updated_by = caller.actor();
        policy.updated_at = Utc::now();
        Ok(self.store.upsert(policy, col::dunning_policies).await?)
    }

    pub async fn actions(&self, site_id: &str) -> Vec<DunningAction> {
        self.store
            .read(|inner| {
                let mut rows: Vec<_> = inner
                    .finance
                    .dunning_actions
                    .iter()
                    .filter(|a| crate::auth::same_id(&a.site_id, site_id))
                    .cloned()
                    .collect();
                rows.sort_by(|a, b| b.executed_on.cmp(&a.executed_on).then(b.id.cmp(&a.id)));
                rows
            })
            .await
    }

    /// Executes the due step of every overdue liability of the site, once.
    pub async fn run(
        &self,
        site_id: &str,
        as_of: Option<NaiveDate>,
    ) -> FinanceResult<DunningRunReport> {
        let policy = self.policy(site_id).await;
        let as_of = match as_of {
            Some(d) => d,
            None => self.store.read(|inner| site_today(inner, site_id)).await,
        };
        let mut report = DunningRunReport {
            site_id: site_id.to_string(),
            as_of: Some(as_of),
            ..DunningRunReport::default()
        };
        if !policy.enabled {
            return Ok(report);
        }
        let steps = to_domain(&policy.steps)?;
        // (liability, unit, step index) to execute, decided under one read lock.
        let work = self
            .store
            .read(|inner| {
                let mut work = Vec::new();
                for due in site_dues(inner, site_id).filter(|d| is_open(d) && d.due_date < as_of) {
                    report.examined += 1;
                    if pause_reason(inner, due).is_some() {
                        report.paused += 1;
                        continue;
                    }
                    let executed: Vec<usize> = inner
                        .finance
                        .dunning_actions
                        .iter()
                        .filter(|a| a.due_id == due.id)
                        .filter_map(|a| usize::try_from(a.step_index).ok())
                        .collect();
                    let days = (as_of - due.due_date).num_days();
                    if let Some(step) = step_due(&steps, days, &executed) {
                        if let Some(unit) = inner
                            .units
                            .iter()
                            .find(|u| crate::auth::same_id(&u.id, &due.unit_id))
                        {
                            work.push((due.clone(), unit.clone(), step, unit_label(inner, unit)));
                        }
                    }
                }
                work
            })
            .await;
        let notifier = NotificationService::new(&self.state);
        for (due, unit, index, label) in work {
            let step = steps[index];
            let outstanding = dues_ledger::outstanding(&due);
            let (category, subject, body) = match step.kind {
                DunningKind::Reminder => (
                    "DEBT_REMINDER",
                    format!("Ödeme hatırlatması: {}", due.period),
                    format!(
                        "{} için {} dönemine ait ₺{} tutarındaki borcunuzun son ödeme tarihi {} idi. Ödemenizi uygulamadan veya sanal IBAN'ınıza havale ile yapabilirsiniz.",
                        label, due.period, crate::services::receipt_document::format_try(outstanding), due.due_date.format("%d.%m.%Y")
                    ),
                ),
                DunningKind::WrittenWarning => (
                    "DEBT_NOTICE",
                    format!("Yazılı uyarı: {} borcu", due.period),
                    format!(
                        "{} için {} dönemine ait ₺{} borç {} gündür ödenmemiştir. KMK 20 uyarınca aylık %5 gecikme tazminatı işlemektedir. Ödeme yapılmazsa yasal yollara başvurulacaktır.",
                        label, due.period, crate::services::receipt_document::format_try(outstanding), (as_of - due.due_date).num_days()
                    ),
                ),
                DunningKind::Ihtarname => (
                    "DEBT_NOTICE",
                    format!("İhtarname: {} borcu", due.period),
                    format!(
                        "{} için ihtarname taslağı hazırlandı (GET /api/v1/dunning/notice-letter/{}). Taslak noter veya iadeli taahhütlü posta ile gönderilmelidir.",
                        label, due.id
                    ),
                ),
            };
            let to = notifier
                .debtor_recipient(&unit, due.debtor_type.as_str())
                .await;
            let note = notifier
                .deliver(
                    Message {
                        site_id: site_id.to_string(),
                        unit_id: Some(unit.id.clone()),
                        channel: step.channel,
                        category,
                        subject,
                        body,
                        dedupe_key: format!("dunning:{}:{}", due.id, index),
                        mandatory: step.kind.is_mandatory(),
                    },
                    &to,
                )
                .await?;
            match note.status.as_str() {
                NOTIFY_SENT => report.sent += 1,
                NOTIFY_BLOCKED => report.blocked += 1,
                _ => report.failed += 1,
            }
            let action = DunningAction {
                id: 0,
                site_id: site_id.to_string(),
                due_id: due.id.clone(),
                step_index: i32::try_from(index).unwrap_or(i32::MAX),
                kind: step.kind.as_str().to_string(),
                channel: step.channel.as_str().to_string(),
                notification_id: Some(note.id),
                executed_on: as_of,
                outcome: note.status.clone(),
            };
            report
                .actions
                .push(self.store.insert(action, col::dunning_actions).await?);
        }
        Ok(report)
    }

    /// Runs every site (the scheduler's daily job).
    pub async fn run_all(&self) -> usize {
        let sites: Vec<String> = self
            .store
            .read(|inner| inner.sites.iter().map(|s| s.id.clone()).collect())
            .await;
        let mut executed = 0;
        for site in sites {
            match self.run(&site, None).await {
                Ok(r) => executed += r.actions.len(),
                Err(e) => tracing::error!("[Dunning] site {}: {}", site, e),
            }
        }
        executed
    }

    /// The ihtarname draft for a liability (to be sent by a notary or registered mail).
    pub async fn notice_letter(&self, site_id: &str, due_id: &str) -> FinanceResult<TextDocument> {
        self.store
            .read(|inner| {
                let due = find_due(inner, site_id, due_id)?;
                let unit = find_unit(inner, site_id, &due.unit_id)?;
                let today = site_today(inner, site_id);
                let calc = crate::services::DuesCalculationService::new();
                let accrued = calc.calculate_delay_penalty(due.clone(), today);
                let principal = dues_ledger::outstanding_principal(&accrued);
                let penalty = dues_ledger::outstanding_penalty(&accrued);
                let site = inner.sites.iter().find(|s| crate::auth::same_id(&s.id, site_id));
                let basis = inner
                    .dues_budget_basis
                    .get(&due.id)
                    .map(|b| format!("İşletme projesi #{} (KMK 37)", b))
                    .unwrap_or_else(|| "Yönetim planı ve kat malikleri kurulu kararı".into());
                Ok(TextDocument {
                    issuer: site.map(|s| s.name.clone()).unwrap_or_else(|| "Site Yönetimi".into()),
                    issuer_lines: site
                        .map(|s| vec![s.address.clone()])
                        .unwrap_or_default(),
                    title: "İHTARNAME (TASLAK)".into(),
                    sections: vec![
                        DocSection {
                            heading: Some("Muhatap".into()),
                            rows: vec![
                                ("Ad Soyad".into(), debtor_name(inner, &unit, due.debtor_type.as_str())),
                                ("Bağımsız bölüm".into(), unit_label(inner, &unit)),
                                ("Sıfat".into(), if due.debtor_type == DebtorType::Tenant { "Kiracı".into() } else { "Kat maliki".into() }),
                            ],
                            ..DocSection::default()
                        },
                        DocSection {
                            heading: Some("Borç".into()),
                            rows: vec![
                                ("Dönem".into(), due.period.clone()),
                                ("Son ödeme tarihi".into(), due.due_date.format("%d.%m.%Y").to_string()),
                                ("Ödenmemiş anapara".into(), try_amount(principal)),
                                (format!("Gecikme tazminatı ({} itibarıyla)", today.format("%d.%m.%Y")), try_amount(penalty)),
                                ("Toplam".into(), try_amount(principal + penalty)),
                                ("Hukuki dayanak".into(), basis),
                            ],
                            ..DocSection::default()
                        },
                        DocSection {
                            heading: Some("İhtar".into()),
                            paragraphs: vec![
                                "Yukarıda dökümü verilen ortak gider ve avans borcunuzu bu ihtarnamenin tebliğinden itibaren 7 gün içinde site yönetiminin hesabına ödemenizi; aksi halde 634 sayılı Kat Mülkiyeti Kanunu'nun 20. maddesi uyarınca aylık %5 gecikme tazminatı ile birlikte icra takibi ve dava yoluna başvurulacağını, doğacak tüm masrafların tarafınıza ait olacağını ihtar ederiz. (Arabuluculuk ön şartı ve süreler avukat tarafından teyit edilmelidir.)".to_string()
                            ],
                            ..DocSection::default()
                        },
                    ],
                    footer: "Bu belge SitePulse tarafından taslak olarak üretilmiştir; noter veya iadeli taahhütlü posta ile tebliğ edilmeden hukuki sonuç doğurmaz.".into(),
                })
            })
            .await
    }
}
