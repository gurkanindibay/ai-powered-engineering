"""Reasons for strict xfail markers that several test modules share (see GUI_TEST_PLAN.md §8)."""

PENDING_QUEUE_GAP = ("GAP: the client never loads GET /api/v1/registration/pending; the cockpit queue is only "
                     "filled by DashboardController.setPendingRegistrationsForTesting, so submitted "
                     "registrations never reach the manager (flutter/lib/ui/dashboard/dashboard_controller.dart)")

RECONCILIATION_NOT_PERSISTED = (
    "BUG: confirming matched statement rows only updates client state; DashboardController.confirmReconciliation "
    "sends nothing to the backend, so no payment, receipt or liability change is stored "
    "(flutter/lib/ui/dashboard/dashboard_controller.dart)")

OPERATIONAL_DUES_DEBTOR = (
    "BUG: POST /api/v1/dues/accrue-period writes debtor_type = TENANT for owner-occupied units (no tenant), so the "
    "owner's operational dues sit on a tenant ledger")

BANK_ACCOUNT_NOT_LOADED = (
    "BUG (STORY-07-06): the client never loads the site bank account (only setSiteBankAccountForTesting sets it), so "
    "the statement format guard is skipped: an MT940 .sta file is accepted for the Kuveyt Türk EXCEL account")

WEBHOOK_PENALTY_NOT_COLLECTED = (
    "BUG (STORY-07-03/07-05, 09-02): an incoming FAST transfer is not allocated to the KMK penalty: paying the full "
    "total (₺1.423,33) leaves ₺23,33 open, and overpaying ₺2.860,67 shows an advance of ₺1.460,67 (payment minus "
    "principal only)")

LIABILITY_ID_SEQUENCE = (
    "BUG: accrue-period inserts dues_liabilities with explicit ids but leaves the identity sequence behind "
    "(ids 1,2 exist, dues_liabilities_id_seq next value is 1), so the next identity insert, e.g. accrue-installment, "
    "fails with 400 'db error' until the sequence passes the existing ids")
