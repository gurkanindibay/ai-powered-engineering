//! Payment plans (yapılandırma), penalty waivers and write-offs, SPEC-009 R10.
//!
//! * A waiver or write-off is requested by one person and approved by another
//!   (four-eyes). The approval lowers what the liability owes; the adjustment row
//!   with the amounts before is the audit record.
//! * A plan spreads open debts over equal instalments. Payments still go through
//!   the normal ingestion path against the original liabilities; the plan only
//!   tracks whether they keep up. A late instalment past the grace days breaks
//!   the plan (dunning resumes); a completed plan may waive the penalty accrued.

use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;

use crate::db::finance_store::FinanceStore;
use crate::domain::installments::{self, ScheduledInstallment};
use crate::domain::kvkk::DeliveryChannel;
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::services::notification_service::{Message, NotificationService};
use crate::state::{AppState, AppStateInner};

/// Principal and penalty paid on `due_ids` by receipts issued on or after `since`
/// (reversals subtract what they reversed).
pub fn paid_since(
    inner: &AppStateInner,
    site_id: &str,
    due_ids: &[String],
    since: NaiveDate,
) -> Decimal {
    inner
        .payment_receipts
        .iter()
        .filter(|r| {
            crate::auth::same_id(&r.site_id, site_id)
                && local_date(inner, site_id, r.issued_at) >= since
        })
        .flat_map(|r| {
            let sign = if r.receipt_type == LEDGER_KIND_REVERSAL {
                Decimal::NEGATIVE_ONE
            } else {
                Decimal::ONE
            };
            r.allocation_breakdown
                .iter()
                .filter(|i| i.due_id.as_ref().is_some_and(|d| due_ids.contains(d)))
                .map(move |i| sign * (i.principal_paid + i.penalty_paid))
        })
        .sum::<Decimal>()
        .max(Decimal::ZERO)
}

fn schedule_of(inner: &AppStateInner, plan_id: i64) -> Vec<ScheduledInstallment> {
    let mut rows: Vec<ScheduledInstallment> = inner
        .finance
        .plan_installments
        .iter()
        .filter(|i| i.plan_id == plan_id)
        .map(|i| ScheduledInstallment {
            seq: u32::try_from(i.seq).unwrap_or(0),
            due_date: i.due_date,
            amount: i.amount,
        })
        .collect();
    rows.sort_by_key(|i| i.seq);
    rows
}

pub fn plan_view(inner: &AppStateInner, plan: &PaymentPlan, as_of: NaiveDate) -> PaymentPlanView {
    let schedule = schedule_of(inner, plan.id);
    let paid = paid_since(inner, &plan.site_id, &plan.due_ids, plan.opened_on);
    let progress = installments::evaluate(
        &schedule,
        paid,
        as_of,
        u32::try_from(plan.grace_days).unwrap_or(0),
    );
    PaymentPlanView {
        plan: plan.clone(),
        unit_label: label_of(inner, &plan.unit_id),
        paid,
        required_to_date: progress.required_to_date,
        installments: progress
            .installments
            .into_iter()
            .map(|i| PlanInstallmentView {
                seq: i.seq,
                due_date: i.due_date,
                amount: i.amount,
                covered: i.covered,
                status: i.status.to_string(),
            })
            .collect(),
    }
}

pub struct PlanService {
    state: AppState,
    store: FinanceStore,
}

