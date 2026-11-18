//! Expenses, the general ledger and the yearly account report, SPEC-009 R7
//! (with the reserve fund, F-16).
//!
//! The ledger is *derived* from the source documents every time it is read
//! (liabilities, waivers, receipts, reversals, invoices, invoice payments,
//! capital disbursements and manual entries), so it can never drift from them.
//! Every generated entry balances, so the trial balance always balances; the
//! receivables account equals the open dues to the kuruş.

use chrono::{Datelike, NaiveDate, Utc};
use rust_decimal::{Decimal, RoundingStrategy};

use crate::db::finance_store::FinanceStore;
use crate::domain::double_entry::{self as de, Posting};
use crate::domain::tax_id::TaxId;
use crate::domain::TrIban;
use crate::finance_book::col;
use crate::models::*;
use crate::services::finance_common::*;
use crate::services::receipt_document::{try_amount, DocSection, DocTable, TextDocument};
use crate::state::{AppState, AppStateInner};

/// Without a stored policy, invoices up to this total need one approval.
pub const DEFAULT_MANAGER_LIMIT: i64 = 25_000;
pub const EXPENSE_METHODS: [&str; 2] = ["BANK_TRANSFER", "CASH"];

struct Entry {
    date: NaiveDate,
    source: &'static str,
    reference: String,
    description: String,
    lines: Vec<Posting>,
}

fn cash_account(channel: PaymentChannel) -> &'static str {
    match channel {
        PaymentChannel::Cash | PaymentChannel::ManualCash => de::CASH,
        _ => de::BANK,
    }
}

fn adjusted_total(inner: &AppStateInner, due_id: &str, kind: &str) -> Decimal {
    inner
        .finance
        .adjustments
        .iter()
        .filter(|a| a.due_id == due_id && a.kind == kind && a.status == REQUEST_APPROVED)
        .map(|a| a.amount)
        .sum()
}

/// Principal and late fee taken off a liability by approved credit notes.
fn credited_total(inner: &AppStateInner, due_id: &str) -> (Decimal, Decimal) {
    inner
        .finance
        .corrections
        .iter()
        .filter(|c| {
            c.status == REQUEST_APPROVED
                && c.kind == CORRECTION_CREDIT_NOTE
                && crate::auth::same_id(&c.due_id, due_id)
        })
        .fold((Decimal::ZERO, Decimal::ZERO), |(p, f), c| {
            (p + c.amount, f + c.penalty_reversed.unwrap_or_default())
        })
}

