//! Collection analytics and the cash-flow forecast, SPEC-009 R14 (and the
//! payment-stream KPIs of §3.3).
//!
//! All figures are computed from the ledger tables: liabilities give what was
//! due, receipt allocation lines give when it was settled.

use std::collections::BTreeMap;

use chrono::{Datelike, Months, NaiveDate};
use rust_decimal::{Decimal, RoundingStrategy};

use crate::db::finance_store::FinanceStore;
use crate::domain::collection_metrics::{self as cm, RiskInput, Settlement};
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::state::{AppState, AppStateInner};

/// Channels settled without a person matching the payment.
pub fn is_zero_touch(channel: PaymentChannel) -> bool {
    matches!(
        channel,
        PaymentChannel::VirtualIban | PaymentChannel::CreditCard | PaymentChannel::OnlinePayment
    )
}

fn month_key(d: NaiveDate) -> String {
    format!("{:04}-{:02}", d.year(), d.month())
}

fn first_of_month(d: NaiveDate) -> NaiveDate {
    NaiveDate::from_ymd_opt(d.year(), d.month(), 1).unwrap_or(d)
}

fn pct(part: Decimal, whole: Decimal) -> Option<Decimal> {
    (whole > Decimal::ZERO).then(|| {
        (part * Decimal::ONE_HUNDRED / whole)
            .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven)
    })
}

/// Settlement lines of a site's receipts (reversals remove the lines they reversed).
fn settlements(inner: &AppStateInner, site_id: &str) -> Vec<(String, Settlement)> {
    let reversed: Vec<i64> = inner
        .payment_receipts
        .iter()
        .filter_map(|r| r.reverses_receipt_id)
        .collect();
    let mut out = Vec::new();
    for r in inner.payment_receipts.iter().filter(|r| {
        crate::auth::same_id(&r.site_id, site_id)
            && r.receipt_type != LEDGER_KIND_REVERSAL
            && !reversed.contains(&r.id)
    }) {
        for line in &r.allocation_breakdown {
            let Some(ref due_id) = line.due_id else {
                continue;
            };
            let Some(due) = inner.dues.iter().find(|d| &d.id == due_id) else {
                continue;
            };
            if line.principal_paid > Decimal::ZERO {
                out.push((
                    due_id.clone(),
                    Settlement {
                        due_date: due.due_date,
                        settled_on: local_date(inner, site_id, r.issued_at),
                        amount: line.principal_paid,
                    },
                ));
            }
        }
    }
    out
}

