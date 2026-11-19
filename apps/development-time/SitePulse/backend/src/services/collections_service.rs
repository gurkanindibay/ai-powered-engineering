//! Collections and the legal handover, SPEC-009 R8.
//!
//! A case follows `REMINDED → NOTICE_SENT → MEDIATION (verify) → LAWYER_ASSIGNED
//! → ICRA_FILED → COLLECTED | WRITTEN_OFF`; every move is an event. The evidence
//! pack (budget and decision, service record, statement, receipts, penalty
//! segments) is built only when every liability has a legal basis (İİK 68/1).
//! The lawyer reads it with a one-time token whose digest is stored; every
//! access is logged (KVKK).

use chrono::{Days, Months, NaiveDate, Utc};
use rust_decimal::Decimal;

use crate::db::finance_store::FinanceStore;
use crate::domain::limitation;
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::services::receipt_document::{try_amount, DocSection, DocTable, TextDocument};
use crate::state::{AppState, AppStateInner};

pub const LAWYER_TOKEN_DAYS: u64 = 30;
pub const KMK25_THRESHOLD: usize = 3;

fn stage(status: &str) -> Option<usize> {
    CASE_STATUSES.iter().position(|s| *s == status)
}

fn is_terminal(status: &str) -> bool {
    matches!(status, "COLLECTED" | "WRITTEN_OFF")
}

/// The legal basis of a liability, if it has one.
pub fn legal_basis(inner: &AppStateInner, due: &DuesLiability) -> Option<String> {
    if due.expense_type == ExpenseType::CapitalDues {
        let site = inner
            .units
            .iter()
            .find(|u| crate::auth::same_id(&u.id, &due.unit_id))
            .map(|u| u.site_id.clone())?;
        return inner
            .capital_projects
            .iter()
            .any(|p| crate::auth::same_id(&p.site_id, &site))
            .then(|| "Demirbaş / yatırım projesi (kat malikleri kurulu kararı)".to_string());
    }
    if let Some(share) = inner
        .finance
        .heat_shares
        .iter()
        .find(|s| s.due_id.as_deref() == Some(due.id.as_str()))
    {
        return Some(format!(
            "Isınma gideri paylaşımı #{} (yönetim planı)",
            share.period_id
        ));
    }
    let budget_id = inner.dues_budget_basis.get(&due.id)?;
    let budget = inner
        .operating_budgets
        .iter()
        .find(|b| &b.id == budget_id)?;
    Some(format!(
        "İşletme projesi {} #{} ({}{})",
        budget.fiscal_year,
        budget.id,
        budget.status,
        budget
            .assembly_decision_ref
            .as_deref()
            .map(|r| format!(", karar {}", r))
            .unwrap_or_default()
    ))
}

fn case_dues<'a>(inner: &'a AppStateInner, case: &CollectionCase) -> Vec<&'a DuesLiability> {
    inner
        .dues
        .iter()
        .filter(|d| case.due_ids.contains(&d.id))
        .collect()
}

pub fn case_view(inner: &AppStateInner, case: &CollectionCase, as_of: NaiveDate) -> CaseView {
    let dues = case_dues(inner, case);
    let two_years_ago = as_of.checked_sub_months(Months::new(24)).unwrap_or(as_of);
    let kmk25 = if case.debtor_type == "OWNER" {
        inner
            .finance
            .cases
            .iter()
            .filter(|c| crate::auth::same_id(&c.unit_id, &case.unit_id) && c.debtor_type == "OWNER")
            .flat_map(|c| {
                inner
                    .finance
                    .case_events
                    .iter()
                    .filter(move |e| e.case_id == c.id)
            })
            .filter(|e| e.to_status == "ICRA_FILED" && e.occurred_on >= two_years_ago)
            .count()
    } else {
        0
    };
    let limitation_warnings = dues
        .iter()
        .filter(|d| is_open(d))
        .filter_map(|d| {
            let status = limitation::status(d.due_date, as_of);
            (status != limitation::LimitationStatus::Running).then(|| LimitationWarning {
                due_id: d.id.clone(),
                period: d.period.clone(),
                due_date: d.due_date,
                limitation_date: limitation::limitation_date(d.due_date),
                status: status.as_str().to_string(),
            })
        })
        .collect();
    let mut events: Vec<CollectionCaseEvent> = inner
        .finance
        .case_events
        .iter()
        .filter(|e| e.case_id == case.id)
        .cloned()
        .collect();
    events.sort_by_key(|e| (e.occurred_on, e.id));
    CaseView {
        unit_label: label_of(inner, &case.unit_id),
        outstanding: dues.iter().map(|d| dues_ledger::outstanding(d)).sum(),
        evidence_ready: !dues.is_empty() && dues.iter().all(|d| legal_basis(inner, d).is_some()),
        kmk25_enforcements_in_two_years: kmk25,
        kmk25_threshold_reached: kmk25 >= KMK25_THRESHOLD,
        limitation_warnings,
        events,
        case: case.clone(),
    }
}