/// Every journal entry of the site, in date order.
fn derive_entries(inner: &AppStateInner, site_id: &str) -> Vec<Entry> {
    let mut out = Vec::new();
    let today = site_today(inner, site_id);
    let dues: Vec<&DuesLiability> = site_dues(inner, site_id).collect();
    let mut paid_on_dues = Decimal::ZERO;
    for d in &dues {
        // A cancelled liability is posted from its correction record below: the
        // original accrual and the reversing entry, so the ledger shows both.
        if d.status == DebtStatus::Cancelled {
            continue;
        }
        let written_off = adjusted_total(inner, &d.id, ADJUSTMENT_WRITE_OFF);
        let waived = adjusted_total(inner, &d.id, ADJUSTMENT_PENALTY_WAIVER);
        let (credited, fee_reversed) = credited_total(inner, &d.id);
        let principal = d.principal_amount + written_off + credited;
        let revenue = if d.expense_type == ExpenseType::CapitalDues {
            de::CAPITAL_DUES_REVENUE
        } else {
            de::OPERATING_DUES_REVENUE
        };
        if principal > Decimal::ZERO {
            out.push(Entry {
                date: d.due_date,
                source: "ACCRUAL",
                reference: d.id.clone(),
                description: format!("{} · {}", d.period, label_of(inner, &d.unit_id)),
                lines: vec![
                    Posting::debit(de::DUES_RECEIVABLE, principal),
                    Posting::credit(revenue, principal),
                ],
            });
        }
        let reevaluated = adjusted_total(inner, &d.id, ADJUSTMENT_PENALTY_REEVALUATION);
        let penalty = d.delay_penalty + waived + fee_reversed + reevaluated;
        if penalty > Decimal::ZERO {
            out.push(Entry {
                date: d.penalty_accrued_through.unwrap_or(today).max(d.due_date),
                source: "PENALTY",
                reference: d.id.clone(),
                description: format!("KMK 20 gecikme tazminatı · {}", d.period),
                lines: vec![
                    Posting::debit(de::DUES_RECEIVABLE, penalty),
                    Posting::credit(de::PENALTY_REVENUE, penalty),
                ],
            });
        }
        paid_on_dues += d.paid_principal + d.paid_penalty;
    }
    for a in inner
        .finance
        .adjustments
        .iter()
        .filter(|a| a.status == REQUEST_APPROVED && crate::auth::same_id(&a.site_id, site_id))
    {
        // A re-evaluation reverses the penalty revenue itself (it was never
        // owed); a waiver forgives penalty that was owed.
        let (source, account) = if a.kind == ADJUSTMENT_PENALTY_REEVALUATION {
            ("PENALTY_REVERSAL", de::PENALTY_REVENUE)
        } else if a.kind == ADJUSTMENT_PENALTY_WAIVER {
            ("WAIVER", de::PENALTY_WAIVED)
        } else {
            ("WRITE_OFF", de::WRITE_OFF_EXPENSE)
        };
        out.push(Entry {
            date: a
                .decided_at
                .map(|t| local_date(inner, site_id, t))
                .unwrap_or(today),
            source,
            reference: format!("ADJ-{}", a.id),
            description: a.reason.clone(),
            lines: vec![
                Posting::debit(account, a.amount),
                Posting::credit(de::DUES_RECEIVABLE, a.amount),
            ],
        });
    }
    push_correction_entries(inner, site_id, &mut out);
    let mut receipt_allocations = Decimal::ZERO;
    for r in inner
        .payment_receipts
        .iter()
        .filter(|r| crate::auth::same_id(&r.site_id, site_id))
    {
        let allocated = r.allocated_principal + r.allocated_penalty;
        let reversal = r.receipt_type == LEDGER_KIND_REVERSAL;
        let virman = r.payment_channel == PaymentChannel::InterLedger;
        let date = local_date(inner, site_id, r.issued_at);
        let mut lines = if virman {
            vec![
                Posting::debit(de::ADVANCES_RECEIVED, allocated),
                Posting::credit(de::DUES_RECEIVABLE, allocated),
            ]
        } else {
            vec![
                Posting::debit(cash_account(r.payment_channel), r.total_amount),
                Posting::credit(de::DUES_RECEIVABLE, allocated),
                Posting::credit(de::ADVANCES_RECEIVED, r.allocated_advance),
            ]
        };
        if reversal {
            for l in lines.iter_mut() {
                std::mem::swap(&mut l.debit, &mut l.credit);
            }
            receipt_allocations -= allocated;
        } else {
            receipt_allocations += allocated;
        }
        lines.retain(|l| l.debit > Decimal::ZERO || l.credit > Decimal::ZERO);
        out.push(Entry {
            date,
            source: if reversal { "REVERSAL" } else { "RECEIPT" },
            reference: r.receipt_number.clone(),
            description: format!("{} · {}", r.payer_name, label_of(inner, &r.unit_id)),
            lines,
        });
    }
    // Advances applied to dues without a receipt (automatic offsets).
    let advance_use = paid_on_dues - receipt_allocations;
    if !advance_use.is_zero() {
        let amount = advance_use.abs();
        let (dr, cr) = if advance_use > Decimal::ZERO {
            (de::ADVANCES_RECEIVED, de::DUES_RECEIVABLE)
        } else {
            (de::DUES_RECEIVABLE, de::ADVANCES_RECEIVED)
        };
        out.push(Entry {
            date: today,
            source: "ADVANCE_USE",
            reference: "AVANS-MAHSUP".into(),
            description: "Avans bakiyesinden otomatik mahsup".into(),
            lines: vec![Posting::debit(dr, amount), Posting::credit(cr, amount)],
        });
    }
    let vendor_name = |id: i64| {
        inner
            .finance
            .vendors
            .iter()
            .find(|v| v.id == id)
            .map(|v| v.name.clone())
            .unwrap_or_default()
    };
    for e in inner.finance.expenses.iter().filter(|e| {
        crate::auth::same_id(&e.site_id, site_id)
            && matches!(
                e.status.as_str(),
                EXPENSE_APPROVED | EXPENSE_PARTIALLY_PAID | EXPENSE_PAID
            )
    }) {
        out.push(Entry {
            date: e.invoice_date,
            source: "EXPENSE",
            reference: e.invoice_number.clone(),
            description: format!("{} · {}", vendor_name(e.vendor_id), e.category),
            lines: vec![
                Posting::debit(de::expense_account(&e.category), e.total_amount),
                Posting::credit(de::VENDORS_PAYABLE, e.total_amount),
            ],
        });
    }
    for p in inner
        .finance
        .expense_payments
        .iter()
        .filter(|p| crate::auth::same_id(&p.site_id, site_id))
    {
        let account = if p.method == "CASH" {
            de::CASH
        } else {
            de::BANK
        };
        out.push(Entry {
            date: p.paid_on,
            source: "EXPENSE_PAYMENT",
            reference: format!("ODEME-{}", p.id),
            description: p
                .reference
                .clone()
                .unwrap_or_else(|| format!("Fatura #{}", p.invoice_id)),
            lines: vec![
                Posting::debit(de::VENDORS_PAYABLE, p.amount),
                Posting::credit(account, p.amount),
            ],
        });
    }
    let projects: Vec<&CapitalProject> = inner
        .capital_projects
        .iter()
        .filter(|p| crate::auth::same_id(&p.site_id, site_id))
        .collect();
    for d in inner
        .capital_disbursements
        .iter()
        .filter(|d| projects.iter().any(|p| p.id == d.project_id))
    {
        out.push(Entry {
            date: d.disbursement_date,
            source: "CAPITAL_DISBURSEMENT",
            reference: d.invoice_number.clone().unwrap_or_else(|| d.id.clone()),
            description: format!("{} · {}", d.recipient_name, d.milestone_name),
            lines: vec![
                Posting::debit(de::CAPITAL_EXPENDITURE, d.amount),
                Posting::credit(de::BANK, d.amount),
            ],
        });
    }
    for m in inner
        .finance
        .journal_entries
        .iter()
        .filter(|m| crate::auth::same_id(&m.site_id, site_id))
    {
        out.push(Entry {
            date: m.entry_date,
            source: match m.kind.as_str() {
                "OPENING" => "OPENING",
                "RESERVE_ALLOCATION" => "RESERVE_ALLOCATION",
                "RESERVE_USE" => "RESERVE_USE",
                "BANK_FEE" => "BANK_FEE",
                _ => "GENERAL",
            },
            reference: format!("YEV-{}", m.id),
            description: m.description.clone(),
            lines: inner
                .finance
                .journal_lines
                .iter()
                .filter(|l| l.entry_id == m.id)
                .map(|l| Posting {
                    account: l.account_code.clone(),
                    debit: l.debit,
                    credit: l.credit,
                })
                .collect(),
        });
    }
    out.sort_by(|a, b| a.date.cmp(&b.date).then(a.reference.cmp(&b.reference)));
    out
}