pub fn collection_analytics(
    inner: &AppStateInner,
    site_id: &str,
    months: u32,
    as_of: NaiveDate,
) -> CollectionAnalytics {
    let dues: Vec<&DuesLiability> = site_dues(inner, site_id).collect();
    let lines = settlements(inner, site_id);
    let start = first_of_month(as_of)
        .checked_sub_months(Months::new(months.saturating_sub(1)))
        .unwrap_or(as_of);
    let mut by_month: BTreeMap<String, (Decimal, Decimal, Vec<Settlement>)> = BTreeMap::new();
    let mut cursor = start;
    while cursor <= as_of {
        by_month.insert(
            month_key(cursor),
            (Decimal::ZERO, Decimal::ZERO, Vec::new()),
        );
        cursor = match cursor.checked_add_months(Months::new(1)) {
            Some(c) => c,
            None => break,
        };
    }
    for d in &dues {
        if let Some(slot) = by_month.get_mut(&month_key(d.due_date)) {
            slot.0 += d.principal_amount;
            slot.1 += d.paid_principal;
        }
    }
    for (due_id, s) in &lines {
        if dues.iter().any(|d| &d.id == due_id) {
            if let Some(slot) = by_month.get_mut(&month_key(s.due_date)) {
                slot.2.push(s.clone());
            }
        }
    }
    let month_rows: Vec<MonthlyCollectionKpi> = by_month
        .into_iter()
        .map(|(month, (due, settled, s))| MonthlyCollectionKpi {
            collection_rate: cm::collection_rate(due, settled),
            on_time_rate: cm::on_time_rate(due, &s),
            dso_days: cm::dso_days(&s),
            month,
            principal_due: due,
            settled,
        })
        .collect();
    // Trailing rate: the last three months that are already due.
    let trailing: Vec<&MonthlyCollectionKpi> = month_rows
        .iter()
        .filter(|m| m.month < month_key(as_of) && m.principal_due > Decimal::ZERO)
        .rev()
        .take(3)
        .collect();
    let trailing_due: Decimal = trailing.iter().map(|m| m.principal_due).sum();
    let trailing_settled: Decimal = trailing.iter().map(|m| m.settled).sum();
    let trailing_rate = cm::collection_rate(trailing_due, trailing_settled);

    // Channels.
    let mut channels: BTreeMap<&'static str, (Decimal, bool)> = BTreeMap::new();
    for r in inner.payment_receipts.iter().filter(|r| {
        crate::auth::same_id(&r.site_id, site_id)
            && r.payment_channel != PaymentChannel::InterLedger
    }) {
        let sign = if r.receipt_type == LEDGER_KIND_REVERSAL {
            Decimal::NEGATIVE_ONE
        } else {
            Decimal::ONE
        };
        let slot = channels
            .entry(r.payment_channel.as_str())
            .or_insert((Decimal::ZERO, is_zero_touch(r.payment_channel)));
        slot.0 += sign * r.total_amount;
    }
    let total: Decimal = channels.values().map(|v| v.0).sum();
    let zero_touch: Decimal = channels.values().filter(|v| v.1).map(|v| v.0).sum();
    let digital: Decimal = channels
        .iter()
        .filter(|(c, _)| matches!(**c, "VIRTUAL_IBAN" | "CREDIT_CARD" | "ONLINE_PAYMENT"))
        .map(|(_, v)| v.0)
        .sum();
    let channel_rows = channels
        .into_iter()
        .map(|(c, (amount, zt))| ChannelShare {
            channel: c.to_string(),
            amount,
            share_percent: pct(amount, total),
            zero_touch: zt,
        })
        .collect();

    // Forecast: expected dues × trailing collection rate, minus planned outflows.
    let budget = crate::services::operating_budget_service::budget_in_force(inner, site_id, as_of);
    let monthly_dues: Decimal = match budget {
        Some(b) => b.unit_shares.iter().map(|s| s.monthly_amount).sum(),
        None => site_units(inner, site_id)
            .filter_map(|u| crate::scheduler::tariff_for(inner, u))
            .sum(),
    };
    let monthly_cost = budget
        .map(|b| b.total_annual_amount / Decimal::from(12))
        .unwrap_or(Decimal::ZERO)
        .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven);
    let rate = trailing_rate.unwrap_or(Decimal::ONE_HUNDRED) / Decimal::ONE_HUNDRED;
    let mut forecast = Vec::new();
    for i in 1..=6u32 {
        let Some(month) = first_of_month(as_of).checked_add_months(Months::new(i)) else {
            break;
        };
        let key = month_key(month);
        let invoices: Decimal = inner
            .finance
            .expenses
            .iter()
            .filter(|e| {
                crate::auth::same_id(&e.site_id, site_id)
                    && matches!(e.status.as_str(), EXPENSE_APPROVED | EXPENSE_PARTIALLY_PAID)
                    && month_key(e.due_date.unwrap_or(e.invoice_date).max(month)) == key
            })
            .map(|e| {
                let paid: Decimal = inner
                    .finance
                    .expense_payments
                    .iter()
                    .filter(|p| p.invoice_id == e.id)
                    .map(|p| p.amount)
                    .sum();
                (e.total_amount - paid).max(Decimal::ZERO)
            })
            .sum();
        let inflow =
            (monthly_dues * rate).round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven);
        let outflow =
            monthly_cost.max(Decimal::ZERO) + if i == 1 { invoices } else { Decimal::ZERO };
        forecast.push(CashFlowMonth {
            month: key,
            expected_inflow: inflow,
            expected_outflow: outflow,
            net: inflow - outflow,
        });
    }

    // At-risk units.
    let mut risky: Vec<AtRiskUnit> = site_units(inner, site_id)
        .filter_map(|u| {
            let overdue: Vec<&&DuesLiability> = dues
                .iter()
                .filter(|d| {
                    crate::auth::same_id(&d.unit_id, &u.id) && is_open(d) && d.due_date < as_of
                })
                .collect();
            let overdue_amount: Decimal = overdue.iter().map(|d| dues_ledger::outstanding(d)).sum();
            let oldest = overdue
                .iter()
                .map(|d| (as_of - d.due_date).num_days())
                .max()
                .unwrap_or(0);
            let monthly = budget
                .and_then(|b| b.share_of(&u.id).map(|s| s.monthly_amount))
                .or_else(|| crate::scheduler::tariff_for(inner, u))
                .unwrap_or(Decimal::ZERO);
            let input = RiskInput {
                overdue_amount,
                monthly_dues: monthly,
                oldest_days_overdue: oldest,
                broken_plans: u32::try_from(
                    inner
                        .finance
                        .plans
                        .iter()
                        .filter(|p| {
                            crate::auth::same_id(&p.unit_id, &u.id) && p.status == PLAN_BROKEN
                        })
                        .count(),
                )
                .unwrap_or(0),
                open_disputes: u32::try_from(
                    inner
                        .finance
                        .disputes
                        .iter()
                        .filter(|d| {
                            crate::auth::same_id(&d.unit_id, &u.id) && d.status == DISPUTE_OPEN
                        })
                        .count(),
                )
                .unwrap_or(0),
                in_collection: inner
                    .finance
                    .cases
                    .iter()
                    .any(|c| crate::auth::same_id(&c.unit_id, &u.id) && c.closed_at.is_none()),
            };
            let (score, tier) = cm::risk_score(&input);
            (score > 0).then(|| AtRiskUnit {
                unit_id: u.id.clone(),
                unit_label: unit_label(inner, u),
                score,
                tier: tier.as_str().to_string(),
                overdue_amount,
                oldest_days_overdue: oldest,
            })
        })
        .collect();
    risky.sort_by(|a, b| b.score.cmp(&a.score).then(a.unit_label.cmp(&b.unit_label)));
    risky.truncate(25);

    CollectionAnalytics {
        site_id: site_id.to_string(),
        as_of,
        months: month_rows,
        channels: channel_rows,
        digital_share_percent: pct(digital, total),
        zero_touch_share_percent: pct(zero_touch, total),
        trailing_collection_rate: trailing_rate,
        cash_flow_forecast: forecast,
        at_risk_units: risky,
    }
}

pub struct AnalyticsService {
    store: FinanceStore,
}

impl AnalyticsService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
        }
    }

    pub async fn collections(
        &self,
        site_id: &str,
        months: Option<u32>,
        as_of: Option<NaiveDate>,
    ) -> CollectionAnalytics {
        let months = months.unwrap_or(12).clamp(1, 36);
        self.store
            .read(|inner| {
                let as_of = as_of.unwrap_or_else(|| site_today(inner, site_id));
                collection_analytics(inner, site_id, months, as_of)
            })
            .await
    }
}
