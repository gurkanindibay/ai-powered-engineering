"""Reasons for strict xfail markers that several test modules share (see GUI_TEST_PLAN.md §8)."""

PENDING_QUEUE_GAP = ("GAP: the client never loads GET /api/v1/registration/pending; the cockpit queue is only "
                     "filled by DashboardController.setPendingRegistrationsForTesting, so submitted "
                     "registrations never reach the manager (flutter/lib/ui/dashboard/dashboard_controller.dart)")

RECONCILIATION_NOT_PERSISTED = (
    "BUG: confirming matched statement rows only updates client state; DashboardController.confirmReconciliation "
    "sends nothing to the backend, so no payment, receipt or liability change is stored "
    "(flutter/lib/ui/dashboard/dashboard_controller.dart)")

BANK_ACCOUNT_NOT_LOADED = (
    "BUG (STORY-07-06): the client never loads the site bank account (only setSiteBankAccountForTesting sets it), so "
    "the statement format guard is skipped: an MT940 .sta file is accepted for the Kuveyt Türk EXCEL account")