/// The original accrual and the reversing entry of every approved cancel and
/// re-issue, and the reversing entry of every approved credit note. The paid
/// amount that moved to the advance balance is posted by the advance-use entry,
/// because the receipts keep their allocation while the liability's paid amount
/// no longer counts them.
fn push_correction_entries(inner: &AppStateInner, site_id: &str, out: &mut Vec<Entry>) {
    for c in inner
        .finance
        .corrections
        .iter()
        .filter(|c| c.status == REQUEST_APPROVED && crate::auth::same_id(&c.site_id, site_id))
    {
        let original = inner
            .dues
            .iter()
            .find(|d| crate::auth::same_id(&d.id, &c.due_id));
        let revenue = match original {
            Some(d) if d.expense_type == ExpenseType::CapitalDues => de::CAPITAL_DUES_REVENUE,
            _ => de::OPERATING_DUES_REVENUE,
        };
        let date = c
            .decided_at
            .map(|t| local_date(inner, site_id, t))
            .unwrap_or_else(|| site_today(inner, site_id));
        let cancels = c.kind != CORRECTION_CREDIT_NOTE;
        let principal = if cancels {
            c.principal_before.unwrap_or_default()
        } else {
            c.amount
        };
        let fee = if cancels {
            c.penalty_before.unwrap_or_default()
        } else {
            c.penalty_reversed.unwrap_or_default()
        };
        let label = label_of(inner, &c.unit_id);
        if cancels {
            // The liability itself is skipped above, so post what it accrued.
            if principal > Decimal::ZERO {
                out.push(Entry {
                    date: original.map_or(date, |d| d.due_date),
                    source: "ACCRUAL",
                    reference: c.due_id.clone(),
                    description: format!("{} · {}", c.period, label),
                    lines: vec![
                        Posting::debit(de::DUES_RECEIVABLE, principal),
                        Posting::credit(revenue, principal),
                    ],
                });
            }
            if fee > Decimal::ZERO {
                out.push(Entry {
                    date,
                    source: "PENALTY",
                    reference: c.due_id.clone(),
                    description: format!("KMK 20 gecikme tazminatı · {}", c.period),
                    lines: vec![
                        Posting::debit(de::DUES_RECEIVABLE, fee),
                        Posting::credit(de::PENALTY_REVENUE, fee),
                    ],
                });
            }
        }
        let mut lines = Vec::new();
        if principal > Decimal::ZERO {
            lines.push(Posting::debit(revenue, principal));
        }
        if fee > Decimal::ZERO {
            lines.push(Posting::debit(de::PENALTY_REVENUE, fee));
        }
        if lines.is_empty() {
            continue;
        }
        lines.push(Posting::credit(de::DUES_RECEIVABLE, principal + fee));
        out.push(Entry {
            date,
            source: if cancels {
                "CANCELLATION"
            } else {
                "CREDIT_NOTE"
            },
            reference: format!("KOR-{}", c.id),
            description: format!("{} · {} · {}", c.period, label, c.reason),
            lines,
        });
    }
}

fn in_range(date: NaiveDate, from: Option<NaiveDate>, to: Option<NaiveDate>) -> bool {
    from.is_none_or(|f| date >= f) && to.is_none_or(|t| date <= t)
}

fn balance(entries: &[Entry], account: &str, to: Option<NaiveDate>) -> Decimal {
    let lines: Vec<&Posting> = entries
        .iter()
        .filter(|e| in_range(e.date, None, to))
        .flat_map(|e| e.lines.iter())
        .filter(|l| l.account == account)
        .collect();
    de::trial_balance(lines)
        .first()
        .map(|r| r.balance)
        .unwrap_or(Decimal::ZERO)
}

