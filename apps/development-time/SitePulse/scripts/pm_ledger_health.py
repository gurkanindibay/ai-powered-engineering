#!/usr/bin/env python3
"""SitePulse ledger health verification and bug bundle export.

The Product Manager Workbench (``pm_workbench_web.py``) calls this module when
the PM clicks **Verify Ledger Health** or **Export Bug Bundle** after manual
exploratory testing. The module answers two questions:

1. Does the seeded site's ledger still obey the journey invariants I1-I12
   (``docs/testing/journey-plan/README.md`` section 4) and the site-scoped rows
   of ``v_integrity_violations``? Checks that a single ledger snapshot can prove
   run as exact SQL. Checks that need a second surface, a restart or a dated
   approval journey are reported as ``MANUAL`` together with the automated suite
   that covers them, never as a silent pass.
2. Can an engineer reproduce the bug from the exported Markdown bundle? The
   bundle carries the active preset, simulated clock, site, personas (without
   passwords), the health scorecard and the recent backend 4xx/5xx responses
   correlated by ``x-request-id`` / ``trace_id``. Every value passes through the
   redaction rules of ``docs/standards/LOGGING_STANDARDS.md`` section 5.

Scope note: the finance-phase view ``v_finance_integrity_violations`` is
asserted by the payments E2E suite, not by this snapshot checker. The workbench
checker covers the ledger facts a PM can break from the seeded presets:
liabilities, allocations, advances, reversals, reconciliation scope, late fees
and due dates. Keeping one documented snapshot scope is what makes "a clean
preset is 100% green" a trustworthy claim.

Design rules:

* Standard library only; PostgreSQL is reached through the shared
  ``pm_scenarios.seeder.PsqlRunner``, the same runner the scenario seeder uses.
* Monetary values are rendered as exact decimal text end to end; no value is
  parsed into a float.
* SQL that embeds the site id only ever receives a validated integer.
* Log parsing keeps a whitelist of structured request fields and drops
  free-text messages, so payer names and other PII cannot leak into an issue.

CLI::

    python3 scripts/pm_ledger_health.py check --site-id 12
    python3 scripts/pm_ledger_health.py bundle --site-id 12 --preset F5
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

DEFAULT_BACKEND_LOG_PATH = Path("/tmp/sitepulse-workbench-backend.log")
DEFAULT_MAX_ERROR_ENTRIES = 20
DEFAULT_LOG_TAIL_BYTES = 256 * 1024

# Status vocabulary shared by the API, the UI and the tests.
STATUS_PASS = "PASS"
STATUS_FAIL = "FAIL"
STATUS_MANUAL = "MANUAL"
STATUS_ERROR = "ERROR"

OVERALL_GREEN = "GREEN"
OVERALL_RED = "RED"

REDACTED = "[redacted]"

SITE_ID_PATTERN = re.compile(r"^[1-9][0-9]*$")


def _normalize_sql(sql: str) -> str:
    """Collapses indentation so an embedded site id is the only variable part."""
    return " ".join(sql.split())


# ---------------------------------------------------------------------------
# Invariants and their site-scoped SQL
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class SqlCheck:
    """One SQL statement that returns ``check_name | subject | detail`` rows."""

    name: str
    description: str
    sql: str


@dataclass(frozen=True)
class Invariant:
    """One ledger invariant, automated through SQL or explicitly manual."""

    invariant_id: str
    title: str
    explanation: str
    remediation: str
    checks: tuple[SqlCheck, ...] = ()
    manual_reason: str = ""
    manual_suite: str = ""

    @property
    def automated(self) -> bool:
        return bool(self.checks)


def _check(name: str, description: str, sql: str) -> SqlCheck:
    return SqlCheck(name=name, description=description, sql=_normalize_sql(sql))


INVARIANTS: tuple[Invariant, ...] = (
    Invariant(
        invariant_id="I1",
        title="Debt components add up to the booked payment",
        explanation=(
            "A liability's paid amount is its paid principal plus its paid fee, each component stays "
            "inside what was owed, a cancelled charge carries no money, and the payment allocations "
            "reconcile to what the liability records as paid."
        ),
        remediation="Reset the preset; if it persists, attach the failing liability ids to the bug bundle.",
        checks=(
            _check(
                "debt_components",
                "Paid amount, paid principal, paid fee and status agree on the liability.",
                """
                SELECT 'debt_components',
                       d.id::text,
                       'paid_amount=' || d.paid_amount ||
                       ', paid_principal=' || d.paid_principal ||
                       ', paid_penalty=' || d.paid_penalty ||
                       ', principal=' || d.principal_amount ||
                       ', penalty=' || d.delay_penalty ||
                       ', status=' || d.status
                FROM dues_liabilities d
                JOIN units u ON u.id = d.unit_id
                WHERE u.site_id = {site}
                  AND (
                      d.paid_amount <> d.paid_principal + d.paid_penalty
                      OR d.paid_principal < 0 OR d.paid_principal > d.principal_amount
                      OR d.paid_penalty < 0 OR d.paid_penalty > d.delay_penalty
                      OR (d.status = 'CANCELLED'
                          AND (d.paid_principal <> 0 OR d.paid_penalty <> 0 OR d.paid_amount <> 0))
                  )
                """,
            ),
            _check(
                "allocations_vs_dues_paid",
                "Payment allocations add up to the liability's recorded paid components.",
                """
                -- Mirrors ``allocations_vs_dues_paid`` in
                -- backend/migrations/V39__advance_exit_settlements.sql: an
                -- allocation of a REVERSED payment no longer counts as paid.
                SELECT 'allocations_vs_dues_paid',
                       d.id::text,
                       'recorded=' || (d.paid_principal + d.paid_penalty) ||
                       ', allocated=' || COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)
                FROM dues_liabilities d
                JOIN units u ON u.id = d.unit_id
                LEFT JOIN payment_allocations pa ON pa.dues_liability_id = d.id
                    AND NOT EXISTS (
                        SELECT 1 FROM payment_entries re
                        WHERE re.id = pa.payment_entry_id
                          AND re.settlement_status = 'REVERSED'
                    )
                WHERE u.site_id = {site}
                GROUP BY d.id
                HAVING EXISTS (SELECT 1 FROM payment_allocations x WHERE x.dues_liability_id = d.id)
                   AND d.paid_principal + d.paid_penalty
                       <> COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)
                """,
            ),
        ),
    ),
    Invariant(
        invariant_id="I2",
        title="Site total equals the sum of unit balances",
        explanation="The collection dashboard total must equal the sum of the unit balances it lists.",
        remediation="Compare the dashboard total with the unit table and attach both to the bug bundle.",
        manual_reason="The dashboard total is an API read model, not a stored ledger column.",
        manual_suite="e2e/tests/test_journey_accruals_payments.py",
    ),
    Invariant(
        invariant_id="I3",
        title="Dashboard and workspace agree on the same debt",
        explanation=(
            "The collection dashboard and the unit workspace must show the same debt and the same "
            "payment history for the same unit, debtor and ledger type."
        ),
        remediation="Open the unit workspace next to the dashboard and attach both screens.",
        manual_reason="Requires two authenticated GUI surfaces in the same session.",
        manual_suite="e2e/tests/test_journey_financial_transitions.py",
    ),
    Invariant(
        invariant_id="I4",
        title="Each payment is counted once and advances stay with their debtor",
        explanation=(
            "A reversal points at the settled original it reverses, and every advance balance equals "
            "the net of the advance ledger for the same unit and debtor."
        ),
        remediation="Reset the preset; if it persists, attach the failing payment or advance ids.",
        checks=(
            _check(
                "reversal_links_original",
                "A reversal names the same-site original payment it reverses.",
                """
                SELECT 'reversal_links_original',
                       r.id::text,
                       'reverses=' || COALESCE(r.reverses_entry_id::text, 'null')
                FROM payment_entries r
                WHERE r.site_id = {site}
                  AND r.entry_type = 'REVERSAL'
                  AND NOT EXISTS (
                      SELECT 1
                      FROM payment_entries o
                      WHERE o.id = r.reverses_entry_id
                        AND o.site_id = r.site_id
                        AND o.settlement_status = 'REVERSED'
                  )
                """,
            ),
            _check(
                "advance_balance_vs_ledger",
                "The stored advance balance equals the net of its advance ledger entries.",
                """
                -- The sign map mirrors ``advance_balance_vs_ledger`` in
                -- backend/migrations/V39__advance_exit_settlements.sql; new
                -- credit entry types must be added in both places.
                SELECT 'advance_balance_vs_ledger',
                       ab.unit_id::text || '/' || ab.debtor_type,
                       'balance=' || ab.balance || ', ledger=' || COALESCE(l.net, 0)
                FROM advance_balances ab
                JOIN units u ON u.id = ab.unit_id
                LEFT JOIN (
                    SELECT unit_id,
                           debtor_type,
                           SUM(CASE WHEN entry_type IN (
                                        'PAYMENT_SURPLUS',
                                        'ADJUSTMENT_CREDIT',
                                        'VIRMAN_REVERSAL',
                                        'EXIT_TRANSFER_CREDIT'
                                    ) THEN amount
                                    WHEN entry_type = 'ADJUSTMENT' THEN 0
                                    ELSE -amount END) AS net
                    FROM advance_ledger_entries
                    GROUP BY unit_id, debtor_type
                ) l ON l.unit_id = ab.unit_id AND l.debtor_type = ab.debtor_type
                WHERE u.site_id = {site}
                  AND ab.balance <> COALESCE(l.net, 0)
                """,
            ),
        ),
    ),
    Invariant(
        invariant_id="I5",
        title="Period shares add up to the prorated tariff",
        explanation=(
            "For each unit and period, the shares add up to the tariff prorated for chargeable days; "
            "pre-creation and unassigned days contribute zero."
        ),
        remediation="Re-open the accrual preview and attach the period, unit and share rows.",
        manual_reason=(
            "The tariff and chargeable-day inputs behind a charge are not persisted per charge, so a "
            "snapshot cannot recompute the expected share."
        ),
        manual_suite="e2e/tests/test_journey_accrual_corner_cases.py",
    ),
    Invariant(
        invariant_id="I6",
        title="Every collectible charge names one primary debtor",
        explanation=(
            "A collectible liability has exactly one primary debtor, and a recorded occupancy belongs "
            "to the same unit as the liability. A cancelled charge stays in audit history with zero "
            "outstanding and no money attached."
        ),
        remediation="Reset the preset; if it persists, attach the liability, occupancy and unit ids.",
        checks=(
            _check(
                "liability_primary_debtor",
                "A collectible liability has a liable person, and its occupancy matches its unit.",
                """
                SELECT 'liability_primary_debtor',
                       d.id::text,
                       'debtor_type=' || d.debtor_type ||
                       ', liable_person=' || COALESCE(d.liable_person_id::text, 'null') ||
                       ', occupancy=' || COALESCE(d.occupancy_id::text, 'null')
                FROM dues_liabilities d
                JOIN units u ON u.id = d.unit_id
                LEFT JOIN unit_occupancies o ON o.id = d.occupancy_id
                WHERE u.site_id = {site}
                  AND (
                      (d.liable_person_id IS NULL
                       AND d.status <> 'CANCELLED'
                       AND (d.principal_amount > 0 OR d.delay_penalty > 0))
                      OR (d.occupancy_id IS NOT NULL AND o.unit_id IS DISTINCT FROM d.unit_id)
                  )
                """,
            ),
        ),
    ),
    Invariant(
        invariant_id="I7",
        title="Historical debt stays with its original debtor",
        explanation=(
            "An approved dated correction changes only the authorized dates and amounts and keeps the "
            "original audit trail."
        ),
        remediation="Run the liability-change journey against this preset and inspect the audit history.",
        manual_reason="Needs a dated correction journey with an approval step.",
        manual_suite="e2e/tests/test_journey_liability_changes.py",
    ),
    Invariant(
        invariant_id="I8",
        title="Balances survive a backend restart",
        explanation="Memory and PostgreSQL must agree after the backend restarts.",
        remediation="Restart the backend, reload the same page and compare; attach both readings.",
        manual_reason="Requires stopping and starting the backend process.",
        manual_suite="e2e/tests/test_journey_fixtures.py",
    ),
    Invariant(
        invariant_id="I9",
        title="Displayed amounts equal the API to the kurush",
        explanation="Every amount a screen shows equals the API response for the same field.",
        remediation="Attach the screen and the API response captured in the bug bundle.",
        manual_reason="Requires comparing a GUI surface with the API response.",
        manual_suite="e2e/tests/test_journey_starting_states_gui.py",
    ),
    Invariant(
        invariant_id="I10",
        title="Every financial row stays inside its own site",
        explanation=(
            "A reconciliation queue row only points at a bank account and a unit that belong to the "
            "same site, so one site can never read or settle another site's money."
        ),
        remediation="Reset the preset; if it persists, attach the queue ids and both site ids.",
        checks=(
            _check(
                "reconciliation_site_scope",
                "The queue row, its bank account and its matched unit share one site.",
                """
                SELECT 'reconciliation_site_scope',
                       rq.match_id,
                       'queue_site=' || rq.site_id ||
                       ', bank_site=' || COALESCE(sba.site_id::text, 'null') ||
                       ', matched_unit=' || COALESCE(rq.matched_unit_id::text, 'null')
                FROM reconciliation_queue rq
                LEFT JOIN site_bank_accounts sba ON sba.id = rq.site_bank_account_id
                WHERE rq.site_id = {site}
                  AND (
                      (sba.id IS NOT NULL AND sba.site_id <> rq.site_id)
                      OR (rq.matched_unit_id IS NOT NULL AND NOT EXISTS (
                          SELECT 1 FROM units u
                          WHERE u.id = rq.matched_unit_id AND u.site_id = rq.site_id
                      ))
                  )
                """,
            ),
        ),
    ),
    Invariant(
        invariant_id="I11",
        title="Late fees and aging start at the effective due date",
        explanation=(
            "A charge's effective due date is never before the day the charge existed, and every late "
            "fee segment starts on that effective due date."
        ),
        remediation="Reset the preset; if it persists, attach the liability and late-fee segment rows.",
        checks=(
            _check(
                "effective_due_date_not_before_creation",
                "The effective due date is not earlier than the charge's creation date.",
                """
                SELECT 'effective_due_date_not_before_creation',
                       d.id::text,
                       'effective_due_date=' || d.effective_due_date ||
                       ', created_on=' || (d.created_at AT TIME ZONE 'Europe/Istanbul')::date
                FROM dues_liabilities d
                JOIN units u ON u.id = d.unit_id
                WHERE u.site_id = {site}
                  AND d.effective_due_date < (d.created_at AT TIME ZONE 'Europe/Istanbul')::date
                """,
            ),
            _check(
                "late_fee_segment_before_effective_due_date",
                "A late-fee segment starts no earlier than the effective due date.",
                """
                SELECT 'late_fee_segment_before_effective_due_date',
                       lfa.id::text,
                       'segment_start=' || lfa.segment_start ||
                       ', effective_due_date=' || d.effective_due_date
                FROM late_fee_accruals lfa
                JOIN dues_liabilities d ON d.id = lfa.due_id
                WHERE lfa.site_id = {site}
                  AND lfa.segment_start < d.effective_due_date
                """,
            ),
        ),
    ),
    Invariant(
        invariant_id="I12",
        title="A title transfer moves no existing charge",
        explanation=(
            "A sale changes only charges accrued after its effective date, or an approved seller-pays "
            "override; older charges keep their original debtor."
        ),
        remediation="Run the occupancy-change journey and compare the pre-sale and post-sale ledger.",
        manual_reason="Needs a sale journey with a second approver.",
        manual_suite="e2e/tests/test_journey_occupancy_changes.py",
    ),
)

INVARIANTS_BY_ID: dict[str, Invariant] = {
    invariant.invariant_id: invariant for invariant in INVARIANTS
}

# The integrity view the issue names. Each row is scoped back to the active site
# through the table that owns the subject id, so a PM never sees another site's
# violation.
INTEGRITY_VIEW_SQL = """
SELECT v.check_name,
       v.subject,
       CASE v.check_name
           WHEN 'advance_balance_vs_ledger'
               THEN 'balance differs from the advance ledger by ' || v.difference
           WHEN 'installment_percentages'
               THEN 'installment percentages differ from 100 by ' || v.difference
           WHEN 'allocations_vs_dues_paid'
               THEN 'allocations differ from paid components by ' || v.difference
           ELSE 'difference=' || v.difference
       END
