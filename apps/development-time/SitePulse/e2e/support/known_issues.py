"""Reasons for strict xfail markers that several test modules share (see GUI_TEST_PLAN.md §8)."""

DEPARTED_TENANT_KEEPS_LATER_ACCRUAL = (
    "BUG #277: a move-out recorded late for 2026-11-25 re-issues only the November split; the 'Aralık 2026' liability "
    "accrued meanwhile stays with the departed tenant and the owner is not charged")
