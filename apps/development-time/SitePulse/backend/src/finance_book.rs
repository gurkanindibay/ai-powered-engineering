//! In-memory copy of every SPEC-009 aggregate (`AppStateInner::finance`).
//!
//! With PostgreSQL it is loaded at boot (`db::finance_store::load_finance_book`)
//! and every change is written to the database first, by
//! `db::finance_store::FinanceStore`, before it is applied here.

use std::collections::HashMap;

use chrono::NaiveDate;

use crate::models::*;

#[derive(Debug, Clone, Default)]
pub struct FinanceBook {
    pub privacy_notices: Vec<PrivacyNotice>,
    pub privacy_acknowledgements: Vec<PrivacyAcknowledgement>,
    pub consents: Vec<CommunicationConsent>,
    pub access_log: Vec<FinancialAccessLogEntry>,
    pub retention_policies: Vec<RetentionPolicy>,
    pub leases: Vec<TenancyLease>,
    pub notifications: Vec<Notification>,
    pub dunning_policies: Vec<DunningPolicy>,
    pub dunning_actions: Vec<DunningAction>,
    pub virman_requests: Vec<VirmanRequest>,
    pub disputes: Vec<LedgerDispute>,
    pub payment_methods: Vec<SavedPaymentMethod>,
    pub mandates: Vec<AutopayMandate>,
    pub autopay_attempts: Vec<AutopayAttempt>,
    pub vendors: Vec<Vendor>,
    pub approval_policies: Vec<ExpenseApprovalPolicy>,
    pub expenses: Vec<ExpenseInvoice>,
    pub expense_payments: Vec<ExpensePayment>,
    pub journal_entries: Vec<ManualJournalEntry>,
    pub journal_lines: Vec<ManualJournalLine>,
    pub cases: Vec<CollectionCase>,
    pub case_events: Vec<CollectionCaseEvent>,
    pub bank_feeds: Vec<BankFeedConnection>,
    pub bank_reconciliations: Vec<BankReconciliationRun>,
    pub plans: Vec<PaymentPlan>,
    pub plan_installments: Vec<PaymentPlanInstallment>,
    pub adjustments: Vec<LedgerAdjustment>,
    pub corrections: Vec<AccrualCorrection>,
    pub heat_periods: Vec<HeatCostPeriod>,
    pub heat_readings: Vec<HeatMeterReading>,
    pub heat_shares: Vec<HeatCostShare>,
    pub meetings: Vec<AssemblyMeeting>,
    pub agenda_items: Vec<AssemblyAgendaItem>,
    pub attendance: Vec<AssemblyAttendance>,
    pub votes: Vec<AssemblyVote>,
    pub decisions: Vec<AssemblyDecision>,
    pub companies: Vec<ManagementCompany>,
    pub company_sites: Vec<ManagementCompanySite>,
    pub company_members: Vec<ManagementCompanyMember>,
    pub fee_invoices: Vec<FeeInvoice>,
    /// Site id -> last day of the budget transition (R1).
    pub budget_transitions: HashMap<String, NaiveDate>,
    /// Payment intent id -> (card instalments, save card) (R6).
    pub intent_options: HashMap<String, (i32, bool)>,
    /// Budget id -> assembly decision id (R1/R12).
    pub budget_decisions: HashMap<String, i64>,
}

/// Collection selectors for `db::finance_store::FinanceStore` (one per record type).
pub mod col {
    use super::FinanceBook;
    use crate::models::*;