FROM v_integrity_violations v
WHERE (v.check_name = 'advance_balance_vs_ledger'
       AND EXISTS (SELECT 1 FROM units u
                   WHERE u.site_id = {site}
                     AND u.id::text = split_part(v.subject, '/', 1)))
   OR (v.check_name = 'installment_percentages'
       AND EXISTS (SELECT 1 FROM capital_projects cp
                   WHERE cp.site_id = {site} AND cp.id::text = v.subject))
   OR (v.check_name = 'allocations_vs_dues_paid'
       AND EXISTS (SELECT 1 FROM dues_liabilities d
                   JOIN units u ON u.id = d.unit_id
                   WHERE u.site_id = {site} AND d.id::text = v.subject))
ORDER BY v.check_name, v.subject
"""

VIEW_CHECK_TITLES: dict[str, str] = {
    "advance_balance_vs_ledger": "Advance balance versus advance ledger",
    "installment_percentages": "Capital installment percentages sum to 100",
    "allocations_vs_dues_paid": "Payment allocations versus the liability's paid components",
}


# ---------------------------------------------------------------------------
# Health report model
# ---------------------------------------------------------------------------


class LedgerHealthError(Exception):
    """The health check cannot run at all (for example the site id is invalid)."""


@dataclass(frozen=True)
class Violation:
    """One failing row returned by a site-scoped check."""

    check_name: str
    subject: str
    detail: str

    def to_dict(self) -> dict[str, str]:
        return {"check_name": self.check_name, "subject": self.subject, "detail": self.detail}


@dataclass
class InvariantResult:
    invariant_id: str
    title: str
    explanation: str
    status: str
    remediation: str = ""
    manual_reason: str = ""
    manual_suite: str = ""
    check_titles: list[str] = field(default_factory=list)
    violations: list[Violation] = field(default_factory=list)
    error: str = ""

    @property
    def automated(self) -> bool:
        """Whether an SQL check produced this result, rather than a GUI journey."""
        return self.status != STATUS_MANUAL

    def to_dict(self) -> dict[str, Any]:
        return {
            "invariant_id": self.invariant_id,
            "title": self.title,
            "explanation": self.explanation,
            "status": self.status,
            "automated": self.status != STATUS_MANUAL,
            "remediation": self.remediation,
            "manual_reason": self.manual_reason,
            "manual_suite": self.manual_suite,
            "check_titles": list(self.check_titles),
            "violations": [violation.to_dict() for violation in self.violations],
            "error": self.error,
        }


@dataclass
class LedgerHealthReport:
    site_id: str
    status: str
    checked_at: str
    invariants: list[InvariantResult]
    view_violations: list[Violation] = field(default_factory=list)
    view_error: str = ""

    def _count(self, status: str) -> int:
        return sum(1 for result in self.invariants if result.status == status)

    @property
    def passed_count(self) -> int:
        return self._count(STATUS_PASS)

    @property
    def failed_count(self) -> int:
        return self._count(STATUS_FAIL)

    @property
    def error_count(self) -> int:
        return self._count(STATUS_ERROR)

    @property
    def manual_count(self) -> int:
        return self._count(STATUS_MANUAL)

    @property
    def automated_count(self) -> int:
        return len(self.invariants) - self.manual_count

    def to_dict(self) -> dict[str, Any]:
        return {
            "site_id": self.site_id,
            "status": self.status,
            "checked_at": self.checked_at,
            "passed_count": self.passed_count,
            "failed_count": self.failed_count,
            "error_count": self.error_count,
            "automated_count": self.automated_count,
            "manual_count": self.manual_count,
            "view_error": self.view_error,
            "integrity_view": {
                "view": "v_integrity_violations",
                "violations": [violation.to_dict() for violation in self.view_violations],
            },
            "invariants": [result.to_dict() for result in self.invariants],
        }


def validate_site_id(site_id: Any) -> str:
    """Returns the site id as digits, refusing anything else (SQL is built from it)."""
    text = str(site_id).strip()
    if not SITE_ID_PATTERN.fullmatch(text):
        raise LedgerHealthError(
            f"Site id {site_id!r} is not a positive integer id; the ledger check only accepts integer ids."
        )
    return text


def parse_check_rows(raw: str) -> list[Violation]:
    """Parses psql ``-At`` output of ``check_name | subject | detail`` rows."""
    violations: list[Violation] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|", 2)
        if len(parts) != 3:
            # A malformed row surfaces instead of disappearing: it means the
            # check itself is broken, not that the ledger is clean.
            violations.append(
                Violation("unparsed_check_row", line[:120], "The check returned an unexpected row shape.")
            )
            continue
        violations.append(Violation(parts[0], parts[1], parts[2]))
    return violations


def _describe_error(err: BaseException) -> str:
    message = str(err).strip()
    return message or err.__class__.__name__


class LedgerHealthChecker:
    """Runs the site-scoped ledger checks against PostgreSQL.

    ``sql_fn`` is injected by the tests (and can point at another database
    runner). By default the shared ``PsqlRunner`` from the scenario seeder is
    used, so the workbench needs no extra credentials or stack configuration.
    """

    def __init__(
        self, *, sql_fn: Callable[[str], str] | None = None, db_name: str = "sitepulse"
    ) -> None:
        self._sql_fn = sql_fn
        self._db_name = db_name

    def _run_sql(self, sql: str) -> str:
        if self._sql_fn is not None:
            return self._sql_fn(sql)
        # Imported late so the module stays cheap to import in the UI process.
        from pm_scenarios.seeder import PsqlRunner

        return PsqlRunner(db_name=self._db_name).run(sql)

    def check(self, site_id: Any) -> LedgerHealthReport:
        site = validate_site_id(site_id)
        results: list[InvariantResult] = []
        for invariant in INVARIANTS:
            if not invariant.automated:
                results.append(self._manual_result(invariant))
                continue
            violations: list[Violation] = []
            error = ""
            for check in invariant.checks:
                try:
                    violations.extend(parse_check_rows(self._run_sql(check.sql.format(site=site))))
                except Exception as err:  # noqa: BLE001 - reported as ERROR, never raised to the UI
                    error = _describe_error(err)
                    break
            results.append(self._invariant_result(invariant, violations=violations, error=error))

        view_violations: list[Violation] = []
        view_error = ""
        try:
            view_violations = parse_check_rows(
                self._run_sql(INTEGRITY_VIEW_SQL.format(site=site))
            )
        except Exception as err:  # noqa: BLE001 - reported in the scorecard
            view_error = _describe_error(err)

        red = (
            any(result.status in (STATUS_FAIL, STATUS_ERROR) for result in results)
            or bool(view_violations)
            or bool(view_error)
        )
        return LedgerHealthReport(
            site_id=site,
            status=OVERALL_RED if red else OVERALL_GREEN,
            checked_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
            invariants=results,
            view_violations=view_violations,
            view_error=view_error,
        )

    @staticmethod
    def _manual_result(invariant: Invariant) -> InvariantResult:
        return InvariantResult(
            invariant_id=invariant.invariant_id,
            title=invariant.title,
            explanation=invariant.explanation,
            status=STATUS_MANUAL,
            remediation=invariant.remediation,
            manual_reason=invariant.manual_reason,
            manual_suite=invariant.manual_suite,
        )

    @staticmethod
    def _invariant_result(
        invariant: Invariant, *, violations: list[Violation], error: str
    ) -> InvariantResult:
        if error:
            status = STATUS_ERROR
        elif violations:
            status = STATUS_FAIL
        else:
            status = STATUS_PASS
        return InvariantResult(
            invariant_id=invariant.invariant_id,
            title=invariant.title,
            explanation=invariant.explanation,
            status=status,
            remediation=invariant.remediation,
            check_titles=[check.description for check in invariant.checks],
            violations=violations,
            error=error,
        )


# ---------------------------------------------------------------------------
# Redaction (LOGGING_STANDARDS.md section 5)
# ---------------------------------------------------------------------------

# The leading ``(?<![A-Za-z0-9])`` rather than ``\b`` lets a prefixed key such
# as ``admin_password`` or ``db_secret`` still match, because ``_`` is a word
# character and would defeat a word boundary.
_SECRET_KEY_PATTERN = re.compile(
    r"(?i)(?<![A-Za-z0-9])(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?token|"
    r"refresh[_-]?token|session[_-]?cookie|authorization|jwt)\b(?!\s*[:=]\s*\[redacted\])"
)
_SECRET_ASSIGNMENT_PATTERN = re.compile(
    r"(?i)(?<![A-Za-z0-9])(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?token|"
    r"refresh[_-]?token|authorization|jwt)\b(\s*[:=]\s*)((?:bearer\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s,;]+))"
)
# ``(?<!\*)`` keeps the mask idempotent: ``m***r@example.test`` is not re-masked
# into ``m****@example.test`` when a value passes through redaction twice.
_EMAIL_PATTERN = re.compile(
    r"(?<!\*)\b([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})"
)
_TR_IBAN_PATTERN = re.compile(r"\bTR\d{2}[0-9A-Z]{16,22}\b")
_TCKN_PATTERN = re.compile(r"\b[1-9]\d{10}\b")
_BEARER_PATTERN = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+")
_LONG_TOKEN_PATTERN = re.compile(r"\b[A-Fa-f0-9]{32,}\b")


def redact_email(value: str) -> str:
    """Masks the local part as ``g***y@example.com`` (section 5, KVKK rule)."""

    def _mask(match: re.Match[str]) -> str:
        local, domain = match.group(1), match.group(2)
        if "***" in local:
            return match.group(0)  # already masked; redaction must be idempotent
        if len(local) == 1:
            return f"*@{domain}"
        if len(local) == 2:
            return f"{local[0]}***@{domain}"
        return f"{local[0]}***{local[-1]}@{domain}"

    return _EMAIL_PATTERN.sub(_mask, value)


def redact_iban(value: str) -> str:
    """Masks a Turkish IBAN keeping the country, bank code and last four digits."""

    def _mask(match: re.Match[str]) -> str:
        raw = match.group(0).replace(" ", "")
        return f"{raw[:4]} •••• •••• •••• •••• ••{raw[-4:-2]} {raw[-2:]}"

    return _TR_IBAN_PATTERN.sub(_mask, value)


def redact_text(value: Any) -> str:
    """Redacts secrets, bearer tokens, e-mails, IBANs and Turkish id numbers."""
    text = "" if value is None else str(value)
    text = _BEARER_PATTERN.sub(f"Bearer {REDACTED}", text)
    text = _SECRET_ASSIGNMENT_PATTERN.sub(
        lambda match: f"{match.group(1)}{match.group(2)}{REDACTED}", text
    )
    text = redact_iban(text)
    text = redact_email(text)
    text = _TCKN_PATTERN.sub(REDACTED, text)
    text = _LONG_TOKEN_PATTERN.sub(REDACTED, text)
    if _SECRET_KEY_PATTERN.search(text):
        # A bare secret word survived without an assignment (for example inside a
        # URL query string); mask the whole token rather than the word.
        text = _SECRET_KEY_PATTERN.sub(REDACTED, text)
    return text


def redact_persona(persona: dict[str, Any]) -> dict[str, str]:
    """Keeps a persona usable for reproduction without its credentials."""
    return {
        "role": redact_text(persona.get("role", "")),
        "name": redact_text(persona.get("name", "")),
        "unit": redact_text(persona.get("unit") or "—"),
        "email": redact_text(persona.get("email", "")),
    }


# ---------------------------------------------------------------------------
# Backend error log parsing
# ---------------------------------------------------------------------------

_LOG_FIELD_PATTERN = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)=("([^"]*)"|\S+)')
_ALLOWED_LOG_FIELDS = ("request_id", "trace_id", "method", "path", "status", "latency_ms")
_STATUS_PATTERN = re.compile(r"^[45][0-9]{2}$")


def read_log_tail(path: Path, max_bytes: int = DEFAULT_LOG_TAIL_BYTES) -> str:
    """Reads at most ``max_bytes`` from the end of the backend log."""
    try:
        with path.open("rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - max_bytes))
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def parse_error_entries(raw: str, *, limit: int = DEFAULT_MAX_ERROR_ENTRIES) -> list[dict[str, str]]:
    """Extracts 4xx/5xx request records from a ``tracing`` log tail.

    Only the whitelisted structured request fields are kept, so free-text log
    messages (which may carry payer names) never reach the exported bundle.
    """
    entries: list[dict[str, str]] = []
    seen: set[str] = set()
    for line in raw.splitlines():
        if "status=" not in line:
            continue
        fields: dict[str, str] = {}
        for match in _LOG_FIELD_PATTERN.finditer(line):
            key = match.group(1)
            if key not in _ALLOWED_LOG_FIELDS:
                continue
            value = match.group(3) if match.group(3) is not None else match.group(2)
            fields[key] = value
        status = fields.get("status", "")
        if not _STATUS_PATTERN.match(status):
            continue
        key = fields.get("request_id") or f"{fields.get('method', '')} {fields.get('path', '')} {status}"
        if key in seen:
            continue
        seen.add(key)
        entries.append(
            {
                "request_id": redact_text(fields.get("request_id", "—")),
                "trace_id": redact_text(fields.get("trace_id", "—")),
                "method": redact_text(fields.get("method", "—")).upper(),
                "path": redact_text(fields.get("path", "—")),
                "status": status,
                "latency_ms": redact_text(fields.get("latency_ms", "—")),
            }
        )
    return entries[-limit:]


# ---------------------------------------------------------------------------
# Bug bundle (Markdown)
# ---------------------------------------------------------------------------

STATUS_ICON = {
    STATUS_PASS: "✅ PASS",
    STATUS_FAIL: "❌ FAIL",
    STATUS_ERROR: "⚠️ ERROR",
    STATUS_MANUAL: "🔎 MANUAL",
}


def _cell(value: Any) -> str:
    """Renders a value as one safe Markdown table cell."""
    text = redact_text(value).replace("|", "\\|").replace("\n", " ").strip()
    return text or "—"


def render_bug_bundle(
    report: LedgerHealthReport,
    *,
    preset: str = "unknown",
    preset_label: str = "",
    site_name: str = "",
    reference_clock: str = "",
    personas: Iterable[dict[str, Any]] = (),
    backend_log_path: Path | str = DEFAULT_BACKEND_LOG_PATH,
    db_name: str = "sitepulse",
    notes: str = "",
    error_limit: int = DEFAULT_MAX_ERROR_ENTRIES,
) -> str:
    """Renders a redacted, self-contained Markdown bug report.

    Everything interpolated here is untrusted (scenario names, persona rows, log
    fields), so every value goes through :func:`redact_text` or :func:`_cell`.
    """
    log_path = Path(backend_log_path)
    error_entries = parse_error_entries(read_log_tail(log_path), limit=error_limit)

    overall = "🟢 GREEN" if report.status == OVERALL_GREEN else "🔴 RED"
    lines: list[str] = [
        "# SitePulse Product Manager Workbench — Bug Report Bundle",
        "",
        f"**Overall ledger health:** {overall}",
        "",
        "## Environment",
        "",
        "| Field | Value |",
        "| --- | --- |",
        f"| Preset | `{_cell(preset)}` |",
        f"| Preset description | {_cell(preset_label)} |",
        f"| Site | {_cell(site_name)} (`{_cell(report.site_id)}`) |",
        f"| Simulated clock | `{_cell(reference_clock or 'live')}` (Europe/Istanbul) |",
        f"| Database | `{_cell(db_name)}` |",
        f"| Checked at (UTC) | `{_cell(report.checked_at)}` |",
        f"| Backend log | `{_cell(log_path)}` |",
        "",
        "## Reproduction",
        "",
        "1. Start the Product Manager Workbench: `python3 scripts/pm_workbench.py serve`.",
        f"2. Reset the preset `{_cell(preset)}` and wait until it reports ready.",
        f"3. Set the simulator clock to `{_cell(reference_clock or 'the preset reference clock')}`.",
        "4. Follow the steps in the preset description above, then click **Verify Ledger Health**.",
        "",
        "## Ledger health scorecard",
        "",
        f"Result: **{_cell(report.status)}** — "
        f"{report.passed_count} passed, {report.failed_count} failed, "
        f"{report.error_count} could not run, {report.manual_count} need a GUI journey.",
        "",
        "| Invariant | Status | What is checked |",
        "| --- | --- | --- |",
    ]

    for result in report.invariants:
        checks = "; ".join(result.check_titles) if result.check_titles else result.manual_reason
        lines.append(
            f"| {_cell(result.invariant_id)} — {_cell(result.title)} | "
            f"{STATUS_ICON.get(result.status, _cell(result.status))} | {_cell(checks)} |"
        )

    lines.extend(["", "## Failing checks", ""])
    failures = [
        result
        for result in report.invariants
        if result.status in (STATUS_FAIL, STATUS_ERROR) or result.violations
    ]
    if not failures and not report.view_violations and not report.view_error:
        lines.append("No automated check failed in this snapshot.")
    for result in failures:
        lines.extend(
            [
                f"### {_cell(result.invariant_id)} — {_cell(result.title)}",
                "",
                f"- Status: {STATUS_ICON.get(result.status, _cell(result.status))}",
                f"- What failed: {_cell(result.explanation)}",
            ]
        )
        if result.error:
            lines.append(f"- Error: `{_cell(result.error)}`")
        if result.remediation:
            lines.append(f"- Try first: {_cell(result.remediation)}")
        if result.violations:
            lines.extend(["", "| Check | Subject | Detail |", "| --- | --- | --- |"])
            for violation in result.violations:
                lines.append(
                    f"| {_cell(violation.check_name)} | {_cell(violation.subject)} | "
                    f"{_cell(violation.detail)} |"
                )
        lines.append("")

    lines.extend(["", "### Integrity view (`v_integrity_violations`), site-scoped", ""])
    if report.view_error:
        lines.append(f"The view could not be read: `{_cell(report.view_error)}`")
    elif not report.view_violations:
        lines.append("No row in the integrity view belongs to this site.")
    else:
        lines.extend(["| Check | Subject | Difference |", "| --- | --- | --- |"])
        for violation in report.view_violations:
            lines.append(
                f"| {_cell(violation.check_name)} | {_cell(violation.subject)} | "
                f"{_cell(violation.detail)} |"
            )

    lines.extend(
        [
            "",
            "## Backend error responses",
            "",
            "Recent 4xx/5xx responses, correlated by `x-request-id` / `trace_id`. "
            "Free-text log messages are intentionally excluded.",
            "",
        ]
    )
    if not error_entries:
        lines.append(f"No 4xx/5xx entry was found in `{_cell(log_path)}`.")
    else:
        lines.extend(
            [
                "| Status | Method | Path | Request id | Trace id | Latency (ms) |",
                "| --- | --- | --- | --- | --- | --- |",
            ]
        )
        for entry in error_entries:
            lines.append(
                f"| {_cell(entry['status'])} | {_cell(entry['method'])} | `{_cell(entry['path'])}` | "
                f"`{_cell(entry['request_id'])}` | `{_cell(entry['trace_id'])}` | "
                f"{_cell(entry['latency_ms'])} |"
            )

    persona_rows = [redact_persona(persona) for persona in personas]
    lines.extend(["", "## Personas used in the session", ""])
    if not persona_rows:
        lines.append("No persona was recorded for this scenario.")
    else:
        lines.extend(
            [
                "Passwords are never exported; reset the preset to restore them.",
                "",
                "| Role | Name | Unit | E-mail |",
                "| --- | --- | --- | --- |",
            ]
        )
        for persona in persona_rows:
            lines.append(
                f"| {_cell(persona['role'])} | {_cell(persona['name'])} | "
                f"{_cell(persona['unit'])} | {_cell(persona['email'])} |"
            )

    lines.extend(["", "## Notes", "", redact_text(notes).strip() or "_Add what you expected and what you saw._", ""])
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def render_scorecard_summary(report: LedgerHealthReport) -> str:
    """Compact terminal summary of a scorecard, one line per invariant."""
    lines = [
        f"Ledger health for site {report.site_id}: {report.status}",
        (
            f"{report.passed_count} passed, {report.failed_count} failed, "
            f"{report.error_count} could not run, {report.manual_count} need a GUI journey"
        ),
    ]
    for item in report.invariants:
        detail = item.error or ", ".join(item.check_titles)
        if item.status == STATUS_MANUAL:
            detail = f"{item.manual_reason} Covered by {item.manual_suite}."
        lines.append(f"  {item.invariant_id:<4} {item.status:<7} {item.title}: {detail}")
    for violation in report.view_violations:
        lines.append(
            f"  view {violation.check_name}: {violation.subject} - {violation.detail}"
        )
    if report.view_error:
        lines.append(f"  view unreadable: {report.view_error}")
    return "\n".join(lines)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pm_ledger_health.py",
        description=(
            "Verify the seeded site's ledger health and export a redacted bug bundle. "
            "Intended for local workbench use; never run it against production."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    check_parser = subparsers.add_parser(
        "check", help="Print the ledger health scorecard (human summary, or JSON with --json)."
    )
    check_parser.add_argument("--site-id", required=True, help="Site id of the seeded preset.")
    check_parser.add_argument("--db", default="sitepulse", help="Database name (default: sitepulse).")
    check_parser.add_argument("--json", action="store_true", help="Print the scorecard as JSON.")

    bundle_parser = subparsers.add_parser("bundle", help="Print a redacted Markdown bug bundle.")
    bundle_parser.add_argument("--site-id", required=True, help="Site id of the seeded preset.")
    bundle_parser.add_argument("--preset", default="unknown", help="Preset code shown in the bundle.")
    bundle_parser.add_argument("--preset-label", default="", help="Human description of the preset.")
    bundle_parser.add_argument("--site-name", default="", help="Display name of the seeded site.")
    bundle_parser.add_argument("--clock", default="", help="Simulated reference clock (YYYY-MM-DD).")
    bundle_parser.add_argument("--db", default="sitepulse", help="Database name (default: sitepulse).")
    bundle_parser.add_argument(
        "--backend-log",
        default=str(DEFAULT_BACKEND_LOG_PATH),
        help="Backend log path used for the correlated error table.",
    )
    bundle_parser.add_argument("--notes", default="", help="Free-text notes appended to the bundle.")
    bundle_parser.add_argument("--output", default="-", help="Write the bundle here instead of stdout.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    checker = LedgerHealthChecker(db_name=args.db)
    try:
        report = checker.check(args.site_id)
    except LedgerHealthError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2

    if args.command == "check":
        if args.json:
            print(json.dumps(report.to_dict(), indent=2, sort_keys=False))
        else:
            print(render_scorecard_summary(report))
        return 0 if report.status == OVERALL_GREEN else 1

    bundle = render_bug_bundle(
        report,
        preset=args.preset,
        preset_label=args.preset_label,
        site_name=args.site_name,
        reference_clock=args.clock,
        backend_log_path=args.backend_log,
        db_name=args.db,
        notes=args.notes,
    )
    if args.output == "-":
        print(bundle)
    else:
        Path(args.output).write_text(bundle, encoding="utf-8")
        print(f"Wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