impl PlanService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: FinanceStore::new(state),
        }
    }

    // -----------------------------------------------------------------------
    // Adjustments
    // -----------------------------------------------------------------------

    pub async fn request_adjustment(
        &self,
        caller: &Caller,
        req: RequestAdjustmentRequest,
        source: &str,
    ) -> FinanceResult<LedgerAdjustment> {
        let reason = non_empty(&req.reason, 5, "reason")?;
        let kind = match req.kind.trim().to_ascii_uppercase().as_str() {
            ADJUSTMENT_PENALTY_WAIVER => ADJUSTMENT_PENALTY_WAIVER,
            ADJUSTMENT_WRITE_OFF => ADJUSTMENT_WRITE_OFF,
            other => return Err(invalid(format!("Unknown adjustment kind '{}'", other))),
        };
        let due = self
            .store
            .read(|inner| find_due(inner, &caller.site_id, &req.due_id).cloned())
            .await?;
        let open = if kind == ADJUSTMENT_PENALTY_WAIVER {
            dues_ledger::outstanding_penalty(&due)
        } else {
            dues_ledger::outstanding_principal(&due)
        };
        let amount = req.amount.unwrap_or(open);
        money(amount, "amount")?;
        if amount > open {
            return Err(conflict(format!(
                "Only ₺{:.2} is outstanding for a {}",
                open,
                kind.to_lowercase()
            )));
        }
        let adjustment = LedgerAdjustment {
            id: 0,
            site_id: caller.site_id.clone(),
            unit_id: due.unit_id.clone(),
            due_id: due.id.clone(),
            kind: kind.to_string(),
            amount,
            reason,
            source: source.to_string(),
            requested_by: caller.actor(),
            requested_at: Utc::now(),
            status: REQUEST_PENDING.to_string(),
            decided_by: None,
            decided_at: None,
            decision_note: None,
            principal_before: None,
            penalty_before: None,
        };
        Ok(self.store.insert(adjustment, col::adjustments).await?)
    }

    pub async fn adjustments(&self, site_id: &str) -> Vec<LedgerAdjustment> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .adjustments
                    .iter()
                    .filter(|a| crate::auth::same_id(&a.site_id, site_id))
                    .cloned()
                    .collect()
            })
            .await
    }

    /// Approves (lowering what the liability owes) or rejects a pending adjustment.
    pub async fn decide_adjustment(
        &self,
        caller: &Caller,
        adjustment_id: i64,
        decision: DecideRequest,
    ) -> FinanceResult<LedgerAdjustment> {
        let mut adj = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .adjustments
                    .iter()
                    .find(|a| {
                        a.id == adjustment_id && crate::auth::same_id(&a.site_id, &caller.site_id)
                    })
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Adjustment {} not found", adjustment_id)))?;
        if adj.status != REQUEST_PENDING {
            return Err(conflict(format!(
                "Adjustment {} is already {}",
                adj.id, adj.status
            )));
        }
        if same_actor(&adj.requested_by, &caller.actor()) {
            return Err(FinanceError::Forbidden(
                "The approver must be a different person from the requester (four-eyes)".into(),
            ));
        }
        if decision.approve {
            self.apply(&mut adj).await?;
            adj.status = REQUEST_APPROVED.to_string();
        } else {
            adj.status = REQUEST_REJECTED.to_string();
        }
        adj.decided_by = Some(caller.actor());
        adj.decided_at = Some(Utc::now());
        adj.decision_note = opt_text(&decision.note);
        Ok(self.store.update(adj, col::adjustments).await?)
    }

    async fn apply(&self, adj: &mut LedgerAdjustment) -> FinanceResult<()> {
        let due = self
            .store
            .read(|inner| find_due(inner, &adj.site_id, &adj.due_id).cloned())
            .await?;
        let (mut principal, mut penalty) = (due.principal_amount, due.delay_penalty);
        if adj.kind == ADJUSTMENT_PENALTY_WAIVER {
            if adj.amount > dues_ledger::outstanding_penalty(&due) {
                return Err(conflict(
                    "The penalty was paid in the meantime; nothing left to waive",
                ));
            }
            penalty -= adj.amount;
        } else {
            if adj.amount > dues_ledger::outstanding_principal(&due) {
                return Err(conflict(
                    "The principal was paid in the meantime; nothing left to write off",
                ));
            }
            principal -= adj.amount;
        }
        adj.principal_before = Some(due.principal_amount);
        adj.penalty_before = Some(due.delay_penalty);
        self.store
            .apply_due_adjustment(&due.id, principal, penalty)
            .await?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Plans
    // -----------------------------------------------------------------------

    pub async fn create_plan(
        &self,
        caller: &Caller,
        req: CreatePaymentPlanRequest,
    ) -> FinanceResult<PaymentPlanView> {
        let debtor = parse_debtor(req.debtor_type.as_deref())?;
        let grace = req.grace_days.unwrap_or(10);
        if !(0..=60).contains(&grace) {
            return Err(invalid("grace_days must be between 0 and 60"));
        }
        let count = u32::try_from(req.installment_count)
            .map_err(|_| invalid("installment_count must be positive"))?;
        let (unit, due_ids, total, approver) = self
            .store
            .read(|inner| {
                let unit = find_unit(inner, &caller.site_id, &req.unit_id)?;
                let approver = inner
                    .users
                    .iter()
                    .find(|u| {
                        crate::auth::same_id(&u.id, req.approved_by.trim())
                            && crate::auth::same_id(&u.site_id, &caller.site_id)
                            && matches!(u.role, Role::SiteManager | Role::Auditor)
                    })
                    .ok_or_else(|| {
                        invalid(
                            "approved_by must be another site manager or the auditor of this site",
                        )
                    })?;
                if crate::auth::same_id(&approver.id, &caller.user_id) {
                    return Err(FinanceError::Forbidden(
                        "A plan is approved by a second person (four-eyes)".into(),
                    ));
                }
                let candidates: Vec<&DuesLiability> = inner
                    .dues
                    .iter()
                    .filter(|d| {
                        crate::auth::same_id(&d.unit_id, &unit.id)
                            && d.debtor_type.as_str() == debtor
                            && is_open(d)
                    })
                    .collect();
                let chosen: Vec<&DuesLiability> = if req.due_ids.is_empty() {
                    candidates
                } else {
                    req.due_ids
                        .iter()
                        .map(|id| {
                            candidates
                                .iter()
                                .find(|d| d.id == *id || crate::auth::same_id(&d.id, id))
                                .copied()
                                .ok_or_else(|| {
                                    invalid(format!(
                                        "Liability {} is not an open {} item of this unit",
                                        id, debtor
                                    ))
                                })
                        })
                        .collect::<FinanceResult<_>>()?
                };
                if chosen.is_empty() {
                    return Err(conflict("The debtor has no open items to restructure"));
                }
                for d in &chosen {
                    if inner
                        .finance
                        .plans
                        .iter()
                        .any(|p| p.status == PLAN_ACTIVE && p.due_ids.contains(&d.id))
                    {
                        return Err(conflict(format!(
                            "Liability {} is already in an active plan",
                            d.id
                        )));
                    }
                }
                let total: Decimal = chosen.iter().map(|d| dues_ledger::outstanding(d)).sum();
                let ids: Vec<String> = chosen.iter().map(|d| d.id.clone()).collect();
                Ok((
                    unit,
                    ids,
                    total,
                    format!("user:{} <{}>", approver.id, approver.email),
                ))
            })
            .await?;
        let schedule = installments::schedule(total, count, req.first_due_date)
            .map_err(|e| invalid(e.to_string()))?;
        let today = self
            .store
            .read(|inner| site_today(inner, &caller.site_id))
            .await;
        let plan = PaymentPlan {
            id: 0,
            site_id: caller.site_id.clone(),
            unit_id: unit.id.clone(),
            debtor_type: debtor.to_string(),
            due_ids,
            total_amount: total,
            installment_count: req.installment_count,
            first_due_date: req.first_due_date,
            grace_days: grace,
            waive_penalty_on_completion: req.waive_penalty_on_completion,
            status: PLAN_ACTIVE.to_string(),
            opened_on: today,
            created_by: caller.actor(),
            approved_by: approver,
            closed_on: None,
            note: opt_text(&req.note),
        };
        let rows: Vec<PaymentPlanInstallment> = schedule
            .iter()
            .map(|s| PaymentPlanInstallment {
                id: 0,
                plan_id: 0,
                seq: i32::try_from(s.seq).unwrap_or(0),
                due_date: s.due_date,
                amount: s.amount,
            })
            .collect();
        let (plan, _) = self
            .store
            .insert_with_children(plan, col::plans, rows, col::plan_installments, |c, id| {
                c.plan_id = id
            })
            .await?;
        Ok(self
            .store
            .read(|inner| plan_view(inner, &plan, today))
            .await)
    }

    pub async fn plans(&self, site_id: &str, unit_id: Option<&str>) -> Vec<PaymentPlanView> {
        self.store
            .read(|inner| {
                let today = site_today(inner, site_id);
                inner
                    .finance
                    .plans
                    .iter()
                    .filter(|p| crate::auth::same_id(&p.site_id, site_id))
                    .filter(|p| unit_id.is_none_or(|u| crate::auth::same_id(&p.unit_id, u)))
                    .map(|p| plan_view(inner, p, today))
                    .collect()
            })
            .await
    }

    pub async fn cancel_plan(&self, caller: &Caller, plan_id: i64) -> FinanceResult<PaymentPlan> {
        let mut plan = self.find_plan(&caller.site_id, plan_id).await?;
        if plan.status != PLAN_ACTIVE {
            return Err(conflict(format!("Plan {} is {}", plan.id, plan.status)));
        }
        plan.status = PLAN_CANCELLED.to_string();
        plan.closed_on = Some(self.store.read(|i| site_today(i, &caller.site_id)).await);
        Ok(self.store.update(plan, col::plans).await?)
    }

    async fn find_plan(&self, site_id: &str, plan_id: i64) -> FinanceResult<PaymentPlan> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .plans
                    .iter()
                    .find(|p| p.id == plan_id && crate::auth::same_id(&p.site_id, site_id))
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Payment plan {} not found", plan_id)))
    }

    /// Completes kept plans and breaks the late ones (daily job).
    pub async fn run(
        &self,
        site_id: &str,
        as_of: Option<NaiveDate>,
    ) -> FinanceResult<PlanRunReport> {
        let as_of = match as_of {
            Some(d) => d,
            None => self.store.read(|inner| site_today(inner, site_id)).await,
        };
        let evaluated: Vec<(PaymentPlan, bool, bool)> = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .plans
                    .iter()
                    .filter(|p| {
                        p.status == PLAN_ACTIVE && crate::auth::same_id(&p.site_id, site_id)
                    })
                    .map(|p| {
                        let schedule = schedule_of(inner, p.id);
                        let paid = paid_since(inner, site_id, &p.due_ids, p.opened_on);
                        let progress = installments::evaluate(
                            &schedule,
                            paid,
                            as_of,
                            u32::try_from(p.grace_days).unwrap_or(0),
                        );
                        let all_settled = p.due_ids.iter().all(|id| {
                            inner
                                .dues
                                .iter()
                                .find(|d| d.id == *id)
                                .is_none_or(|d| !is_open(d))
                        });
                        (
                            p.clone(),
                            progress.completed || all_settled,
                            progress.broken,
                        )
                    })
                    .collect()
            })
            .await;
        let mut report = PlanRunReport {
            completed: Vec::new(),
            broken: Vec::new(),
        };
        for (mut plan, completed, broken) in evaluated {
            if completed {
                plan.status = PLAN_COMPLETED.to_string();
                plan.closed_on = Some(as_of);
                if plan.waive_penalty_on_completion {
                    self.waive_plan_penalties(&plan).await?;
                }
                report.completed.push(plan.id);
            } else if broken {
                plan.status = PLAN_BROKEN.to_string();
                plan.closed_on = Some(as_of);
                report.broken.push(plan.id);
                self.notify_broken(&plan).await?;
            } else {
                continue;
            }
            self.store.update(plan, col::plans).await?;
        }
        Ok(report)
    }

    /// The approver of the plan already agreed to the waiver: it is recorded as
    /// approved by them, requested by the plan's creator.
    async fn waive_plan_penalties(&self, plan: &PaymentPlan) -> FinanceResult<()> {
        let dues: Vec<DuesLiability> = self
            .store
            .read(|inner| {
                inner
                    .dues
                    .iter()
                    .filter(|d| {
                        plan.due_ids.contains(&d.id)
                            && dues_ledger::outstanding_penalty(d) > Decimal::ZERO
                    })
                    .cloned()
                    .collect()
            })
            .await;
        for due in dues {
            let mut adj = LedgerAdjustment {
                id: 0,
                site_id: plan.site_id.clone(),
                unit_id: plan.unit_id.clone(),
                due_id: due.id.clone(),
                kind: ADJUSTMENT_PENALTY_WAIVER.to_string(),
                amount: dues_ledger::outstanding_penalty(&due),
                reason: format!(
                    "Ödeme planı #{} tamamlandı: gecikme tazminatından vazgeçildi",
                    plan.id
                ),
                source: "PAYMENT_PLAN".to_string(),
                requested_by: plan.created_by.clone(),
                requested_at: Utc::now(),
                status: REQUEST_APPROVED.to_string(),
                decided_by: Some(plan.approved_by.clone()),
                decided_at: Some(Utc::now()),
                decision_note: None,
                principal_before: None,
                penalty_before: None,
            };
            self.apply(&mut adj).await?;
            self.store.insert(adj, col::adjustments).await?;
        }
        Ok(())
    }

    async fn notify_broken(&self, plan: &PaymentPlan) -> FinanceResult<()> {
        let unit = self
            .store
            .read(|inner| find_unit(inner, &plan.site_id, &plan.unit_id))
            .await?;
        let notifier = NotificationService::new(&self.state);
        let to = notifier.debtor_recipient(&unit, &plan.debtor_type).await;
        notifier
            .deliver(
                Message {
                    site_id: plan.site_id.clone(),
                    unit_id: Some(plan.unit_id.clone()),
                    channel: DeliveryChannel::Email,
                    category: "PLAN",
                    subject: format!("Ödeme planı #{} bozuldu", plan.id),
                    body: "Ödeme planınızın taksiti süresinde ödenmediği için plan sona erdi. Kalan borcunuz için hatırlatmalar yeniden başlayacaktır.".into(),
                    dedupe_key: format!("plan-broken:{}", plan.id),
                    mandatory: true,
                },
                &to,
            )
            .await?;
        Ok(())
    }
}
