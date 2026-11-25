#!/usr/bin/env python3
"""SitePulse Product Manager Workbench Web UI (`pm_workbench_web.py`).

A zero-dependency local web UI served on http://localhost:9095 so a Product
Manager can prepare a scenario preset with one click instead of typing CLI
commands. `pm_workbench.py up` starts it automatically; `pm_workbench.py serve`
runs it on its own.

Endpoints:
  GET  /              Scenario gallery and active-scenario cheat sheet (HTML)
  GET  /api/presets   Preset catalogue grouped into complexity packs A-F
  GET  /api/active    Manifest of the active scenario (null when none is active)
  POST /api/seed      {"preset": "F5"} seeds that preset and pins the E2E clock
  POST /api/reset     Re-provisions the active preset
  GET  /healthz       Liveness probe

All scenario truth (reference clocks, expected totals, unit balances and PM
checklists) comes from `pm_scenarios`, so the UI cannot drift from the seeder
the automated E2E suite uses. This module only presents that data.

Safety:
  * Binds to loopback by default and refuses to start in production.
  * Standard library only; no new runtime dependency is introduced.
  * Monetary values stay exact strings end to end; no floating-point parsing.
"""
from __future__ import annotations

import argparse
import calendar
import json
import logging
import sys
import threading
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

try:
    from zoneinfo import ZoneInfo
    ISTANBUL_TZ = ZoneInfo("Europe/Istanbul")
except Exception:
    ISTANBUL_TZ = timezone(timedelta(hours=3))

# Upper bound for a single Time Machine advance step (one year of days).
MAX_ADVANCE_DAYS = 366

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

E2E_DIR = SCRIPT_DIR.parent / "e2e"
if str(E2E_DIR) not in sys.path:
    sys.path.insert(0, str(E2E_DIR))

try:
    from support.bank_files import (
        build_companion_statement_rows,
        resident_import_xlsx,
        statement_csv,
        statement_mt940,
    )
except ImportError:
    COMPANION_FILES_AVAILABLE = False
    build_companion_statement_rows = None  # type: ignore[assignment]
    resident_import_xlsx = None  # type: ignore[assignment]
    statement_csv = None  # type: ignore[assignment]
    statement_mt940 = None  # type: ignore[assignment]
else:
    COMPANION_FILES_AVAILABLE = True

from pm_scenarios import (  # noqa: E402  (sys.path is set up above)
    EXPECTED_TOTALS,
    EXPECTED_UNIT_BALANCES,
    PM_CHECKLISTS,
    REFERENCE_CLOCKS,
)
import pm_ledger_health  # noqa: E402  (sys.path is set up above)

LOGGER = logging.getLogger("pm_workbench_web")

DEFAULT_UI_HOST = "127.0.0.1"
DEFAULT_UI_PORT = 9095
DEFAULT_API_URL = "http://localhost:8080"
DEFAULT_WEB_URL = "http://localhost:9090"
DEFAULT_STATE_PATH = Path.home() / ".sitepulse" / "workbench-active.json"
UI_HTML_PATH = SCRIPT_DIR / "pm_workbench_ui.html"
MAX_REQUEST_BYTES = 64 * 1024

# Hostnames a browser may use to reach a loopback-only workbench. Any other
# Host header is rejected so a DNS-rebinding page cannot masquerade as the UI.
LOOPBACK_HOSTNAMES = ("localhost", "127.0.0.1", "::1")

# Canonical presets: the E2E state names a PM may prepare, grouped into the
# six complexity packs of the test plan. Aliases (F8/F9/F10) are accepted on
# input and normalised to the canonical spelling.
PACKS: tuple[dict[str, Any], ...] = (
    {"id": "A", "title": "Onboarding", "presets": ("F0", "F1", "F2", "F3")},
    {"id": "B", "title": "Core dues and late fees", "presets": ("F4", "F5", "F7")},
    {"id": "C", "title": "Occupancy, sales and splits", "presets": ("F6",)},
    {"id": "D", "title": "Capital expenditure", "presets": ("F8_CAPITAL",)},
    {"id": "E", "title": "Reconciliation and import", "presets": ("F9_RECON",)},
    {"id": "F", "title": "Governance and multi-site", "presets": ("F10_GOVERNANCE",)},
)

PRESET_ALIASES: dict[str, str] = {
    "F8": "F8_CAPITAL",
    "F9": "F9_RECON",
    "F10": "F10_GOVERNANCE",
}

PRESET_LABELS: dict[str, str] = {
    "F0": "Empty site",
    "F1": "Structure only",
    "F2": "Residents invited",
    "F3": "Period opened, no residents",
    "F4": "Single period with overdue dues",
    "F5": "Three periods, advance balance",
    "F6": "Changing occupancy across periods",
    "F7": "Closed historical period",
    "F8_CAPITAL": "Capital project and installments",
    "F9_RECON": "Virtual IBANs and bank reconciliation",
    "F10_GOVERNANCE": "Two sites, arrears and governance",
}