pub struct CollectionsService {
    state: AppState,
    store: FinanceStore,
}

impl CollectionsService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: FinanceStore::new(state),
        }
    }

    pub async fn open_case(
        &self,
        caller: &Caller,
        req: OpenCaseRequest,
    ) -> FinanceResult<CaseView> {
        let debtor = parse_debtor(req.debtor_type.as_deref())?;
        let (unit, due_ids, amount, today) = self
            .store
            .read(|inner| {
                let unit = find_unit(inner, &caller.site_id, &req.unit_id)?;
                let today = site_today(inner, &caller.site_id);
                let overdue: Vec<&DuesLiability> = inner
                    .dues
                    .iter()
                    .filter(|d| {
                        crate::auth::same_id(&d.unit_id, &unit.id)
                            && d.debtor_type.as_str() == debtor
                            && is_open(d)
                            && d.fee_due_date() < today
                    })
                    .collect();
                let chosen: Vec<&DuesLiability> = if req.due_ids.is_empty() {
                    overdue
                } else {
                    req.due_ids
                        .iter()
                        .map(|id| {
                            overdue
                                .iter()
                                .find(|d| d.id == *id || crate::auth::same_id(&d.id, id))
                                .copied()
                                .ok_or_else(|| {
                                    invalid(format!(
                                        "Liability {} is not an overdue {} item of this unit",
                                        id, debtor
                                    ))
                                })
                        })
                        .collect::<FinanceResult<_>>()?
                };
                if chosen.is_empty() {
                    return Err(conflict("The debtor has no overdue items"));
                }
                for d in &chosen {
                    if inner
                        .finance
                        .cases
                        .iter()
                        .any(|c| !is_terminal(&c.status) && c.due_ids.contains(&d.id))
                    {
                        return Err(conflict(format!(
                            "Liability {} is already in an open case",
                            d.id
                        )));
                    }
                }
                Ok((
                    unit,
                    chosen.iter().map(|d| d.id.clone()).collect::<Vec<_>>(),
                    chosen
                        .iter()
                        .map(|d| dues_ledger::outstanding(d))
                        .sum::<Decimal>(),
                    today,
                ))
            })
            .await?;
        let case = CollectionCase {
            id: 0,
            site_id: caller.site_id.clone(),
            unit_id: unit.id.clone(),
            debtor_type: debtor.to_string(),
            due_ids,
            opened_amount: amount,
            status: "REMINDED".into(),
            lawyer_name: None,
            lawyer_contact: None,
            lawyer_token_digest: None,
            lawyer_token_expires_at: None,
            opened_by: caller.actor(),
            opened_at: Utc::now(),
            closed_at: None,
            note: opt_text(&req.note),
        };
        let event = CollectionCaseEvent {
            id: 0,
            case_id: 0,
            from_status: None,
            to_status: "REMINDED".into(),
            note: Some("Takip dosyası açıldı".into()),
            actor: caller.actor(),
            occurred_on: today,
            created_at: Utc::now(),
        };
        let (case, _) = self
            .store
            .insert_with_children(case, col::cases, vec![event], col::case_events, |e, id| {
                e.case_id = id
            })
            .await?;
        Ok(self
            .store
            .read(|inner| case_view(inner, &case, today))
            .await)
    }

    pub async fn cases(&self, site_id: &str) -> Vec<CaseView> {
        self.store
            .read(|inner| {
                let today = site_today(inner, site_id);
                inner
                    .finance
                    .cases
                    .iter()
                    .filter(|c| crate::auth::same_id(&c.site_id, site_id))
                    .map(|c| case_view(inner, c, today))
                    .collect()
            })
            .await
    }

    async fn find(&self, site_id: &str, id: i64) -> FinanceResult<CollectionCase> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .cases
                    .iter()
                    .find(|c| c.id == id && crate::auth::same_id(&c.site_id, site_id))
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Collection case {} not found", id)))
    }

    pub async fn case(&self, site_id: &str, id: i64) -> FinanceResult<CaseView> {
        let case = self.find(site_id, id).await?;
        Ok(self
            .store
            .read(|inner| case_view(inner, &case, site_today(inner, site_id)))
            .await)
    }

    pub async fn advance(
        &self,
        caller: &Caller,
        id: i64,
        req: AdvanceCaseRequest,
    ) -> FinanceResult<CaseView> {
        let mut case = self.find(&caller.site_id, id).await?;
        let to = req.to_status.trim().to_ascii_uppercase();
        let (Some(from_stage), Some(to_stage)) = (stage(&case.status), stage(&to)) else {
            return Err(invalid(format!("Unknown case status '{}'", to)));
        };
        if is_terminal(&case.status) {
            return Err(conflict(format!(
                "Case {} is closed ({})",
                case.id, case.status
            )));
        }
        if !is_terminal(&to) && to_stage <= from_stage {
            return Err(conflict(format!(
                "A case moves forward: {} cannot go to {}",
                case.status, to
            )));
        }
        if to == "LAWYER_ASSIGNED" {
            case.lawyer_name = Some(non_empty(
                req.lawyer_name.as_deref().unwrap_or(""),
                3,
                "lawyer_name",
            )?);
            case.lawyer_contact = opt_text(&req.lawyer_contact);
        }
        let view = self
            .store
            .read(|inner| case_view(inner, &case, site_today(inner, &caller.site_id)))
            .await;
        if to == "ICRA_FILED" && !view.evidence_ready {
            return Err(conflict(
                "İİK 68/1: every liability needs a legal basis (operating budget or project decision) before enforcement",
            ));
        }
        let today = self
            .store
            .read(|inner| site_today(inner, &caller.site_id))
            .await;
        let event = CollectionCaseEvent {
            id: 0,
            case_id: case.id,
            from_status: Some(case.status.clone()),
            to_status: to.clone(),
            note: opt_text(&req.note),
            actor: caller.actor(),
            occurred_on: req.occurred_on.unwrap_or(today),
            created_at: Utc::now(),
        };
        self.store.insert(event, col::case_events).await?;
        case.status = to.clone();
        if is_terminal(&to) {
            case.closed_at = Some(Utc::now());
            case.lawyer_token_digest = None;
            case.lawyer_token_expires_at = None;
        }
        let case = self.store.update(case, col::cases).await?;
        Ok(self
            .store
            .read(|inner| case_view(inner, &case, today))
            .await)
    }

    pub async fn evidence_pack(&self, site_id: &str, id: i64) -> FinanceResult<EvidencePack> {
        let case = self.find(site_id, id).await?;
        self.store
            .read(|inner| {
                let today = site_today(inner, site_id);
                let unit = find_unit(inner, site_id, &case.unit_id)?;
                let calc = crate::services::DuesCalculationService::new();
                let mut items = Vec::new();
                for d in case_dues(inner, &case) {
                    let basis = legal_basis(inner, d).ok_or_else(|| {
                        conflict(format!(
                            "Liability {} ({}) has no legal basis; the evidence pack cannot be built",
                            d.id, d.period
                        ))
                    })?;
                    let accrued = calc.calculate_delay_penalty(d.clone(), today);
                    let fee_start = d.fee_due_date();
                    let recorded_through = d.penalty_accrued_through.unwrap_or(fee_start).max(fee_start);
                    let mut breakdown = Vec::new();
                    if d.delay_penalty > Decimal::ZERO {
                        breakdown.push(PenaltyDay {
                            from: fee_start,
                            to: recorded_through,
                            days: (recorded_through - fee_start).num_days(),
                            principal_base: d.principal_amount,
                            penalty: d.delay_penalty,
                        });
                    }
                    let segment = accrued.delay_penalty - d.delay_penalty.max(d.paid_penalty);
                    if segment > Decimal::ZERO {
                        breakdown.push(PenaltyDay {
                            from: recorded_through,
                            to: today,
                            days: (today - recorded_through).num_days(),
                            principal_base: dues_ledger::outstanding_principal(d),
                            penalty: segment,
                        });
                    }
                    items.push(EvidenceItem {
                        due_id: d.id.clone(),
                        period: d.period.clone(),
                        expense_type: d.expense_type.as_str().to_string(),
                        due_date: d.due_date,
                        principal: d.principal_amount,
                        paid: d.paid_principal + d.paid_penalty,
                        penalty_accrued: accrued.delay_penalty,
                        outstanding: dues_ledger::outstanding(&accrued),
                        legal_basis: basis,
                        penalty_breakdown: breakdown,
                    });
                }
                let budget = case_dues(inner, &case)
                    .iter()
                    .find_map(|d| inner.dues_budget_basis.get(&d.id))
                    .and_then(|b| inner.operating_budgets.iter().find(|x| &x.id == b))
                    .cloned();
                let service_record = budget.as_ref().and_then(|b| {
                    b.service_records
                        .iter()
                        .find(|s| crate::auth::same_id(&s.unit_id, &unit.id))
                        .cloned()
                });
                let statement = crate::services::resident_statement::build_statement(
                    inner,
                    &unit,
                    Some(case.debtor_type.as_str()),
                    today,
                );
                Ok(EvidencePack {
                    case_id: case.id,
                    site_name: site_name(inner, site_id),
                    unit_label: unit_label(inner, &unit),
                    debtor_type: case.debtor_type.clone(),
                    debtor_name: debtor_name(inner, &unit, &case.debtor_type),
                    total_outstanding: items.iter().map(|i| i.outstanding).sum(),
                    budget,
                    service_record,
                    items,
                    receipts: statement.receipts,
                    generated_at: Utc::now(),
                })
            })
            .await
    }

    pub fn evidence_document(pack: &EvidencePack) -> TextDocument {
        let mut sections = vec![DocSection {
            heading: Some("Borçlu".into()),
            rows: vec![
                ("Ad Soyad".into(), pack.debtor_name.clone()),
                ("Bağımsız bölüm".into(), pack.unit_label.clone()),
                (
                    "Sıfat".into(),
                    if pack.debtor_type == "TENANT" {
                        "Kiracı".into()
                    } else {
                        "Kat maliki".into()
                    },
                ),
                ("Toplam alacak".into(), try_amount(pack.total_outstanding)),
            ],
            ..DocSection::default()
        }];
        if let Some(ref b) = pack.budget {
            sections.push(DocSection {
                heading: Some("İşletme projesi (KMK 37)".into()),
                rows: vec![
                    (
                        "Yıl / durum".into(),
                        format!("{} / {}", b.fiscal_year, b.status),
                    ),
                    (
                        "Karar".into(),
                        b.assembly_decision_ref
                            .clone()
                            .unwrap_or_else(|| "Geçici proje (yönetici)".into()),
                    ),
                    (
                        "Karar tarihi".into(),
                        b.assembly_decision_date
                            .map(|d| d.format("%d.%m.%Y").to_string())
                            .unwrap_or_else(|| "—".into()),
                    ),
                    ("Yıllık toplam".into(), try_amount(b.total_annual_amount)),
                ],
                ..DocSection::default()
            });
        }
        if let Some(ref s) = pack.service_record {
            sections.push(DocSection {
                heading: Some("Tebliğ".into()),
                rows: vec![
                    ("Tebliğ edilen".into(), s.recipient_name.clone()),
                    ("Yöntem".into(), s.method.clone()),
                    ("Tarih".into(), s.served_on.format("%d.%m.%Y").to_string()),
                ],
                ..DocSection::default()
            });
        }
        sections.push(DocSection {
            heading: Some("Alacak kalemleri".into()),
            table: Some(DocTable {
                headers: vec![
                    "Dönem".into(),
                    "Vade".into(),
                    "Anapara".into(),
                    "Gecikme".into(),
                    "Kalan".into(),
                ],
                rows: pack
                    .items
                    .iter()
                    .map(|i| {
                        vec![
                            i.period.clone(),
                            i.due_date.format("%d.%m.%Y").to_string(),
                            try_amount(i.principal),
                            try_amount(i.penalty_accrued),
                            try_amount(i.outstanding),
                        ]
                    })
                    .collect(),
            }),
            paragraphs: pack
                .items
                .iter()
                .map(|i| format!("{}: {}", i.period, i.legal_basis))
                .collect(),
            ..DocSection::default()
        });
        sections.push(DocSection {
            heading: Some("Gecikme tazminatı dökümü (KMK 20, aylık %5)".into()),
            table: Some(DocTable {
                headers: vec![
                    "Dönem".into(),
                    "Başlangıç".into(),
                    "Bitiş".into(),
                    "Gün".into(),
                    "Tutar".into(),
                ],
                rows: pack
                    .items
                    .iter()
                    .flat_map(|i| {
                        i.penalty_breakdown.iter().map(move |p| {
                            vec![
                                i.period.clone(),
                                p.from.format("%d.%m.%Y").to_string(),
                                p.to.format("%d.%m.%Y").to_string(),
                                p.days.to_string(),
                                try_amount(p.penalty),
                            ]
                        })
                    })
                    .collect(),
            }),
            ..DocSection::default()
        });
        sections.push(DocSection {
            heading: Some("Tahsilat makbuzları".into()),
            table: Some(DocTable {
                headers: vec![
                    "Makbuz".into(),
                    "Tarih".into(),
                    "Tutar".into(),
                    "Durum".into(),
                ],
                rows: pack
                    .receipts
                    .iter()
                    .map(|r| {
                        vec![
                            r.receipt_number.clone(),
                            r.issued_at.format("%d.%m.%Y").to_string(),
                            try_amount(r.total_amount),
                            if r.reversed {
                                "İptal".into()
                            } else {
                                "Geçerli".into()
                            },
                        ]
                    })
                    .collect(),
            }),
            ..DocSection::default()
        });
        TextDocument {
            issuer: pack.site_name.clone(),
            issuer_lines: vec![format!("Takip dosyası #{}", pack.case_id)],
            title: "AVUKATA DEVİR DELİL DOSYASI".into(),
            sections,
            footer: "İİK 68/1 belgesi niteliği, arabuluculuk ön şartı ve zamanaşımı (TBK 147/1) avukat tarafından değerlendirilmelidir. KVKK: bu dosya yalnızca takip amacıyla kullanılabilir.".into(),
        }
    }

    /// Issues a read-only token for the lawyer; only its digest is kept.
    pub async fn grant_lawyer_access(
        &self,
        caller: &Caller,
        id: i64,
    ) -> FinanceResult<LawyerAccessGrant> {
        let mut case = self.find(&caller.site_id, id).await?;
        if case.lawyer_name.is_none() {
            return Err(conflict(
                "Assign a lawyer (LAWYER_ASSIGNED) before sharing the pack",
            ));
        }
        if is_terminal(&case.status) {
            return Err(conflict("The case is closed"));
        }
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let expires = Utc::now()
            .checked_add_days(Days::new(LAWYER_TOKEN_DAYS))
            .unwrap_or_else(Utc::now);
        case.lawyer_token_digest = Some(crate::auth::token_digest(&token));
        case.lawyer_token_expires_at = Some(expires);
        self.store.update(case, col::cases).await?;
        Ok(LawyerAccessGrant {
            case_id: id,
            pack_url: format!(
                "{}/api/v1/public/collection-cases/pack?token={}",
                crate::services::card_payment_service::public_base_url(),
                token
            ),
            token,
            expires_at: expires,
        })
    }

    /// The evidence pack behind a lawyer token; every access is logged.
    pub async fn pack_by_token(&self, token: &str) -> FinanceResult<EvidencePack> {
        let digest = crate::auth::token_digest(token.trim());
        let now = Utc::now();
        let case = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .cases
                    .iter()
                    .find(|c| {
                        c.lawyer_token_digest.as_deref() == Some(digest.as_str())
                            && c.lawyer_token_expires_at.is_some_and(|e| e > now)
                    })
                    .cloned()
            })
            .await
            .ok_or_else(|| FinanceError::Forbidden("The link is invalid or has expired".into()))?;
        let pack = self.evidence_pack(&case.site_id, case.id).await?;
        let lawyer = Caller {
            site_id: case.site_id.clone(),
            user_id: format!("lawyer-case-{}", case.id),
            email: case
                .lawyer_contact
                .clone()
                .unwrap_or_else(|| "lawyer".into()),
            role: Role::Auditor,
            unit_id: None,
        };
        crate::services::kvkk_service::KvkkService::new(&self.state)
            .log_access(
                &lawyer,
                ACCESS_EXPORT,
                "EVIDENCE_PACK",
                Some(&case.unit_id),
                Some(format!("case {}", case.id)),
            )
            .await?;
        Ok(pack)
    }
}
