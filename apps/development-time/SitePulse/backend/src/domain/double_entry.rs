//! Double-entry bookkeeping for a site, SPEC-009 R7.
//!
//! The chart is a simplified subset of the Tekdüzen Hesap Planı (verify with a
//! mali müşavir): a site is generally not a taxpayer, so VAT on incoming
//! invoices is part of the expense. Every journal entry balances; the trial
//! balance of balanced entries always balances.

use std::collections::BTreeMap;

use rust_decimal::Decimal;
use thiserror::Error;

/// Which side increases an account.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NormalSide {
    Debit,
    Credit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Account {
    pub code: &'static str,
    pub name: &'static str,
    pub side: NormalSide,
}

const fn acc(code: &'static str, name: &'static str, side: NormalSide) -> Account {
    Account { code, name, side }
}

pub const CASH: &str = "100";
pub const BANK: &str = "102";
pub const DUES_RECEIVABLE: &str = "120";
pub const VENDORS_PAYABLE: &str = "320";
pub const ADVANCES_RECEIVED: &str = "340";
pub const RESERVE_FUND: &str = "549";
pub const OPERATING_DUES_REVENUE: &str = "600";
pub const CAPITAL_DUES_REVENUE: &str = "602";
pub const PENALTY_REVENUE: &str = "642";
pub const PENALTY_WAIVED: &str = "653";
pub const WRITE_OFF_EXPENSE: &str = "689";
pub const RESERVE_APPROPRIATION: &str = "690";
pub const CAPITAL_EXPENDITURE: &str = "770.90";
pub const BANK_FEES: &str = "780";

/// The site chart of accounts. Expense accounts `770.xx` follow the budget
/// categories so budget vs actual reads straight from the ledger.
pub const CHART: [Account; 26] = [
    acc(CASH, "Kasa", NormalSide::Debit),
    acc(BANK, "Bankalar", NormalSide::Debit),
    acc(
        DUES_RECEIVABLE,
        "Kat malikleri ve sakinlerden alacaklar",
        NormalSide::Debit,
    ),
    acc(VENDORS_PAYABLE, "Satıcılar", NormalSide::Credit),
    acc(ADVANCES_RECEIVED, "Alınan avanslar", NormalSide::Credit),
    acc(RESERVE_FUND, "Yedek akçe (fon)", NormalSide::Credit),
    acc("500", "Açılış bakiyesi / devreden fon", NormalSide::Credit),
    acc(
        OPERATING_DUES_REVENUE,
        "Aidat gelirleri",
        NormalSide::Credit,
    ),
    acc(
        CAPITAL_DUES_REVENUE,
        "Demirbaş ve yatırım katılım gelirleri",
        NormalSide::Credit,
    ),
    acc(
        PENALTY_REVENUE,
        "Gecikme tazminatı gelirleri (KMK 20)",
        NormalSide::Credit,
    ),
    acc(
        PENALTY_WAIVED,
        "Gecikme tazminatı vazgeçmeleri",
        NormalSide::Debit,
    ),
    acc(
        WRITE_OFF_EXPENSE,
        "Tahsil edilemeyen alacak giderleri",
        NormalSide::Debit,
    ),
    acc(
        RESERVE_APPROPRIATION,
        "Yedek akçeye ayrılan",
        NormalSide::Debit,
    ),
    acc("770.01", "Personel giderleri", NormalSide::Debit),
    acc("770.02", "Temizlik giderleri", NormalSide::Debit),
    acc("770.03", "Enerji giderleri", NormalSide::Debit),
    acc("770.04", "Su giderleri", NormalSide::Debit),
    acc("770.05", "Bakım onarım giderleri", NormalSide::Debit),
    acc("770.06", "Sigorta giderleri", NormalSide::Debit),
    acc("770.07", "Yönetim hizmet bedeli", NormalSide::Debit),
    acc("770.08", "Güvenlik giderleri", NormalSide::Debit),
    acc("770.09", "Bahçe ve peyzaj giderleri", NormalSide::Debit),
    acc("770.10", "Yedek akçe harcamaları", NormalSide::Debit),
    acc("770.99", "Diğer giderler", NormalSide::Debit),
    acc(
        CAPITAL_EXPENDITURE,
        "Demirbaş ve yatırım harcamaları",
        NormalSide::Debit,
    ),
    acc(
        BANK_FEES,
        "Banka ve ödeme hizmeti giderleri",
        NormalSide::Debit,
    ),
];

pub fn account(code: &str) -> Option<&'static Account> {
    CHART.iter().find(|a| a.code == code)
}