PRESET_SUMMARIES: dict[str, str] = {
    "F0": "Fresh site with no blocks, units or people. Use it to test onboarding from scratch.",
    "F1": "One block with seven units, tariffs and land shares, and no residents yet.",
    "F2": "Seven units with resident accounts activated, ready for login and profile checks.",
    "F3": "One open period on a site with no residents, for tariff and accrual previews.",
    "F4": "One accrued period with six overdue units and one settled receipt.",
    "F5": "Three accrued periods with an operational advance balance on one unit.",
    "F6": "Move-ins, move-outs and a multi-debtor unit across three periods.",
    "F7": "Three periods where September is closed and immutable.",
    "F8_CAPITAL": "Facade insulation project: budget, first installment and an advance to transfer.",
    "F9_RECON": "Deterministic Virtual IBANs, a duplicate person and an ambiguous transfer.",
    "F10_GOVERNANCE": "Two sites with severe arrears, a payment plan, heating split and a meeting.",
}


class WorkbenchWebError(Exception):
    """Base error for a request the Workbench Web UI cannot fulfil."""

    status = 500

    def __init__(self, message: str, **details: Any) -> None:
        super().__init__(message)
        self.message = message
        self.details = details

    def payload(self) -> dict[str, Any]:
        return {"error": self.message, **self.details}


class UnknownPresetError(WorkbenchWebError):
    status = 400


class InvalidRequestError(WorkbenchWebError):
    status = 400


class ForbiddenRequestError(WorkbenchWebError):
    """A request that a browser from another origin must not be able to make."""

    status = 403


class PayloadTooLargeError(WorkbenchWebError):
    status = 413


class UnsupportedMediaTypeError(WorkbenchWebError):
    status = 415


class NoActiveScenarioError(WorkbenchWebError):
    status = 409


class SeedingFailedError(WorkbenchWebError):
    status = 502


class CompanionFilesUnavailableError(WorkbenchWebError):
    status = 503


class LedgerHealthFailedError(WorkbenchWebError):
    """The ledger check or the bundle export could not run against the database."""

    status = 502


def normalize_preset(value: Any) -> str:
    """Returns the canonical preset key for a user-supplied value."""
    if not isinstance(value, str) or not value.strip():
        raise InvalidRequestError("A preset name is required, for example F5.")
    candidate = value.strip().upper()
    candidate = PRESET_ALIASES.get(candidate, candidate)
    if candidate not in EXPECTED_TOTALS:
        known = ", ".join(preset_key for pack in PACKS for preset_key in pack["presets"])
        raise UnknownPresetError(f"Unknown preset {value!r}. Known presets: {known}.", known_presets=known.split(", "))
    return candidate


def json_safe(value: Any) -> Any:
    """Converts Decimals to exact strings so no money value becomes a float."""
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    return value


def preset_catalogue() -> dict[str, Any]:
    """Builds the scenario gallery payload from the shared scenario catalogue."""
    pack_by_preset = {preset: pack["id"] for pack in PACKS for preset in pack["presets"]}
    packs: list[dict[str, Any]] = []
    for pack in PACKS:
        entries = []
        for preset in pack["presets"]:
            totals = json_safe(dict(EXPECTED_TOTALS[preset]))
            entries.append(
                {
                    "preset": preset,
                    "label": PRESET_LABELS.get(preset, preset),
                    "summary": PRESET_SUMMARIES.get(preset, ""),
                    "pack": pack["id"],
                    "reference_clock": REFERENCE_CLOCKS[preset],
                    "unit_count": len(EXPECTED_UNIT_BALANCES[preset]),
                    "site_count": totals.get("sites", 1),
                    "expected_site_totals": totals,
                    "checklist": list(PM_CHECKLISTS.get(preset, [])),
                    "aliases": sorted(alias for alias, target in PRESET_ALIASES.items() if target == preset),
                }
            )
        packs.append({"id": pack["id"], "title": pack["title"], "presets": entries})
    return {"packs": packs, "default_preset": "F5", "pack_by_preset": pack_by_preset}


@dataclass
class ActiveScenario:
    """The scenario last prepared through the UI, persisted across restarts."""

    preset: str
    manifest: dict[str, Any]
    seeded_at: str
    clock: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "preset": self.preset,
            "manifest": self.manifest,
            "seeded_at": self.seeded_at,
            "clock": self.clock,
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "ActiveScenario":
        return cls(
            preset=str(payload["preset"]),
            manifest=dict(payload.get("manifest") or {}),
            seeded_at=str(payload.get("seeded_at", "")),
            clock=dict(payload.get("clock") or {}),
        )