    pub fn privacy_notices(b: &mut FinanceBook) -> &mut Vec<PrivacyNotice> {
        &mut b.privacy_notices
    }
    pub fn privacy_acknowledgements(b: &mut FinanceBook) -> &mut Vec<PrivacyAcknowledgement> {
        &mut b.privacy_acknowledgements
    }
    pub fn consents(b: &mut FinanceBook) -> &mut Vec<CommunicationConsent> {
        &mut b.consents
    }
    pub fn access_log(b: &mut FinanceBook) -> &mut Vec<FinancialAccessLogEntry> {
        &mut b.access_log
    }
    pub fn retention_policies(b: &mut FinanceBook) -> &mut Vec<RetentionPolicy> {
        &mut b.retention_policies
    }
    pub fn leases(b: &mut FinanceBook) -> &mut Vec<TenancyLease> {
        &mut b.leases
    }
    pub fn notifications(b: &mut FinanceBook) -> &mut Vec<Notification> {
        &mut b.notifications
    }
    pub fn dunning_policies(b: &mut FinanceBook) -> &mut Vec<DunningPolicy> {
        &mut b.dunning_policies
    }
    pub fn dunning_actions(b: &mut FinanceBook) -> &mut Vec<DunningAction> {
        &mut b.dunning_actions
    }
    pub fn virman_requests(b: &mut FinanceBook) -> &mut Vec<VirmanRequest> {
        &mut b.virman_requests
    }
    pub fn disputes(b: &mut FinanceBook) -> &mut Vec<LedgerDispute> {
        &mut b.disputes
    }
    pub fn payment_methods(b: &mut FinanceBook) -> &mut Vec<SavedPaymentMethod> {
        &mut b.payment_methods
    }
    pub fn mandates(b: &mut FinanceBook) -> &mut Vec<AutopayMandate> {
        &mut b.mandates
    }
    pub fn autopay_attempts(b: &mut FinanceBook) -> &mut Vec<AutopayAttempt> {
        &mut b.autopay_attempts
    }
    pub fn vendors(b: &mut FinanceBook) -> &mut Vec<Vendor> {
        &mut b.vendors
    }
    pub fn approval_policies(b: &mut FinanceBook) -> &mut Vec<ExpenseApprovalPolicy> {
        &mut b.approval_policies
    }
    pub fn expenses(b: &mut FinanceBook) -> &mut Vec<ExpenseInvoice> {
        &mut b.expenses
    }
    pub fn expense_payments(b: &mut FinanceBook) -> &mut Vec<ExpensePayment> {
        &mut b.expense_payments
    }
    pub fn journal_entries(b: &mut FinanceBook) -> &mut Vec<ManualJournalEntry> {
        &mut b.journal_entries
    }
    pub fn journal_lines(b: &mut FinanceBook) -> &mut Vec<ManualJournalLine> {
        &mut b.journal_lines
    }
    pub fn cases(b: &mut FinanceBook) -> &mut Vec<CollectionCase> {
        &mut b.cases
    }
    pub fn case_events(b: &mut FinanceBook) -> &mut Vec<CollectionCaseEvent> {
        &mut b.case_events
    }
    pub fn bank_feeds(b: &mut FinanceBook) -> &mut Vec<BankFeedConnection> {
        &mut b.bank_feeds
    }
    pub fn bank_reconciliations(b: &mut FinanceBook) -> &mut Vec<BankReconciliationRun> {
        &mut b.bank_reconciliations
    }
    pub fn plans(b: &mut FinanceBook) -> &mut Vec<PaymentPlan> {
        &mut b.plans
    }
    pub fn plan_installments(b: &mut FinanceBook) -> &mut Vec<PaymentPlanInstallment> {
        &mut b.plan_installments
    }
    pub fn adjustments(b: &mut FinanceBook) -> &mut Vec<LedgerAdjustment> {
        &mut b.adjustments
    }
    pub fn corrections(b: &mut FinanceBook) -> &mut Vec<AccrualCorrection> {
        &mut b.corrections
    }
    pub fn heat_periods(b: &mut FinanceBook) -> &mut Vec<HeatCostPeriod> {
        &mut b.heat_periods
    }
    pub fn heat_readings(b: &mut FinanceBook) -> &mut Vec<HeatMeterReading> {
        &mut b.heat_readings
    }
    pub fn heat_shares(b: &mut FinanceBook) -> &mut Vec<HeatCostShare> {
        &mut b.heat_shares
    }
    pub fn meetings(b: &mut FinanceBook) -> &mut Vec<AssemblyMeeting> {
        &mut b.meetings
    }
    pub fn agenda_items(b: &mut FinanceBook) -> &mut Vec<AssemblyAgendaItem> {
        &mut b.agenda_items
    }
    pub fn attendance(b: &mut FinanceBook) -> &mut Vec<AssemblyAttendance> {
        &mut b.attendance
    }
    pub fn votes(b: &mut FinanceBook) -> &mut Vec<AssemblyVote> {
        &mut b.votes
    }
    pub fn decisions(b: &mut FinanceBook) -> &mut Vec<AssemblyDecision> {
        &mut b.decisions
    }
    pub fn companies(b: &mut FinanceBook) -> &mut Vec<ManagementCompany> {
        &mut b.companies
    }
    pub fn company_sites(b: &mut FinanceBook) -> &mut Vec<ManagementCompanySite> {
        &mut b.company_sites
    }
    pub fn company_members(b: &mut FinanceBook) -> &mut Vec<ManagementCompanyMember> {
        &mut b.company_members
    }
    pub fn fee_invoices(b: &mut FinanceBook) -> &mut Vec<FeeInvoice> {
        &mut b.fee_invoices
    }
}