fn movement(
    entries: &[Entry],
    account: &str,
    from: NaiveDate,
    to: NaiveDate,
    credit: bool,
) -> Decimal {
    entries
        .iter()
        .filter(|e| in_range(e.date, Some(from), Some(to)))
        .flat_map(|e| e.lines.iter())
        .filter(|l| l.account == account)
        .map(|l| if credit { l.credit } else { l.debit })
        .sum()
}

fn budget_for_year<'a>(
    inner: &'a AppStateInner,
    site_id: &str,
    year: i32,
) -> Option<&'a OperatingBudget> {
    inner
        .operating_budgets
        .iter()
        .filter(|b| crate::auth::same_id(&b.site_id, site_id) && b.fiscal_year == year)
        .filter(|b| b.is_in_force() || b.status == BUDGET_SUPERSEDED)
        .max_by_key(|b| (b.is_in_force(), b.created_at))
}

fn pct(part: Decimal, whole: Decimal) -> Option<Decimal> {
    (whole > Decimal::ZERO).then(|| {
        (part * Decimal::ONE_HUNDRED / whole)
            .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven)
    })
}

pub fn budget_vs_actual(inner: &AppStateInner, site_id: &str, year: i32) -> BudgetVsActual {
    let budget = budget_for_year(inner, site_id, year);
    let mut rows: Vec<BudgetVsActualRow> = BUDGET_CATEGORIES
        .iter()
        .map(|c| {
            let budgeted: Decimal = budget
                .map(|b| {
                    b.lines
                        .iter()
                        .filter(|l| l.category == *c)
                        .map(|l| l.annual_amount)
                        .sum()
                })
                .unwrap_or(Decimal::ZERO);
            let actual: Decimal = inner
                .finance
                .expenses
                .iter()
                .filter(|e| {
                    crate::auth::same_id(&e.site_id, site_id)
                        && e.category == *c
                        && e.invoice_date.year() == year
                        && matches!(
                            e.status.as_str(),
                            EXPENSE_APPROVED | EXPENSE_PARTIALLY_PAID | EXPENSE_PAID
                        )
                })
                .map(|e| e.total_amount)
                .sum();
            BudgetVsActualRow {
                category: c.to_string(),
                budgeted,
                actual,
                variance: budgeted - actual,
                used_percent: pct(actual, budgeted),
            }
        })
        .filter(|r| !r.budgeted.is_zero() || !r.actual.is_zero())
        .collect();
    rows.sort_by(|a, b| a.category.cmp(&b.category));
    BudgetVsActual {
        site_id: site_id.to_string(),
        budget_id: budget.map(|b| b.id.clone()),
        fiscal_year: year,
        total_budgeted: rows.iter().map(|r| r.budgeted).sum(),
        total_actual: rows.iter().map(|r| r.actual).sum(),
        rows,
    }
}

fn expense_view(inner: &AppStateInner, e: &ExpenseInvoice) -> ExpenseView {
    let paid: Decimal = inner
        .finance
        .expense_payments
        .iter()
        .filter(|p| p.invoice_id == e.id)
        .map(|p| p.amount)
        .sum();
    let limit = manager_limit(inner, &e.site_id);
    ExpenseView {
        vendor_name: inner
            .finance
            .vendors
            .iter()
            .find(|v| v.id == e.vendor_id)
            .map(|v| v.name.clone())
            .unwrap_or_default(),
        paid_amount: paid,
        open_amount: (e.total_amount - paid).max(Decimal::ZERO),
        needs_auditor: e.status == EXPENSE_PENDING
            && e.total_amount > limit
            && !e.approvals.iter().any(|a| a.role == Role::Auditor.as_str()),
        invoice: e.clone(),
    }
}

fn manager_limit(inner: &AppStateInner, site_id: &str) -> Decimal {
    inner
        .finance
        .approval_policies
        .iter()
        .find(|p| crate::auth::same_id(&p.site_id, site_id))
        .map(|p| p.manager_limit)
        .unwrap_or_else(|| Decimal::from(DEFAULT_MANAGER_LIMIT))
}

pub struct AccountingService {
    store: FinanceStore,
}

