"""SitePulse Product Manager Scenario Seeder package.

Provides reproducible F0–F10 reference state seeding against running dev/test
environments, shared by the E2E suite and the PM Workbench.
"""

from .seeder import (
    EXPECTED_TOTALS,
    EXPECTED_UNIT_BALANCES,
    PERSONAS,
    PM_CHECKLISTS,
    REFERENCE_CLOCKS,
    ScenarioManifest,
    make_viban,
    seed_preset,
)

__all__ = [
    "EXPECTED_TOTALS",
    "EXPECTED_UNIT_BALANCES",
    "PERSONAS",
    "PM_CHECKLISTS",
    "REFERENCE_CLOCKS",
    "ScenarioManifest",
    "make_viban",
    "seed_preset",
]