/// The expense account of a budget category.
pub fn expense_account(category: &str) -> &'static str {
    match category {
        "PERSONNEL" => "770.01",
        "CLEANING" => "770.02",
        "ENERGY" => "770.03",
        "WATER" => "770.04",
        "MAINTENANCE" => "770.05",
        "INSURANCE" => "770.06",
        "MANAGEMENT_FEE" => "770.07",
        "SECURITY" => "770.08",
        "GARDENING" => "770.09",
        "RESERVE" => "770.10",
        _ => "770.99",
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Posting {
    pub account: String,
    pub debit: Decimal,
    pub credit: Decimal,
}

impl Posting {
    pub fn debit(account: &str, amount: Decimal) -> Self {
        Posting {
            account: account.to_string(),
            debit: amount,
            credit: Decimal::ZERO,
        }
    }
    pub fn credit(account: &str, amount: Decimal) -> Self {
        Posting {
            account: account.to_string(),
            debit: Decimal::ZERO,
            credit: amount,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum JournalError {
    #[error("a journal entry needs at least two lines")]
    TooFewLines,
    #[error("line {0}: unknown account {1}")]
    UnknownAccount(usize, String),
    #[error("line {0}: a line is either a debit or a credit, positive, with at most 2 decimals")]
    LineAmount(usize),
    #[error("the entry does not balance: debits {0} vs credits {1}")]
    Unbalanced(Decimal, Decimal),
}

/// Checks a manual entry: known accounts, one-sided positive lines, balanced.
pub fn validate_entry(lines: &[Posting]) -> Result<(), JournalError> {
    if lines.len() < 2 {
        return Err(JournalError::TooFewLines);
    }
    let (mut debits, mut credits) = (Decimal::ZERO, Decimal::ZERO);
    for (i, l) in lines.iter().enumerate() {
        if account(&l.account).is_none() {
            return Err(JournalError::UnknownAccount(i, l.account.clone()));
        }
        let one_sided = (l.debit > Decimal::ZERO) != (l.credit > Decimal::ZERO);
        if !one_sided
            || l.debit < Decimal::ZERO
            || l.credit < Decimal::ZERO
            || l.debit.scale() > 2
            || l.credit.scale() > 2
        {
            return Err(JournalError::LineAmount(i));
        }
        debits += l.debit;
        credits += l.credit;
    }
    if debits != credits {
        return Err(JournalError::Unbalanced(debits, credits));
    }
    Ok(())
}

/// Drops zero lines and reports whether what is left balances. Generated entries
/// use it: an entry whose amounts are all zero is skipped.
pub fn is_balanced(lines: &[Posting]) -> bool {
    let d: Decimal = lines.iter().map(|l| l.debit).sum();
    let c: Decimal = lines.iter().map(|l| l.credit).sum();
    d == c
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrialBalanceRow {
    pub account: String,
    pub name: &'static str,
    pub debit: Decimal,
    pub credit: Decimal,
    /// Balance on the account's normal side (negative when it is reversed).
    pub balance: Decimal,
}

/// Debit and credit totals per account, in chart order.
pub fn trial_balance<'a>(lines: impl IntoIterator<Item = &'a Posting>) -> Vec<TrialBalanceRow> {
    let mut totals: BTreeMap<&str, (Decimal, Decimal)> = BTreeMap::new();
    let lines: Vec<&Posting> = lines.into_iter().collect();
    for l in &lines {
        let t = totals
            .entry(l.account.as_str())
            .or_insert((Decimal::ZERO, Decimal::ZERO));
        t.0 += l.debit;
        t.1 += l.credit;
    }
    CHART
        .iter()
        .filter_map(|a| {
            totals.get(a.code).map(|(d, c)| TrialBalanceRow {
                account: a.code.to_string(),
                name: a.name,
                debit: *d,
                credit: *c,
                balance: match a.side {
                    NormalSide::Debit => *d - *c,
                    NormalSide::Credit => *c - *d,
                },
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> Decimal {
        Decimal::from_str_exact(s).unwrap_or_default()
    }

    #[test]
    fn chart_codes_are_unique_and_categories_map_to_expenses() {
        let mut codes: Vec<&str> = CHART.iter().map(|a| a.code).collect();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), CHART.len());
        for c in [
            "PERSONNEL",
            "CLEANING",
            "ENERGY",
            "WATER",
            "MAINTENANCE",
            "INSURANCE",
            "MANAGEMENT_FEE",
            "SECURITY",
            "GARDENING",
            "RESERVE",
            "OTHER",
        ] {
            assert!(account(expense_account(c)).is_some(), "{}", c);
        }
    }

    #[test]
    fn manual_entries_must_balance_on_known_accounts() {
        let ok = vec![
            Posting::debit(RESERVE_APPROPRIATION, d("500.00")),
            Posting::credit(RESERVE_FUND, d("500.00")),
        ];
        assert!(validate_entry(&ok).is_ok());
        assert_eq!(validate_entry(&ok[..1]), Err(JournalError::TooFewLines));
        let unbalanced = vec![Posting::debit(BANK, d("10")), Posting::credit(CASH, d("9"))];
        assert!(matches!(
            validate_entry(&unbalanced),
            Err(JournalError::Unbalanced(_, _))
        ));
        let unknown = vec![Posting::debit("999", d("1")), Posting::credit(CASH, d("1"))];
        assert!(matches!(
            validate_entry(&unknown),
            Err(JournalError::UnknownAccount(0, _))
        ));
        let both = vec![
            Posting {
                account: BANK.into(),
                debit: d("1"),
                credit: d("1"),
            },
            Posting::credit(CASH, d("0")),
        ];
        assert_eq!(validate_entry(&both), Err(JournalError::LineAmount(0)));
    }

    #[test]
    fn trial_balance_balances_and_uses_the_normal_side() {
        let lines = vec![
            Posting::debit(DUES_RECEIVABLE, d("1000")),
            Posting::credit(OPERATING_DUES_REVENUE, d("1000")),
            Posting::debit(BANK, d("400")),
            Posting::credit(DUES_RECEIVABLE, d("400")),
        ];
        let tb = trial_balance(&lines);
        let debit: Decimal = tb.iter().map(|r| r.debit).sum();
        let credit: Decimal = tb.iter().map(|r| r.credit).sum();
        assert_eq!(debit, credit);
        let receivable = tb.iter().find(|r| r.account == DUES_RECEIVABLE);
        assert_eq!(receivable.map(|r| r.balance), Some(d("600")));
        let revenue = tb.iter().find(|r| r.account == OPERATING_DUES_REVENUE);
        assert_eq!(revenue.map(|r| r.balance), Some(d("1000")));
        assert!(is_balanced(&lines));
    }
}