class WorkbenchService:
    """Seeds presets and tracks the active scenario for the web UI.

    Seeding and clock control are injected so the HTTP layer can be tested
    without a live backend, database or browser.
    """

    def __init__(
        self,
        *,
        seed_fn: Callable[[str], Any] | None = None,
        clock_fn: Callable[[str], Any] | None = None,
        clock_action_fn: Callable[[dict[str, Any]], Any] | None = None,
        health_fn: Callable[[str], Any] | None = None,
        bundle_fn: Callable[..., str] | None = None,
        state_path: Path | str | None = None,
        api_url: str = DEFAULT_API_URL,
        web_url: str = DEFAULT_WEB_URL,
        db_name: str = "sitepulse",
        saas_email: str = "admin@sitepulse.io",
        saas_password: str = "E2E-Bootstrap-Admin-1",
        backend_log_path: Path | str = pm_ledger_health.DEFAULT_BACKEND_LOG_PATH,
        skip_reload: bool = False,
    ) -> None:
        self._seed_fn = seed_fn
        self._clock_fn = clock_fn
        self._clock_action_fn = clock_action_fn
        self._health_fn = health_fn
        self._bundle_fn = bundle_fn
        self._state_path = Path(state_path) if state_path else DEFAULT_STATE_PATH
        self._api_url = api_url
        self._web_url = web_url
        self._db_name = db_name
        self._saas_email = saas_email
        self._saas_password = saas_password
        self._backend_log_path = Path(backend_log_path)
        self._skip_reload = skip_reload
        self._lock = threading.RLock()
        self._active: ActiveScenario | None = None
        self._loaded = False
        self._cached_clock_date: str | None = None

    # -- catalogue ---------------------------------------------------------

    def presets(self) -> dict[str, Any]:
        return preset_catalogue()

    # -- active scenario state --------------------------------------------

    def active(self) -> ActiveScenario | None:
        with self._lock:
            if not self._loaded:
                self._active = self._read_state()
                self._loaded = True
            return self._active

    def _read_state(self) -> ActiveScenario | None:
        if not self._state_path.is_file():
            return None
        try:
            payload = json.loads(self._state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as err:
            LOGGER.warning("Ignoring unreadable workbench state file %s: %s", self._state_path, err)
            return None
        if not isinstance(payload, dict) or "preset" not in payload:
            LOGGER.warning("Ignoring malformed workbench state file %s", self._state_path)
            return None
        return ActiveScenario.from_dict(payload)

    def _write_state(self, active: ActiveScenario) -> None:
        try:
            self._state_path.parent.mkdir(parents=True, exist_ok=True)
            self._state_path.write_text(json.dumps(active.to_dict(), indent=2), encoding="utf-8")
        except OSError as err:
            # The scenario is seeded and usable; only persistence failed.
            LOGGER.warning("Could not persist workbench state to %s: %s", self._state_path, err)

    # -- actions -----------------------------------------------------------

    def prepare(self, preset: Any) -> ActiveScenario:
        canonical = normalize_preset(preset)
        with self._lock:
            manifest = self._seed(canonical)
            clock = self._pin_clock(canonical)
            active = ActiveScenario(
                preset=canonical,
                manifest=manifest,
                seeded_at=datetime.now(timezone.utc).isoformat(),
                clock=clock,
            )
            self._active = active
            self._loaded = True
            self._write_state(active)
            return active

    def reset(self) -> ActiveScenario:
        with self._lock:
            active = self.active()
            if active is None:
                raise NoActiveScenarioError("No scenario is active, so there is nothing to reset.")
            return self.prepare(active.preset)

    def _seed(self, preset: str) -> dict[str, Any]:
        try:
            if self._seed_fn is not None:
                result = self._seed_fn(preset)
            else:
                result = self._seed_with_shared_seeder(preset)
        except WorkbenchWebError:
            raise
        except Exception as err:  # noqa: BLE001 - the HTTP layer maps it to 502
            raise SeedingFailedError(f"Seeding {preset} failed: {err}") from err
        return json_safe(self._manifest_dict(result))

    def _seed_with_shared_seeder(self, preset: str) -> Any:
        from pm_scenarios import seed_preset  # imported late to keep test doubles cheap

        return seed_preset(
            preset,
            api_url=self._api_url,
            db_name=self._db_name,
            saas_email=self._saas_email,
            saas_password=self._saas_password,
            reload_fn=(lambda: None) if self._skip_reload else None,
            set_clock=False,  # this service owns clock control so it is set exactly once
        )

    @staticmethod
    def _manifest_dict(result: Any) -> dict[str, Any]:
        manifest = getattr(result, "manifest", result)
        if hasattr(manifest, "to_dict"):
            return dict(manifest.to_dict())
        if isinstance(manifest, dict):
            return dict(manifest)
        raise SeedingFailedError("The scenario seeder returned no manifest.")

    def _pin_clock(self, preset: str) -> dict[str, Any]:
        reference_date = REFERENCE_CLOCKS[preset]
        self._cached_clock_date = reference_date
        try:
            if self._clock_fn is not None:
                response = self._clock_fn(reference_date)
            else:
                response = self._clock_with_backend(reference_date)
        except Exception as err:  # noqa: BLE001 - the scenario is still usable
            LOGGER.warning("Could not pin the E2E clock to %s: %s", reference_date, err)
            return {"status": "FAILED", "reference_date": reference_date, "error": str(err)}
        return {"status": "SET", "reference_date": reference_date, "response": json_safe(response)}

    def _clock_with_backend(self, reference_date: str) -> Any:
        # Imported late: pm_workbench imports this module at start-up.
        from pm_workbench import call_clock_api

        return call_clock_api(self._api_url, {"action": "set_date", "date": reference_date})

    def get_clock(self) -> dict[str, Any]:
        """Returns the current simulated Europe/Istanbul date and time."""
        with self._lock:
            if self._clock_action_fn is not None:
                try:
                    res = self._clock_action_fn({"action": "get"})
                    if isinstance(res, dict):
                        return json_safe(res)
                except Exception as err:
                    LOGGER.warning("Injected clock action function failed on get: %s", err)
            else:
                from pm_workbench import call_clock_api
                try:
                    res = call_clock_api(self._api_url, {"action": "get"})
                    if isinstance(res, dict) and res.get("action") == "current":
                        self._cached_clock_date = res.get("date")
                        return json_safe(res)
                except Exception as err:
                    LOGGER.debug("Could not fetch clock from backend %s: %s", self._api_url, err)

            active = self.active()
            ref_date = self._cached_clock_date
            if not ref_date and active:
                clock_info = active.clock or {}
                ref_date = clock_info.get("reference_date") or active.manifest.get("reference_clock")
            if not ref_date:
                ref_date = datetime.now(ISTANBUL_TZ).date().isoformat()

            try:
                midnight = datetime.fromisoformat(f"{ref_date}T00:00:00").replace(tzinfo=ISTANBUL_TZ)
            except ValueError:
                # A malformed cached/manifest date must not break the UI: report the real date.
                midnight = datetime.now(ISTANBUL_TZ)
                ref_date = midnight.date().isoformat()
            return {
                "action": "current",
                "date": ref_date,
                "time": midnight.strftime("%H:%M:%S"),
                "iso": midnight.isoformat(),
                "timezone": "Europe/Istanbul",
                "status": "FALLBACK",
            }

    def _parse_advance_days(self, raw_days: Any) -> int:
        """Validates the `days` step for an advance action (bounded so it stays useful)."""
        try:
            days = int(raw_days)
        except (TypeError, ValueError) as err:
            raise InvalidRequestError(
                f"Invalid 'days' value {raw_days!r}; expected a whole number."
            ) from err
        if not 1 <= days <= MAX_ADVANCE_DAYS:
            raise InvalidRequestError(
                f"'days' must be between 1 and {MAX_ADVANCE_DAYS}, got {days}."
            )
        return days

    def control_clock(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Executes a Time Machine action against the E2E clock."""
        action = payload.get("action")
        if not action:
            raise InvalidRequestError("A clock action is required.")

        current = self.get_clock()
        cur_date_str = str(current.get("date", ""))
        try:
            cur_date = datetime.strptime(cur_date_str, "%Y-%m-%d").date()
        except (ValueError, TypeError):
            cur_date = datetime.now(timezone.utc).date()

        backend_payload: dict[str, Any]
        if action == "advance":
            days = self._parse_advance_days(payload.get("days", 1))
            target_date = cur_date + timedelta(days=days)
            backend_payload = {"action": "advance_to", "date": target_date.isoformat()}
        elif action in ("jump_due_day", "jump_to_due_day"):
            # Due date is the 10th of the month.
            if cur_date.day < 10:
                target_date = date(cur_date.year, cur_date.month, 10)
            else:
                next_y = cur_date.year + (1 if cur_date.month == 12 else 0)
                next_m = 1 if cur_date.month == 12 else cur_date.month + 1
                target_date = date(next_y, next_m, 10)
            backend_payload = {"action": "set_date", "date": target_date.isoformat()}
        elif action in ("jump_month_end", "jump_to_month_end"):
            num_days = calendar.monthrange(cur_date.year, cur_date.month)[1]
            month_end = date(cur_date.year, cur_date.month, num_days)
            if cur_date < month_end:
                target_date = month_end
            else:
                next_y = cur_date.year + (1 if cur_date.month == 12 else 0)
                next_m = 1 if cur_date.month == 12 else cur_date.month + 1
                next_days = calendar.monthrange(next_y, next_m)[1]
                target_date = date(next_y, next_m, next_days)
            backend_payload = {"action": "set_date", "date": target_date.isoformat()}
        elif action == "set_date":
            date_val = payload.get("date")
            if not date_val:
                raise InvalidRequestError("Action 'set_date' requires a 'date' string (YYYY-MM-DD).")
            try:
                datetime.strptime(date_val, "%Y-%m-%d")
            except ValueError as err:
                raise InvalidRequestError(f"Invalid date format {date_val!r}; expected YYYY-MM-DD.") from err
            backend_payload = {"action": "set_date", "date": date_val}
        elif action == "advance_to":
            date_val = payload.get("date")
            if not date_val:
                raise InvalidRequestError("Action 'advance_to' requires a 'date' string (YYYY-MM-DD).")
            backend_payload = {"action": "advance_to", "date": date_val}
        elif action == "tick":
            backend_payload = {"action": "tick"}
        elif action in ("clear", "reset"):
            backend_payload = {"action": "clear"}
        elif action in ("get", "status"):
            return self.get_clock()
        else:
            raise InvalidRequestError(f"Unknown clock action {action!r}.")

        with self._lock:
            if self._clock_action_fn is not None:
                resp = self._clock_action_fn(backend_payload)
            elif self._clock_fn is not None and backend_payload.get("action") == "set_date":
                resp = self._clock_fn(backend_payload["date"])
            else:
                from pm_workbench import call_clock_api
                try:
                    resp = call_clock_api(self._api_url, backend_payload)
                except Exception as err:
                    raise WorkbenchWebError(f"Clock action {action} failed: {err}") from err

            if isinstance(resp, dict):
                target_date_str = resp.get("date") or backend_payload.get("date")
                if target_date_str:
                    self._cached_clock_date = str(target_date_str)
                if self._active:
                    new_clock = dict(self._active.clock or {})
                    if target_date_str:
                        new_clock["reference_date"] = str(target_date_str)
                        new_clock["status"] = "SET"
                    if resp.get("report"):
                        new_clock["last_tick_report"] = resp.get("report")
                    self._active.clock = new_clock
                    self._write_state(self._active)

            return json_safe(resp if isinstance(resp, dict) else {"status": "OK"})
    # -- ledger health and bug bundle -------------------------------------

    def _require_active(self) -> ActiveScenario:
        active = self.active()
        if active is None:
            raise NoActiveScenarioError(
                "No scenario is active; prepare a preset before verifying the ledger."
            )
        return active

    def _site_id(self, active: ActiveScenario) -> str:
        site_id = active.manifest.get("site_id")
        if site_id in (None, ""):
            raise NoActiveScenarioError(
                "The active scenario records no site id, so its ledger cannot be verified."
            )
        return str(site_id)

    def ledger_health(self) -> dict[str, Any]:
        """Runs the site-scoped ledger checks for the active scenario."""
        with self._lock:
            active = self._require_active()
            site_id = self._site_id(active)
            try:
                if self._health_fn is not None:
                    report = self._health_fn(site_id)
                else:
                    report = self._checker().check(site_id)
            except pm_ledger_health.LedgerHealthError as err:
                raise InvalidRequestError(str(err)) from err
            except Exception as err:  # noqa: BLE001 - surfaced as a 502 with the reason
                raise LedgerHealthFailedError(
                    f"The ledger check could not run: {err}"
                ) from err
            payload = report.to_dict() if hasattr(report, "to_dict") else dict(report)
            return json_safe(
                {
                    "preset": active.preset,
                    "site_id": site_id,
                    "site_name": active.manifest.get("site_name"),
                    "reference_clock": active.manifest.get("reference_clock"),
                    "health": payload,
                }
            )

    def bug_bundle(self, notes: Any = "") -> dict[str, Any]:
        """Renders a redacted Markdown bug bundle for the active scenario."""
        with self._lock:
            active = self._require_active()
            site_id = self._site_id(active)
            manifest = active.manifest
            try:
                if self._bundle_fn is not None:
                    markdown = self._bundle_fn(
                        site_id,
                        preset=active.preset,
                        preset_label=PRESET_LABELS.get(active.preset, active.preset),
                        site_name=str(manifest.get("site_name") or ""),
                        reference_clock=str(
                            manifest.get("reference_clock")
                            or (active.clock or {}).get("reference_date")
                            or ""
                        ),
                        personas=manifest.get("personas") or manifest.get("persona_accounts") or [],
                        backend_log_path=self._backend_log_path,
                        db_name=self._db_name,
                        notes=str(notes or ""),
                    )
                else:
                    markdown = self._render_bundle(active, site_id=site_id, notes=str(notes or ""))
            except pm_ledger_health.LedgerHealthError as err:
                raise InvalidRequestError(str(err)) from err
            except Exception as err:  # noqa: BLE001 - surfaced as a 502 with the reason
                raise LedgerHealthFailedError(
                    f"The bug bundle could not be generated: {err}"
                ) from err
            return {
                "preset": active.preset,
                "site_id": site_id,
                "markdown": markdown,
            }

    def _checker(self) -> pm_ledger_health.LedgerHealthChecker:
        return pm_ledger_health.LedgerHealthChecker(db_name=self._db_name)

    def _render_bundle(self, active: ActiveScenario, *, site_id: str, notes: str) -> str:
        manifest = active.manifest
        report = self._checker().check(site_id)
        return pm_ledger_health.render_bug_bundle(
            report,
            preset=active.preset,
            preset_label=PRESET_LABELS.get(active.preset, active.preset),
            site_name=str(manifest.get("site_name") or ""),
            reference_clock=str(
                manifest.get("reference_clock")
                or (active.clock or {}).get("reference_date")
                or ""
            ),
            personas=manifest.get("personas") or manifest.get("persona_accounts") or [],
            backend_log_path=self._backend_log_path,
            db_name=self._db_name,
            notes=notes,
        )

    def payload(self, active: ActiveScenario) -> dict[str, Any]:
        """Flattens the active scenario into the cheat-sheet shape the UI renders."""
        manifest = active.manifest
        clock = dict(active.clock or {})
        payload = {
            "preset": active.preset,
            "label": PRESET_LABELS.get(active.preset, active.preset),
            "seeded_at": active.seeded_at,
            "clock": clock,
            "web_url": self._web_url,
            "site_id": manifest.get("site_id"),
            "site_name": manifest.get("site_name"),
            "reference_clock": manifest.get("reference_clock") or clock.get("reference_date"),
            "expected_site_totals": manifest.get("expected_site_totals") or {},
            "unit_by_unit_expected_balances": (
                manifest.get("unit_by_unit_expected_balances") or manifest.get("unit_balances") or []
            ),
            "personas": manifest.get("personas") or manifest.get("persona_accounts") or [],
            "pm_checklist": manifest.get("pm_checklist") or manifest.get("pm_checklists") or [],
        }
        return json_safe(payload)

    # -- companion files ---------------------------------------------------

    def companion_bank_csv(self) -> str:
        """Returns the dynamically populated companion bank statement CSV."""
        active = self.active()
        manifest = active.manifest if active else None
        rows = build_companion_statement_rows(manifest)
        return statement_csv(rows)

    def companion_bank_mt940(self) -> str:
        """Returns the dynamically populated companion bank statement MT940."""
        active = self.active()
        manifest = active.manifest if active else None
        rows = build_companion_statement_rows(manifest)
        return statement_mt940(rows)

    def companion_resident_xlsx(self) -> bytes:
        """Returns the companion resident directory Excel (.xlsx) file bytes."""
        return resident_import_xlsx()


def render_index_html() -> str:
    """Returns the single-page UI markup served at the root path."""
    try:
        return UI_HTML_PATH.read_text(encoding="utf-8")
    except OSError as err:
        LOGGER.error("Workbench UI markup is unavailable at %s: %s", UI_HTML_PATH, err)
        return (
            "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<title>SitePulse PM Workbench</title></head><body>"
            "<h1>SitePulse PM Workbench</h1>"
            "<p>The UI markup could not be read. Use <code>/api/presets</code> and "
            "<code>/api/active</code>, or reinstall the tool.</p></body></html>"
        )


GET_ROUTES = (
    "/",
    "/index.html",
    "/api/presets",
    "/api/active",
    "/api/clock",
    "/healthz",
    "/api/companion/bank-statement",
    "/api/companion/resident-import.xlsx",
)
POST_ROUTES = (
    "/api/seed",
    "/api/reset",
    "/api/clock",
    "/api/ledger-health",
    "/api/bug-bundle",
)


def make_handler(service: WorkbenchService) -> type[BaseHTTPRequestHandler]:
    """Builds a request handler bound to one WorkbenchService instance."""

    class WorkbenchRequestHandler(BaseHTTPRequestHandler):
        server_version = "SitePulsePMWorkbench/1.0"

        # -- plumbing ------------------------------------------------------

        def log_message(self, fmt: str, *args: Any) -> None:
            # Access logs stay at debug level so the console only shows the
            # listening URL and seeding notices during normal use.
            LOGGER.debug("%s %s", self.address_string(), fmt % args)

        def _path(self) -> str:
            path = urlparse(self.path).path or "/"
            return path.rstrip("/") or "/"

        # -- same-origin guardrails ---------------------------------------

        def _host_name(self, value: str) -> str:
            """Returns the lowercase hostname of a Host/Origin authority."""
            parsed = urlparse(value if "//" in value else f"//{value}")
            return (parsed.hostname or "").lower()

        def _check_host(self) -> None:
            # A DNS-rebinding page resolves its own name to 127.0.0.1, so the
            # only trustworthy signal is that the browser used a loopback Host.
            host_header = self.headers.get("Host")
            if not host_header:
                return  # HTTP/1.0 clients without a Host header are not browsers
            if self._host_name(host_header) not in LOOPBACK_HOSTNAMES:
                raise ForbiddenRequestError(
                    "This workbench only accepts loopback Host headers "
                    f"({', '.join(LOOPBACK_HOSTNAMES)})."
                )

        def _check_origin(self) -> None:
            # A cross-site POST would otherwise land as a CORS "simple request".
            # Browsers send Origin on POST; a present value must be our own
            # origin, host and port: another loopback dev server is not us.
            origin = self.headers.get("Origin")
            if not origin:
                return
            parsed = urlparse(origin if "//" in origin else f"//{origin}")
            try:
                origin_port = parsed.port
            except ValueError as err:
                raise ForbiddenRequestError("Malformed Origin header.") from err
            if (parsed.hostname or "").lower() not in LOOPBACK_HOSTNAMES:
                raise ForbiddenRequestError("Cross-origin requests are not allowed.")
            if origin_port != self.server.server_address[1]:
                raise ForbiddenRequestError("Cross-origin requests are not allowed.")

        def _check_json_content_type(self) -> None:
            # Requiring application/json forces a CORS preflight that this
            # server never approves, so a form or text/plain POST cannot seed.
            content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if content_type != "application/json":
                raise UnsupportedMediaTypeError(
                    "POST requests must use Content-Type: application/json."
                )

        def _send_body(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _send_download(self, filename: str, content_type: str, body: bytes) -> None:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _send_json(self, status: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
            self._send_body(status, body, "application/json; charset=utf-8")

        def _send_error_payload(self, error: WorkbenchWebError) -> None:
            self._send_json(error.status, error.payload())

        def _method_not_allowed(self, allowed: str) -> None:
            self.send_response(405)
            self.send_header("Allow", allowed)
            body = json.dumps(
                {"error": f"{self.command} is not supported on {self._path()}; allowed: {allowed}."}
            ).encode("utf-8")
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_json_body(self) -> dict[str, Any]:
            raw_length = self.headers.get("Content-Length")
            try:
                length = int(raw_length) if raw_length else 0
            except ValueError as err:
                raise InvalidRequestError("Content-Length must be an integer.") from err
            if length > MAX_REQUEST_BYTES:
                raise PayloadTooLargeError(f"Request body exceeds {MAX_REQUEST_BYTES} bytes.")
            if length <= 0:
                return {}
            raw = self.rfile.read(length)
            try:
                payload = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError) as err:
                raise InvalidRequestError("Request body must be valid JSON.") from err
            if not isinstance(payload, dict):
                raise InvalidRequestError("Request body must be a JSON object.")
            return payload

        # -- routing -------------------------------------------------------

        def do_GET(self) -> None:  # noqa: N802 - http.server naming
            self._dispatch("GET")

        def do_POST(self) -> None:  # noqa: N802 - http.server naming
            self._dispatch("POST")

        def do_HEAD(self) -> None:  # noqa: N802 - http.server naming
            self._dispatch("GET")

        def _dispatch(self, method: str) -> None:
            path = self._path()
            try:
                self._check_host()
                if method == "GET":
                    self._handle_get(path)
                else:
                    self._check_origin()
                    self._check_json_content_type()
                    self._handle_post(path)
            except WorkbenchWebError as err:
                self._send_error_payload(err)
            except Exception as err:  # noqa: BLE001 - never leak internals to the browser
                request_id = uuid.uuid4().hex[:12]
                LOGGER.exception(
                    "Unhandled workbench UI error for %s %s (request id %s)",
                    method,
                    path,
                    request_id,
                )
                self._send_json(
                    500,
                    {
                        "error": "Internal workbench error; see the workbench log.",
                        "request_id": request_id,
                    },
                )

        def _handle_get(self, path: str) -> None:
            if path in ("/", "/index.html"):
                body = render_index_html().encode("utf-8")
                self._send_body(200, body, "text/html; charset=utf-8")
            elif path == "/api/presets":
                self._send_json(200, service.presets())
            elif path == "/api/active":
                active = service.active()
                self._send_json(
                    200,
                    {"active": service.payload(active) if active else None},
                )
            elif path == "/api/clock":
                self._send_json(200, service.get_clock())
            elif path == "/healthz":
                self._send_json(200, {"status": "ok", "service": "pm-workbench-web"})
            elif path == "/api/companion/bank-statement":
                if not COMPANION_FILES_AVAILABLE:
                    raise CompanionFilesUnavailableError(
                        "Companion files unavailable: e2e/support is not importable."
                    )
                query = parse_qs(urlparse(self.path).query)
                fmt = (query.get("format", ["csv"])[0]).lower()
                if fmt == "mt940":
                    self._send_download(
                        "bank-statement.mt940",
                        "text/plain; charset=utf-8",
                        service.companion_bank_mt940().encode("utf-8"),
                    )
                elif fmt == "csv":
                    self._send_download(
                        "bank-statement.csv",
                        "text/csv; charset=utf-8",
                        service.companion_bank_csv().encode("utf-8"),
                    )
                else:
                    raise InvalidRequestError("format must be csv or mt940.")
            elif path == "/api/companion/resident-import.xlsx":
                if not COMPANION_FILES_AVAILABLE:
                    raise CompanionFilesUnavailableError(
                        "Companion files unavailable: e2e/support is not importable."
                    )
                xlsx_bytes = service.companion_resident_xlsx()
                self._send_download(
                    "resident-import.xlsx",
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    xlsx_bytes,
                )
            elif path in POST_ROUTES:
                self._method_not_allowed("POST")
            else:
                self._send_json(404, {"error": f"Unknown path {path}."})

        def _handle_post(self, path: str) -> None:
            if path == "/api/seed":
                payload = self._read_json_body()
                active = service.prepare(payload.get("preset"))
                self._send_json(200, service.payload(active))
            elif path == "/api/reset":
                self._read_json_body()  # body optional; validated when present
                active = service.reset()
                self._send_json(200, service.payload(active))
            elif path == "/api/clock":
                payload = self._read_json_body()
                resp = service.control_clock(payload)
                self._send_json(200, resp)
            elif path == "/api/ledger-health":
                self._read_json_body()  # body optional; the active scenario decides the scope
                self._send_json(200, service.ledger_health())
            elif path == "/api/bug-bundle":
                payload = self._read_json_body()
                self._send_json(200, service.bug_bundle(payload.get("notes", "")))
            elif path in GET_ROUTES:
                self._method_not_allowed("GET")
            else:
                self._send_json(404, {"error": f"Unknown path {path}."})

    return WorkbenchRequestHandler


def create_server(
    service: WorkbenchService,
    *,
    host: str = DEFAULT_UI_HOST,
    port: int = DEFAULT_UI_PORT,
    allow_remote: bool = False,
) -> ThreadingHTTPServer:
    """Creates the Workbench UI server, refusing to bind in production."""
    from pm_workbench import check_production_guardrail  # imported late: pm_workbench imports this module

    check_production_guardrail()
    if host not in LOOPBACK_HOSTNAMES and not allow_remote:
        raise OSError(
            f"Refusing to bind {host!r}: the workbench exposes persona credentials. "
            "Pass --allow-remote to serve it beyond loopback."
        )
    server = ThreadingHTTPServer((host, port), make_handler(service))
    server.daemon_threads = True
    return server


def serve(
    *,
    host: str = DEFAULT_UI_HOST,
    port: int = DEFAULT_UI_PORT,
    service: WorkbenchService | None = None,
    allow_remote: bool = False,
) -> None:
    """Runs the UI until interrupted."""
    server = create_server(
        service or WorkbenchService(), host=host, port=port, allow_remote=allow_remote
    )
    bound_host, bound_port = server.server_address[:2]
    # Print the real bind address: "0.0.0.0" or a LAN address must not look local.
    display_host = "localhost" if str(bound_host) in ("127.0.0.1", "::1") else bound_host
    sys.stderr.write(f"SitePulse PM Workbench UI listening on http://{display_host}:{bound_port}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("SitePulse PM Workbench UI stopped.\n")
    finally:
        server.server_close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pm_workbench_web.py",
        description="SitePulse Product Manager Workbench Web UI (scenario gallery and cheat sheet)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--host", default=DEFAULT_UI_HOST, help="Loopback interface to bind")
    parser.add_argument("--port", type=int, default=DEFAULT_UI_PORT, help="UI port")
    parser.add_argument(
        "--allow-remote",
        action="store_true",
        help="Allow binding a non-loopback host (exposes persona credentials)",
    )
    parser.add_argument("--api-url", default=DEFAULT_API_URL, help="Backend API base URL")
    parser.add_argument("--web-url", default=DEFAULT_WEB_URL, help="Flutter Web client base URL")
    parser.add_argument("--db-name", default="sitepulse", help="PostgreSQL database name")
    parser.add_argument("--saas-email", default="admin@sitepulse.io", help="SaaS bootstrap admin email")
    parser.add_argument("--saas-password", default="E2E-Bootstrap-Admin-1", help="SaaS bootstrap admin password")
    parser.add_argument("--state-file", default=None, help="Active-scenario state file path")
    parser.add_argument("--skip-reload", action="store_true", help="Skip backend state reload while seeding")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    service = WorkbenchService(
        state_path=args.state_file,
        api_url=args.api_url,
        web_url=args.web_url,
        db_name=args.db_name,
        saas_email=args.saas_email,
        saas_password=args.saas_password,
        skip_reload=args.skip_reload,
    )
    try:
        serve(
            host=args.host,
            port=args.port,
            service=service,
            allow_remote=args.allow_remote,
        )
    except OSError as err:
        sys.stderr.write(f"Could not start the Workbench UI on {args.host}:{args.port}: {err}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
