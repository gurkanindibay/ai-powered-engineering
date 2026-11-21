"""Reasons for strict xfail markers that several test modules share (see GUI_TEST_PLAN.md §8)."""

JOINT_OWNER_TRANSFER_DAY_OVERLAP = (
    "BUG #276: on a title transfer with the tenant staying, seller and buyer are both jointly liable on the transfer "
    "day (seller liable through 2026-12-15 instead of 2026-12-14), see dues_repository.rs accrual of tenant liabilities")

DEPARTED_TENANT_KEEPS_LATER_ACCRUAL = (
    "BUG #277: a move-out recorded late for 2026-11-25 re-issues only the November split; the 'Aralık 2026' liability "
    "accrued meanwhile stays with the departed tenant and the owner is not charged")
