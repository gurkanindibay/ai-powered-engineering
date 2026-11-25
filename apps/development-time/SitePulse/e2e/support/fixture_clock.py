"""One shared "today" for the E2E run: the backend clock, SQL arrange steps and expected values.

The backend derives every late penalty and aging figure from the site's local date at request
time, while SQL arrange steps used the database's `CURRENT_DATE` (UTC). A run that crossed
midnight in the site's time zone (Europe/Istanbul, UTC+3, so 21:00 UTC) therefore grew each
penalty by a day mid-test. The stack freezes the backend clock at `fixture_instant()` and arrange
steps read the same date from `E2EStack.fixture_today`.
"""
from __future__ import annotations

import os
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

SITE_TIMEZONE = "Europe/Istanbul"
NOW_ENV = "SITEPULSE_E2E_NOW"
# Noon at the site (UTC+3): far from both local midnights, so the date cannot flip while it is frozen.
_PIN_HOUR_UTC = 9


def site_local_date(instant: datetime, timezone_name: str = SITE_TIMEZONE) -> date:
    return instant.astimezone(ZoneInfo(timezone_name)).date()


def fixture_instant(now: datetime | None = None, environ: dict[str, str] | None = None) -> datetime:
    """The instant the backend clock is frozen at: noon at the site on the run's start date.

    `SITEPULSE_E2E_NOW` (RFC 3339) stands in for the wall clock, so a run that starts just before
    the site's midnight can be simulated.
    """
    env = os.environ if environ is None else environ
    raw = env.get(NOW_ENV)
    start = datetime.fromisoformat(raw.replace("Z", "+00:00")) if raw else (now or datetime.now(timezone.utc))
    if start.tzinfo is None:
        raise ValueError(f"{NOW_ENV} must carry a UTC offset, got {raw!r}")
    local = site_local_date(start)
    return datetime(local.year, local.month, local.day, _PIN_HOUR_UTC, tzinfo=timezone.utc)
