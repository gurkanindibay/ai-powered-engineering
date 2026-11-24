"""Backend client and Arrange-step data builders for GUI tests.

Builders prefer real REST endpoints. Where the API has no way to express the
needed state (e.g. a dues liability with a specific starting status) the
builder writes SQL and restarts the backend so its in-memory state reloads;
such builders are marked "SQL arrange". Date-driven scheduled jobs use
`E2EClock`.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import date as CalendarDate
from decimal import Decimal

from .stack import WEBHOOK_SECRET, E2EStack, api_base


class ApiError(RuntimeError):
    pass


@dataclass
class Session:
    token: str
    user: dict


class E2EClock:
    """Controls date-driven backend jobs through the E2E-only scheduler API."""

    def __init__(self, api: Api):
        self.api = api

    @staticmethod
    def _date_text(value: CalendarDate | str) -> str:
        return value.isoformat() if isinstance(value, CalendarDate) else value

    def set_date(self, value: CalendarDate | str) -> dict:
        return self.api.call("POST", "/__e2e/clock", body={
            "action": "set_date", "date": self._date_text(value),
        })

    def advance_to(self, value: CalendarDate | str) -> dict:
        return self.api.call("POST", "/__e2e/clock", body={
            "action": "advance_to", "date": self._date_text(value),
        })

    def set_instant(self, value: str) -> dict:
        """Set an exact instant (RFC 3339, e.g. `2026-11-30T20:30:00Z`), for boundaries inside a UTC day."""
        return self.api.call("POST", "/__e2e/clock", body={"action": "set_instant", "at": value})

    def tick(self, *, timeout: float = 30) -> dict:
        return self.api.call("POST", "/__e2e/clock", body={"action": "tick"}, timeout=timeout)

    def clear(self) -> dict:
        """Return the backend process to the system clock."""
        return self.api.call("POST", "/__e2e/clock", body={"action": "clear"})


class Api:
    def __init__(self, base: str | None = None, stack: E2EStack | None = None):
        self.base = base or api_base()
        self.stack = stack
        self.clock = E2EClock(self)
        self.network_events: list[dict[str, str | int]] = []

    def call(self, method: str, path: str, token: str | None = None,
             body: object | None = None, *, timeout: float = 30) -> object:
        data = json.dumps(body).encode() if body is not None else (b"{}" if method in ("POST", "PUT") else None)
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode()
                self.network_events.append({"method": method, "route": path.split("?", 1)[0], "status": resp.status})
        except urllib.error.HTTPError as exc:
            self.network_events.append({"method": method, "route": path.split("?", 1)[0], "status": exc.code})
            raise ApiError(f"{method} {path} -> {exc.code}: {exc.read().decode()[:300]}") from None
        result = json.loads(raw) if raw else None
        if method == "POST" and path == "/__e2e/clock" and isinstance(body, dict):
            if self.stack is not None:
                self.stack.remember_e2e_clock(body)
        return result

    def login(self, email: str, password: str) -> Session:
        out = self.call("POST", "/api/v1/auth/login", body={"email": email, "password": password})
        return Session(out["access_token"], out["user"])

    # -- reads used as expected values -------------------------------------
    def resident_dashboard(self, session: Session) -> dict:
        return self.call("GET", f"/api/v1/residents/{session.user['unit_id']}/dashboard", session.token)

    def saas_sites(self, session: Session) -> list[dict]:
        return self.call("GET", "/api/v1/saas/sites", session.token)

    def saas_stats(self, session: Session) -> dict:
        return self.call("GET", "/api/v1/saas/stats", session.token)

    def site_overview(self, session: Session, site_id: str) -> dict:
        query = urllib.parse.urlencode({"site_id": site_id})
        return self.call("GET", f"/api/v1/site-admin/overview?{query}", session.token)

    def payment_stream(self, session: Session, **filters: str) -> dict:
        query = "&".join(f"{k}={urllib.parse.quote(str(v))}" for k, v in
                         {"site_id": session.user.get("site_id", ""), **filters}.items())
        return self.call("GET", f"/api/v1/payments/stream?{query}", session.token)

    def debt_aging_report(self, session: Session, site_id: str) -> dict:
        return self.call("GET", f"/api/v1/payments/debt-aging?site_id={site_id}", session.token)

    def resident_statement(self, session: Session, unit_id: str) -> dict:
        return self.call("GET", f"/api/v1/residents/{unit_id}/statement", session.token)

    def e2e_clock(self, action: str, date: str | None = None) -> dict:
        """Control the E2E-only backend clock; unavailable in normal backend builds."""
        if action not in {"set_date", "advance_to", "tick", "clear"}:
            raise ValueError(f"Unsupported E2E clock action: {action}")
        if action in {"tick", "clear"} and date is not None:
            raise ValueError(f"The E2E clock {action} action does not accept a date")
        if action not in {"tick", "clear"} and date is None:
            raise ValueError(f"The E2E clock action {action!r} requires a date")
        body: dict[str, str] = {"action": action}
        if date is not None:
            body["date"] = date
        return self.call("POST", "/__e2e/clock", body=body)

    # -- writes used by Arrange steps ---------------------------------------
    def change_password(self, email: str, current: str, new: str) -> Session:
        token = self.login(email, current).token
        out = self.call("POST", "/api/v1/auth/change-password", token,
                        body={"email": email, "current_password": current, "new_password": new})
        return Session(out["access_token"], out["user"])

    def create_site(self, saas: Session, name: str, admin_email: str, admin_name: str = "Murat Yıldırım",
                    blocks: tuple[str, ...] = ("A Blok",)) -> dict:
        """SaaS onboarding through the API; returns site_id and the manager's temporary_password."""
        return self.call("POST", "/api/v1/saas/sites", saas.token, body={
            "site_name": name, "address": "Kadıköy, İstanbul", "site_admin_full_name": admin_name,
            "site_admin_email": admin_email, "site_admin_phone": "+90 532 000 00 00", "plan_type": "STANDARD",
            "blocks": list(blocks)})

    def webhook_transfer(self, virtual_iban: str, amount: Decimal, transaction_id: str,
                         description: str = "FAST transfer") -> dict:
        """Signed bank webhook for an incoming FAST transfer (STORY-07-03); replays are idempotent."""
        body = json.dumps({"transaction_id": transaction_id, "virtual_iban": virtual_iban, "amount": str(amount),
                           "currency": "TRY", "description": description}).encode()
        req = urllib.request.Request(self.base + "/api/v1/bank/webhook/incoming-transfer", data=body, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("X-SitePulse-Signature", hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest())
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as exc:
            raise ApiError(f"webhook -> {exc.code}: {exc.read().decode()[:300]}") from None

    def submit_registration(self, slug: str, full_name: str, email: str, block: str, unit_no: int,
                            floor: int = 1, phone: str = "+90 532 000 00 00", is_resident: bool = False) -> dict:
        """Public self-registration form (STORY-04-03); the request waits for the manager."""
        return self.call("POST", f"/api/v1/registration/submit/{slug}", body={
            "full_name": full_name, "email": email, "phone": phone, "block": block,
            "unit_no": unit_no, "floor": floor, "is_resident": is_resident})

    def move_in(self, session: Session, unit_id: str, full_name: str, email: str, role: str = "TENANT",
                phone: str = "+90 533 000 00 00") -> dict:
        """Moves a tenant in with the command the unit's state allows (EPIC-08 §3.3).

        An owner-occupied unit is rented out (C2) and a tenant-occupied one gets a
        replacement tenant (C1); an owner move-in takes no person data (T3).
        Returns the opened occupancy session.
        """
        site = session.user["site_id"]
        if role.upper() == "OWNER":
            command = "OWNER_MOVE_IN"
            body = {"command": command}
        else:
            state = self.call("GET", f"/api/v1/site-admin/units/{unit_id}/occupancy-state?site_id={site}",
                              session.token)
            command = {"OWNER_OCCUPIED": "OWNER_RENTS_OUT",
                       "TENANT_OCCUPIED": "REPLACE_TENANT"}.get(state.get("occupancy"), "TENANT_MOVE_IN")
            body = {"command": command, "full_name": full_name, "email": email, "phone": phone}
        result = self.call("POST", f"/api/v1/site-admin/units/{unit_id}/occupancy-transitions?site_id={site}",
                           session.token, body=body)
        return result.get("opened") or {}

    def move_out(self, session: Session, unit_id: str) -> dict:
        return self.call("POST", f"/api/v1/site-admin/units/{unit_id}/move-out?site_id={session.user['site_id']}",
                         session.token, body={"notes": "E2E move-out"})

    def create_period(self, session: Session, name: str, due_date: str) -> dict:
        return self.call("POST", "/api/v1/dues/periods", session.token,
                         body={"site_id": session.user["site_id"], "period_name": name, "due_date": due_date})

    def accrue_period(self, session: Session, period: str, amount: Decimal | str | None, due_date: str) -> dict:
        body = {
            "site_id": session.user["site_id"],
            "period": period,
            "due_date": due_date,
        }
        if amount is not None:
            body["amount"] = str(amount)
        return self.call("POST", "/api/v1/dues/accrue-period", session.token, body=body)

    def list_periods(self, session: Session, site_id: str | None = None) -> list[dict]:
        query = f"?site_id={site_id or session.user['site_id']}"
        return self.call("GET", f"/api/v1/dues/periods{query}", session.token)

    def close_period(self, session: Session, period_id: str | int) -> dict:
        return self.call("POST", f"/api/v1/dues/periods/{period_id}/close", session.token)

    def create_capital_project(self, session: Session, title: str, budget: Decimal,
                               basis: str = "BY_LAND_SHARE", installments: int = 1,
                               first_due: str = "2026-11-30") -> dict:
        """Capital project with equal installments (the last one absorbs the kuruş remainder)."""
        per = (budget / installments).quantize(Decimal("0.01"), rounding="ROUND_DOWN")
        items = [{"installment_number": i, "total_installments": installments, "due_date": first_due,
                  "installment_budget": str(per if i < installments else budget - per * (installments - 1))}
                 for i in range(1, installments + 1)]
        return self.call("POST", "/api/v1/capital-projects", session.token, body={
            "site_id": session.user["site_id"], "title": title, "category": "OTHER", "total_budget": str(budget),
            "allocation_basis": basis, "contract_amount": str(budget), "installments": items})

    def accrue_installment(self, session: Session, project_id: str, number: int) -> dict:
        return self.call("POST", f"/api/v1/capital-projects/{project_id}/accrue-installment"
                                 f"?site_id={session.user['site_id']}", session.token,
                         body={"installment_number": number})

    def record_manual_payment(self, session: Session, unit_id: str, amount: Decimal, payer_name: str,
                              payer_role: str = "OWNER", channel: str = "MANUAL_CASH",
                              description: str | None = None,
                              settles_owner_capital_dues: bool = False,
                              payment_date: str | None = None,
                              designation: dict | None = None,
                              idempotency_key: str | None = None) -> dict:
        body = {
            "site_id": session.user.get("site_id"), "unit_id": str(unit_id), "amount": str(amount),
            "payer_name": payer_name, "payer_role": payer_role, "payment_channel": channel,
            "description": description, "settles_owner_capital_dues": settles_owner_capital_dues,
            "idempotency_key": idempotency_key or f"e2e-{payer_role}-{unit_id}-{amount}-{payer_name}",
        }
        if payment_date:
            body["payment_date"] = payment_date
        if designation:
            body["designation"] = designation
        return self.call("POST", "/api/v1/payments/record-manual", session.token, body=body)

    def reverse_payment(self, session: Session, receipt: str, reason: str = "Bounced payment") -> dict:
        return self.call(
            "POST",
            "/api/v1/payments/reverse",
            session.token,
            body={"site_id": session.user.get("site_id"), "receipt": str(receipt), "reason": reason},
        )

    def get_blocks(self, session: Session, site_id: str | None = None) -> list[dict]:
        """Lists blocks for the site."""
        query = f"?site_id={site_id}" if site_id else ""
        return self.call("GET", f"/api/v1/site-admin/blocks{query}", session.token)

    def create_block(self, session: Session, block_name: str, total_floors: int = 10,
                     site_id: str | None = None) -> dict:
        """Creates a block in the site."""
        query = f"?site_id={site_id}" if site_id else ""
        return self.call("POST", f"/api/v1/site-admin/blocks{query}", session.token,
                         body={"block_name": block_name, "total_floors": total_floors})

    def get_units(self, session: Session, site_id: str | None = None) -> list[dict]:
        """Lists units for the site."""
        query = f"?site_id={site_id}" if site_id else ""
        return self.call("GET", f"/api/v1/site-admin/units{query}", session.token)

    def create_units(self, session: Session, block_name: str, start_unit: int | None = None,
                     end_unit: int | None = None, unit_number: int | None = None,
                     unit_numbers: list[int] | None = None, site_id: str | None = None) -> list[dict]:
        """Creates units in a block."""
        query = f"?site_id={site_id}" if site_id else ""
        body: dict = {"block_name": block_name}
        if start_unit is not None and end_unit is not None:
            body["start_unit"] = start_unit
            body["end_unit"] = end_unit
        elif unit_number is not None:
            body["unit_number"] = unit_number
        elif unit_numbers is not None:
            body["unit_numbers"] = unit_numbers
        return self.call("POST", f"/api/v1/site-admin/units{query}", session.token, body=body)

    def register_home_owner(self, session: Session, block: str, unit_no: int,
                            owner_full_name: str, email: str, phone: str = "+90 532 000 00 00",
                            is_resident: bool = True, tenant: dict | None = None,
                            household_members: list[dict] | None = None,
                            monthly_dues: Decimal = Decimal("0.00"),
                            house_type: str | None = None,
                            floor: int | None = None,
                            site_id: str | None = None) -> dict:
        """Registers a resident/owner into a unit."""
        query = f"?site_id={site_id}" if site_id else ""
        if floor is None:
            floor = ((unit_no - 1) // 4) + 1
        body: dict = {
            "block": block,
            "unit_no": unit_no,
            "floor": floor,
            "owner_full_name": owner_full_name,
            "email": email,
            "phone": phone,
            "is_resident": is_resident,
            "monthly_dues": str(monthly_dues),
        }
        if house_type is not None:
            body["house_type"] = house_type
        if tenant:
            if "new" in tenant or "id" in tenant:
                body["tenant"] = tenant
            else:
                body["tenant_full_name"] = tenant.get("full_name")
                body["tenant_email"] = tenant.get("email")
                body["tenant_phone"] = tenant.get("phone", "+90 532 000 00 00")
        if household_members:
            body["members"] = [
                {
                    "person": {
                        "kind": "new",
                        "card": {
                            "full_name": m["full_name"],
                            "phone": m.get("phone", "+90 532 000 00 00"),
                            "email": m.get("email", ""),
                        },
                    } if "person" not in m else m["person"],
                    "relationship": m.get("relationship", "OTHER"),
                }
                for m in household_members
            ]
        return self.call("POST", f"/api/v1/site-admin/home-owners{query}", session.token, body=body)

    def get_unit_occupancy_state(self, session: Session, unit_id: str, site_id: str | None = None) -> dict:
        site = site_id or session.user["site_id"]
        return self.call("GET", f"/api/v1/site-admin/units/{unit_id}/occupancy-state?site_id={site}", session.token)

    def get_unit_members(self, session: Session, unit_id: str, site_id: str | None = None) -> list[dict]:
        site = site_id or session.user["site_id"]
        return self.call("GET", f"/api/v1/home-residents/members/{unit_id}?site_id={site}", session.token)

    def add_unit_member(self, session: Session, unit_id: str, full_name: str,
                        relationship: str = "OTHER", phone: str = "+90 532 000 00 00",
                        email: str = "", site_id: str | None = None) -> dict:
        site = site_id or session.user["site_id"]
        body = {
            "person": {
                "kind": "new",
                "card": {
                    "full_name": full_name,
                    "phone": phone,
                    "email": email,
                },
            },
            "relationship": relationship,
        }
        return self.call("POST", f"/api/v1/home-residents/members/{unit_id}?site_id={site}", session.token, body=body)


class Builders:
    """Arrange helpers. Each returns what it created."""

    def __init__(self, stack: E2EStack):
        self.stack = stack

    def overdue_dues(self, unit_number: int = 14, principal: Decimal = Decimal("1400.00"),
                     days_overdue: int = 10, period: str = "Eylül 2026",
                     debtor_type: str | None = None) -> dict:
        """SQL arrange: a PENDING operational dues liability whose due date is in the past."""
        unit_id = self.stack.sql(f"SELECT id FROM units WHERE unit_number = {int(unit_number)} LIMIT 1;")
        if not unit_id:
            raise ApiError(f"unit {unit_number} not found in seed")
        if not debtor_type:
            tenant = self.stack.sql(f"SELECT tenant_person_id FROM units WHERE id = {int(unit_id)};").strip()
            debtor_type = "TENANT" if tenant else "OWNER"
        person_col = "tenant_person_id" if debtor_type == "TENANT" else "owner_person_id"
        person_id = self.stack.sql(f"SELECT {person_col} FROM units WHERE id = {int(unit_id)};").strip()
        person_sql = f"{int(person_id)}" if person_id else "NULL"
        liability_id = self.stack.sql(
            "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type, liable_person_id) "
            f"VALUES ({int(unit_id)}, '{period}', {principal}, CURRENT_DATE - {int(days_overdue)}, 'PENDING', '{debtor_type}', {person_sql}) "
            "RETURNING id;").splitlines()[0]
        self.stack.restart_backend()
        return {"unit_id": unit_id, "liability_id": liability_id, "principal": principal}

    def overdue_since_period_due_date(self, period: str) -> None:
        """SQL arrange: charges of `period` that were created on time, so late fee and aging count
        from their period due date (an accrual run after the due date counts from its own day)."""
        self.stack.sql(f"UPDATE dues_liabilities SET effective_due_date = due_date WHERE period = '{period}';")
        self.stack.restart_backend()

    def tenant_debt(self, unit_id: str, amount: Decimal, period: str = "Ekim 2026") -> dict:
        """SQL arrange: an unpaid TENANT liability tied to the unit's active tenant occupancy."""
        row = self.stack.sql(
            "SELECT id, person_id FROM unit_occupancies "
            f"WHERE unit_id = {int(unit_id)} AND occupancy_type = 'TENANT' AND is_active LIMIT 1;")
        if not row:
            raise ApiError(f"unit {unit_id} has no active tenant")
        occupancy_id, person_id = row.split("|")
        liability_id = self.stack.sql(
            "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, "
            "occupancy_id, principal_amount, due_date, status) "
            f"VALUES ({int(unit_id)}, '{period}', 'TENANT', 'OPERATIONAL_DUES', {int(person_id)}, "
            f"{int(occupancy_id)}, {amount}, CURRENT_DATE - 5, 'PENDING') RETURNING id;").splitlines()[0]
        self.stack.restart_backend()
        return {"liability_id": liability_id, "occupancy_id": occupancy_id, "person_id": person_id}

    def foreign_site_unit(self, slug: str = "kardelen-rezidans") -> str:
        """SQL arrange: a block, owner and unit on another tenant; returns the unit id."""
        site_id = self.stack.sql(f"SELECT id FROM sites WHERE slug = '{slug}';")
        block_id = self.stack.sql(
            f"INSERT INTO blocks (site_id, block_name, total_floors) VALUES ({int(site_id)}, 'K Blok', 5) "
            "RETURNING id;").splitlines()[0]
        person_id = self.stack.sql(
            "INSERT INTO persons (national_id, full_name, phone, email, person_type) VALUES "
            "('77777777777', 'Kardelen Maliki', '+90 532 777 77 77', 'kardelen.malik@e2e.test', 'HOME_OWNER') "
            "RETURNING id;").splitlines()[0]
        unit_id = self.stack.sql(
            "INSERT INTO units (block_id, site_id, unit_number, floor, land_share, owner_person_id, virtual_iban) "
            f"VALUES ({int(block_id)}, {int(site_id)}, 5, 2, 20, {int(person_id)}, 'TR620020500009863791600099') "
            "RETURNING id;").splitlines()[0]
        self.stack.restart_backend()
        return unit_id


def raw_call(api: Api, method: str, path: str, token: str, body: object | None = None) -> tuple[int, str]:
    """Execute a raw HTTP request against the API without high-level error wrapping."""
    data = json.dumps(body).encode() if body is not None else (b"{}" if method in ("POST", "PUT") else None)
    request = urllib.request.Request(api.base + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()