impl AccountingService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
        }
    }

    // ----- vendors ---------------------------------------------------------

    pub async fn create_vendor(
        &self,
        caller: &Caller,
        req: CreateVendorRequest,
    ) -> FinanceResult<Vendor> {
        let name = non_empty(&req.name, 2, "name")?;
        let tax_id = TaxId::parse(&req.tax_id).map_err(|e| invalid(e.to_string()))?;
        let iban = match opt_text(&req.iban) {
            Some(raw) => Some(
                TrIban::parse(&raw)
                    .map_err(|e| invalid(e.to_string()))?
                    .into_string(),
            ),
            None => None,
        };
        let duplicate = self
            .store
            .read(|inner| {
                inner.finance.vendors.iter().any(|v| {
                    crate::auth::same_id(&v.site_id, &caller.site_id) && v.tax_id == tax_id.as_str()
                })
            })
            .await;
        if duplicate {
            return Err(conflict(format!(
                "A vendor with tax id {} exists",
                tax_id.as_str()
            )));
        }
        let vendor = Vendor {
            id: 0,
            site_id: caller.site_id.clone(),
            name,
            tax_id: tax_id.as_str().to_string(),
            iban,
            email: opt_text(&req.email),
            phone: opt_text(&req.phone),
            active: true,
            created_at: Utc::now(),
        };
        Ok(self.store.insert(vendor, col::vendors).await?)
    }

    pub async fn vendors(&self, site_id: &str) -> Vec<Vendor> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .vendors
                    .iter()
                    .filter(|v| crate::auth::same_id(&v.site_id, site_id))
                    .cloned()
                    .collect()
            })
            .await
    }

    // ----- approval policy and invoices -------------------------------------

    pub async fn policy(&self, site_id: &str) -> Decimal {
        self.store.read(|inner| manager_limit(inner, site_id)).await
    }

    pub async fn set_policy(
        &self,
        caller: &Caller,
        req: SetApprovalPolicyRequest,
    ) -> FinanceResult<ExpenseApprovalPolicy> {
        if req.manager_limit < Decimal::ZERO || req.manager_limit.scale() > 2 {
            return Err(invalid(
                "manager_limit must be zero or positive with at most 2 decimals",
            ));
        }
        let existing = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .approval_policies
                    .iter()
                    .find(|p| crate::auth::same_id(&p.site_id, &caller.site_id))
                    .map(|p| p.id)
            })
            .await;
        let policy = ExpenseApprovalPolicy {
            id: existing.unwrap_or(0),
            site_id: caller.site_id.clone(),
            manager_limit: req.manager_limit,
            updated_by: caller.actor(),
            updated_at: Utc::now(),
        };
        Ok(self.store.upsert(policy, col::approval_policies).await?)
    }

    pub async fn create_expense(
        &self,
        caller: &Caller,
        req: CreateExpenseRequest,
    ) -> FinanceResult<ExpenseView> {
        money(req.net_amount, "net_amount")?;
        if req.vat_amount < Decimal::ZERO || req.vat_amount.scale() > 2 {
            return Err(invalid(
                "vat_amount must be zero or positive with at most 2 decimals",
            ));
        }
        let number = non_empty(&req.invoice_number, 1, "invoice_number")?;
        let category = BUDGET_CATEGORIES
            .into_iter()
            .find(|c| c.eq_ignore_ascii_case(req.category.trim()))
            .ok_or_else(|| invalid(format!("Unknown expense category '{}'", req.category)))?;
        if req.due_date.is_some_and(|d| d < req.invoice_date) {
            return Err(invalid("due_date is before invoice_date"));
        }
        let budget_id = self
            .store
            .read(|inner| {
                let vendor_ok = inner.finance.vendors.iter().any(|v| {
                    v.id == req.vendor_id
                        && v.active
                        && crate::auth::same_id(&v.site_id, &caller.site_id)
                });
                if !vendor_ok {
                    return Err(not_found(format!("Vendor {} not found", req.vendor_id)));
                }
                if inner.finance.expenses.iter().any(|e| {
                    crate::auth::same_id(&e.site_id, &caller.site_id)
                        && e.vendor_id == req.vendor_id
                        && e.invoice_number == number
                }) {
                    return Err(conflict(format!(
                        "Invoice {} of this vendor is already recorded",
                        number
                    )));
                }
                Ok(crate::services::operating_budget_service::budget_in_force(
                    inner,
                    &caller.site_id,
                    req.invoice_date,
                )
                .map(|b| b.id.clone()))
            })
            .await?;
        let invoice = ExpenseInvoice {
            id: 0,
            site_id: caller.site_id.clone(),
            vendor_id: req.vendor_id,
            invoice_number: number,
            invoice_date: req.invoice_date,
            due_date: req.due_date,
            category: category.to_string(),
            description: opt_text(&req.description),
            net_amount: req.net_amount,
            vat_amount: req.vat_amount,
            total_amount: req.net_amount + req.vat_amount,
            document_ref: opt_text(&req.document_ref),
            status: EXPENSE_PENDING.to_string(),
            budget_id,
            approvals: Vec::new(),
            rejection_reason: None,
            created_by: caller.actor(),
            created_at: Utc::now(),
        };
        let saved = self.store.insert(invoice, col::expenses).await?;
        Ok(self.store.read(|inner| expense_view(inner, &saved)).await)
    }

    pub async fn expenses(&self, site_id: &str) -> Vec<ExpenseView> {
        self.store
            .read(|inner| {
                let mut rows: Vec<ExpenseView> = inner
                    .finance
                    .expenses
                    .iter()
                    .filter(|e| crate::auth::same_id(&e.site_id, site_id))
                    .map(|e| expense_view(inner, e))
                    .collect();
                rows.sort_by_key(|a| std::cmp::Reverse(a.invoice.invoice_date));

                rows
            })
            .await
    }

    async fn find_expense(&self, site_id: &str, id: i64) -> FinanceResult<ExpenseInvoice> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .expenses
                    .iter()
                    .find(|e| e.id == id && crate::auth::same_id(&e.site_id, site_id))
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Expense invoice {} not found", id)))
    }

    /// Four-eyes approval: never the creator; above the manager limit both a
    /// manager and the auditor approve.
    pub async fn approve_expense(&self, caller: &Caller, id: i64) -> FinanceResult<ExpenseView> {
        let mut e = self.find_expense(&caller.site_id, id).await?;
        if e.status != EXPENSE_PENDING {
            return Err(conflict(format!(
                "Invoice {} is {}",
                e.invoice_number, e.status
            )));
        }
        if same_actor(&e.created_by, &caller.actor()) {
            return Err(FinanceError::Forbidden(
                "The person who recorded the invoice cannot approve it (four-eyes)".into(),
            ));
        }
        if e.approvals
            .iter()
            .any(|a| same_actor(&a.approver, &caller.actor()))
        {
            return Err(conflict("You have already approved this invoice"));
        }
        let role = if caller.is_auditor() {
            Role::Auditor
        } else {
            Role::SiteManager
        };
        e.approvals.push(ExpenseApproval {
            approver: caller.actor(),
            role: role.as_str().to_string(),
            approved_at: Utc::now(),
        });
        let limit = self.policy(&caller.site_id).await;
        let has_manager = e
            .approvals
            .iter()
            .any(|a| a.role == Role::SiteManager.as_str());
        let has_auditor = e.approvals.iter().any(|a| a.role == Role::Auditor.as_str());
        let complete = if e.total_amount > limit {
            has_manager && has_auditor
        } else {
            !e.approvals.is_empty()
        };
        if complete {
            e.status = EXPENSE_APPROVED.to_string();
        }
        let saved = self.store.update(e, col::expenses).await?;
        Ok(self.store.read(|inner| expense_view(inner, &saved)).await)
    }

    pub async fn reject_expense(
        &self,
        caller: &Caller,
        id: i64,
        req: RejectExpenseRequest,
    ) -> FinanceResult<ExpenseView> {
        let reason = non_empty(&req.reason, 3, "reason")?;
        let mut e = self.find_expense(&caller.site_id, id).await?;
        if e.status != EXPENSE_PENDING {
            return Err(conflict(format!(
                "Invoice {} is {}",
                e.invoice_number, e.status
            )));
        }
        e.status = EXPENSE_REJECTED.to_string();
        e.rejection_reason = Some(reason);
        let saved = self.store.update(e, col::expenses).await?;
        Ok(self.store.read(|inner| expense_view(inner, &saved)).await)
    }

    pub async fn pay_expense(
        &self,
        caller: &Caller,
        id: i64,
        req: PayExpenseRequest,
    ) -> FinanceResult<ExpenseView> {
        money(req.amount, "amount")?;
        let method = req
            .method
            .as_deref()
            .unwrap_or("BANK_TRANSFER")
            .trim()
            .to_ascii_uppercase();
        if !EXPENSE_METHODS.contains(&method.as_str()) {
            return Err(invalid("method must be BANK_TRANSFER or CASH"));
        }
        let mut e = self.find_expense(&caller.site_id, id).await?;
        if !matches!(e.status.as_str(), EXPENSE_APPROVED | EXPENSE_PARTIALLY_PAID) {
            return Err(conflict(format!(
                "Invoice {} is {}; only an approved invoice is paid",
                e.invoice_number, e.status
            )));
        }
        let open = self
            .store
            .read(|inner| expense_view(inner, &e).open_amount)
            .await;
        if req.amount > open {
            return Err(conflict(format!(
                "Only ₺{:.2} is open on this invoice",
                open
            )));
        }
        let today = self
            .store
            .read(|inner| site_today(inner, &caller.site_id))
            .await;
        let payment = ExpensePayment {
            id: 0,
            site_id: caller.site_id.clone(),
            invoice_id: e.id,
            amount: req.amount,
            paid_on: req.paid_on.unwrap_or(today),
            method,
            reference: opt_text(&req.reference),
            recorded_by: caller.actor(),
            created_at: Utc::now(),
        };
        self.store.insert(payment, col::expense_payments).await?;
        e.status = if req.amount == open {
            EXPENSE_PAID
        } else {
            EXPENSE_PARTIALLY_PAID
        }
        .to_string();
        let saved = self.store.update(e, col::expenses).await?;
        Ok(self.store.read(|inner| expense_view(inner, &saved)).await)
    }

    // ----- journal ---------------------------------------------------------

    pub async fn create_journal_entry(
        &self,
        caller: &Caller,
        req: CreateJournalEntryRequest,
    ) -> FinanceResult<JournalEntryView> {
        let description = non_empty(&req.description, 3, "description")?;
        let kind = req
            .kind
            .as_deref()
            .unwrap_or("GENERAL")
            .trim()
            .to_ascii_uppercase();
        if !matches!(
            kind.as_str(),
            "GENERAL" | "OPENING" | "RESERVE_ALLOCATION" | "RESERVE_USE" | "BANK_FEE"
        ) {
            return Err(invalid(format!("Unknown journal entry kind '{}'", kind)));
        }
        let postings: Vec<Posting> = req
            .lines
            .iter()
            .map(|l| Posting {
                account: l.account_code.trim().to_string(),
                debit: l.debit,
                credit: l.credit,
            })
            .collect();
        de::validate_entry(&postings).map_err(|e| invalid(e.to_string()))?;
        let today = self
            .store
            .read(|inner| site_today(inner, &caller.site_id))
            .await;
        let entry = ManualJournalEntry {
            id: 0,
            site_id: caller.site_id.clone(),
            entry_date: req.entry_date.unwrap_or(today),
            kind,
            description,
            created_by: caller.actor(),
            created_at: Utc::now(),
        };
        let lines: Vec<ManualJournalLine> = postings
            .iter()
            .map(|p| ManualJournalLine {
                id: 0,
                entry_id: 0,
                account_code: p.account.clone(),
                debit: p.debit,
                credit: p.credit,
            })
            .collect();
        let (entry, lines) = self
            .store
            .insert_with_children(
                entry,
                col::journal_entries,
                lines,
                col::journal_lines,
                |l, id| l.entry_id = id,
            )
            .await?;
        Ok(JournalEntryView {
            date: entry.entry_date,
            source: "MANUAL".to_string(),
            reference: format!("YEV-{}", entry.id),
            description: entry.description,
            lines: lines
                .iter()
                .map(|l| line_view(&l.account_code, l.debit, l.credit))
                .collect(),
        })
    }

    pub async fn journal(
        &self,
        site_id: &str,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> Vec<JournalEntryView> {
        self.store
            .read(|inner| {
                derive_entries(inner, site_id)
                    .into_iter()
                    .filter(|e| in_range(e.date, from, to))
                    .map(|e| JournalEntryView {
                        date: e.date,
                        source: e.source.to_string(),
                        reference: e.reference,
                        description: e.description,
                        lines: e
                            .lines
                            .iter()
                            .map(|l| line_view(&l.account, l.debit, l.credit))
                            .collect(),
                    })
                    .collect()
            })
            .await
    }

    pub async fn trial_balance(
        &self,
        site_id: &str,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> TrialBalance {
        self.store
            .read(|inner| {
                let entries = derive_entries(inner, site_id);
                let lines: Vec<&Posting> = entries
                    .iter()
                    .filter(|e| in_range(e.date, from, to))
                    .flat_map(|e| e.lines.iter())
                    .collect();
                let rows: Vec<TrialBalanceRowView> = de::trial_balance(lines)
                    .into_iter()
                    .map(|r| TrialBalanceRowView {
                        account_code: r.account,
                        account_name: r.name.to_string(),
                        debit: r.debit,
                        credit: r.credit,
                        balance: r.balance,
                    })
                    .collect();
                let total_debit: Decimal = rows.iter().map(|r| r.debit).sum();
                let total_credit: Decimal = rows.iter().map(|r| r.credit).sum();
                TrialBalance {
                    site_id: site_id.to_string(),
                    from,
                    to,
                    balanced: total_debit == total_credit,
                    rows,
                    total_debit,
                    total_credit,
                }
            })
            .await
    }

    pub async fn budget_vs_actual(&self, site_id: &str, year: i32) -> BudgetVsActual {
        self.store
            .read(|inner| budget_vs_actual(inner, site_id, year))
            .await
    }

    pub async fn reserve_fund(&self, site_id: &str, year: i32) -> ReserveFundStatus {
        self.store
            .read(|inner| {
                let target: Decimal = budget_for_year(inner, site_id, year)
                    .map(|b| {
                        b.lines
                            .iter()
                            .filter(|l| l.category == "RESERVE")
                            .map(|l| l.annual_amount)
                            .sum()
                    })
                    .unwrap_or(Decimal::ZERO);
                let entries = derive_entries(inner, site_id);
                let lines: Vec<&Posting> = entries
                    .iter()
                    .flat_map(|e| e.lines.iter())
                    .filter(|l| l.account == de::RESERVE_FUND)
                    .collect();
                let allocated: Decimal = lines.iter().map(|l| l.credit).sum();
                let used: Decimal = lines.iter().map(|l| l.debit).sum();
                ReserveFundStatus {
                    site_id: site_id.to_string(),
                    fiscal_year: year,
                    target,
                    allocated,
                    used,
                    balance: allocated - used,
                    target_reached_percent: pct(allocated - used, target),
                }
            })
            .await
    }

    /// The manager's yearly account (hesap verme, KMK 35) to the assembly.
    pub async fn account_report(&self, site_id: &str, year: i32) -> FinanceResult<AccountReport> {
        let start = NaiveDate::from_ymd_opt(year, 1, 1).ok_or_else(|| invalid("Invalid year"))?;
        let end = NaiveDate::from_ymd_opt(year, 12, 31).ok_or_else(|| invalid("Invalid year"))?;
        Ok(self
            .store
            .read(|inner| {
                let entries = derive_entries(inner, site_id);
                let before = start.pred_opt();
                let cash = |to: Option<NaiveDate>| {
                    balance(&entries, de::CASH, to) + balance(&entries, de::BANK, to)
                };
                let bva = budget_vs_actual(inner, site_id, year);
                let tb_lines: Vec<&Posting> = entries.iter().flat_map(|e| e.lines.iter()).collect();
                let all = de::trial_balance(tb_lines);
                let collected: Decimal = entries
                    .iter()
                    .filter(|e| in_range(e.date, Some(start), Some(end)))
                    .filter(|e| matches!(e.source, "RECEIPT" | "REVERSAL"))
                    .flat_map(|e| e.lines.iter())
                    .filter(|l| l.account == de::CASH || l.account == de::BANK)
                    .map(|l| l.debit - l.credit)
                    .sum();
                AccountReport {
                    site_id: site_id.to_string(),
                    site_name: site_name(inner, site_id),
                    fiscal_year: year,
                    period_start: start,
                    period_end: end,
                    opening_cash: before.map(|b| cash(Some(b))).unwrap_or(Decimal::ZERO),
                    closing_cash: cash(Some(end)),
                    dues_accrued: movement(&entries, de::OPERATING_DUES_REVENUE, start, end, true)
                        + movement(&entries, de::CAPITAL_DUES_REVENUE, start, end, true),
                    penalties_accrued: movement(&entries, de::PENALTY_REVENUE, start, end, true),
                    collected,
                    total_expenses: bva.total_actual,
                    expenses_by_category: bva.rows,
                    expenses_paid: movement(&entries, de::VENDORS_PAYABLE, start, end, false),
                    receivables_outstanding: balance(&entries, de::DUES_RECEIVABLE, Some(end)),
                    payables_outstanding: balance(&entries, de::VENDORS_PAYABLE, Some(end)),
                    advances_held: balance(&entries, de::ADVANCES_RECEIVED, Some(end)),
                    reserve_balance: balance(&entries, de::RESERVE_FUND, Some(end)),
                    waivers_and_write_offs: movement(
                        &entries,
                        de::PENALTY_WAIVED,
                        start,
                        end,
                        false,
                    ) + movement(
                        &entries,
                        de::WRITE_OFF_EXPENSE,
                        start,
                        end,
                        false,
                    ),
                    trial_balance_balanced: all.iter().map(|r| r.debit).sum::<Decimal>()
                        == all.iter().map(|r| r.credit).sum::<Decimal>(),
                    generated_at: Utc::now(),
                }
            })
            .await)
    }

    pub fn account_report_document(report: &AccountReport) -> TextDocument {
        TextDocument {
            issuer: report.site_name.clone(),
            issuer_lines: vec![format!(
                "{} – {} dönemi",
                report.period_start.format("%d.%m.%Y"),
                report.period_end.format("%d.%m.%Y")
            )],
            title: format!("{} YILI HESAP RAPORU (KMK 35)", report.fiscal_year),
            sections: vec![
                DocSection {
                    heading: Some("Kasa ve banka".into()),
                    rows: vec![
                        ("Dönem başı".into(), try_amount(report.opening_cash)),
                        ("Tahsilat".into(), try_amount(report.collected)),
                        ("Gider ödemeleri".into(), try_amount(report.expenses_paid)),
                        ("Dönem sonu".into(), try_amount(report.closing_cash)),
                    ],
                    ..DocSection::default()
                },
                DocSection {
                    heading: Some("Gelirler".into()),
                    rows: vec![
                        ("Tahakkuk eden aidat ve katılım".into(), try_amount(report.dues_accrued)),
                        ("Gecikme tazminatı (KMK 20)".into(), try_amount(report.penalties_accrued)),
                        ("Vazgeçilen / silinen".into(), try_amount(report.waivers_and_write_offs)),
                    ],
                    ..DocSection::default()
                },
                DocSection {
                    heading: Some("Giderler: bütçe ve gerçekleşen".into()),
                    table: Some(DocTable {
                        headers: vec!["Kalem".into(), "Bütçe".into(), "Gerçekleşen".into(), "Fark".into()],
                        rows: report
                            .expenses_by_category
                            .iter()
                            .map(|r| vec![r.category.clone(), try_amount(r.budgeted), try_amount(r.actual), try_amount(r.variance)])
                            .collect(),
                    }),
                    rows: vec![("Toplam gider".into(), try_amount(report.total_expenses))],
                    ..DocSection::default()
                },
                DocSection {
                    heading: Some("Dönem sonu bakiyeleri".into()),
                    rows: vec![
                        ("Sakinlerden alacaklar".into(), try_amount(report.receivables_outstanding)),
                        ("Satıcılara borçlar".into(), try_amount(report.payables_outstanding)),
                        ("Alınan avanslar".into(), try_amount(report.advances_held)),
                        ("Yedek akçe".into(), try_amount(report.reserve_balance)),
                        (
                            "Mizan".into(),
                            if report.trial_balance_balanced { "Denk".into() } else { "DENK DEĞİL".into() },
                        ),
                    ],
                    ..DocSection::default()
                },
            ],
            footer: "Bu rapor yöneticinin kat malikleri kuruluna hesap verme yükümlülüğü (KMK 35) için SitePulse defterlerinden üretilmiştir; denetçi incelemesine sunulur.".into(),
        }
    }
}

fn line_view(account: &str, debit: Decimal, credit: Decimal) -> JournalLineView {
    JournalLineView {
        account_code: account.to_string(),
        account_name: de::account(account)
            .map(|a| a.name)
            .unwrap_or("?")
            .to_string(),
        debit,
        credit,
    }
}
