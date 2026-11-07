"""Backend client and Arrange-step data builders for GUI tests.

Builders prefer real REST endpoints. Where the API has no way to express the
needed state (e.g. a dues liability that is already overdue, since the backend
has no clock control) the builder writes SQL and restarts the backend so its
in-memory state reloads; such builders are marked "SQL arrange".
"""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from decimal import Decimal

from .stack import E2EStack, api_base


class ApiError(RuntimeError):
    pass


@dataclass
class Session:
    token: str
    user: dict


class Api:
    def __init__(self, base: str | None = None):
        self.base = base or api_base()

    def call(self, method: str, path: str, token: str | None = None, body: object | None = None) -> object:
        data = json.dumps(body).encode() if body is not None else (b"{}" if method in ("POST", "PUT") else None)
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode()
        except urllib.error.HTTPError as exc:
            raise ApiError(f"{method} {path} -> {exc.code}: {exc.read().decode()[:300]}") from None
        return json.loads(raw) if raw else None

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

    def payment_stream(self, session: Session, **filters: str) -> dict:
        query = "&".join(f"{k}={urllib.parse.quote(str(v))}" for k, v in
                         {"site_id": session.user.get("site_id", ""), **filters}.items())
        return self.call("GET", f"/api/v1/payments/stream?{query}", session.token)

    # -- writes used by Arrange steps ---------------------------------------
    def change_password(self, email: str, current: str, new: str) -> Session:
        token = self.login(email, current).token
        out = self.call("POST", "/api/v1/auth/change-password", token,
                        body={"email": email, "current_password": current, "new_password": new})
        return Session(out["access_token"], out["user"])

    def submit_registration(self, slug: str, full_name: str, email: str, block: str, unit_no: int,
                            floor: int = 1, phone: str = "+90 532 000 00 00", is_resident: bool = False) -> dict:
        """Public self-registration form (STORY-04-03); the request waits for the manager."""
        return self.call("POST", f"/api/v1/registration/submit/{slug}", body={
            "full_name": full_name, "email": email, "phone": phone, "block": block,
            "unit_no": unit_no, "floor": floor, "is_resident": is_resident})

    def move_in(self, session: Session, unit_id: str, full_name: str, email: str, role: str = "TENANT",
                phone: str = "+90 533 000 00 00") -> dict:
        return self.call("POST", f"/api/v1/site-admin/units/{unit_id}/move-in?site_id={session.user['site_id']}",
                         session.token, body={"role": role, "full_name": full_name, "email": email, "phone": phone})

    def create_period(self, session: Session, name: str, due_date: str) -> dict:
        return self.call("POST", "/api/v1/dues/periods", session.token,
                         body={"site_id": session.user["site_id"], "period_name": name, "due_date": due_date})

    def accrue_period(self, session: Session, period: str, amount: Decimal, due_date: str) -> dict:
        return self.call("POST", "/api/v1/dues/accrue-period", session.token, body={
            "site_id": session.user["site_id"], "period": period, "amount": str(amount), "due_date": due_date})

    def record_manual_payment(self, session: Session, unit_id: str, amount: Decimal, payer_name: str,
                              payer_role: str = "OWNER", channel: str = "MANUAL_CASH",
                              description: str | None = None) -> dict:
        return self.call("POST", "/api/v1/payments/record-manual", session.token, body={
            "site_id": session.user.get("site_id"), "unit_id": str(unit_id), "amount": str(amount),
            "payer_name": payer_name, "payer_role": payer_role, "payment_channel": channel,
            "description": description, "idempotency_key": f"e2e-{payer_role}-{unit_id}-{amount}-{payer_name}"})


class Builders:
    """Arrange helpers. Each returns what it created."""

    def __init__(self, stack: E2EStack):
        self.stack = stack

    def overdue_dues(self, unit_number: int = 14, principal: Decimal = Decimal("1400.00"),
                     days_overdue: int = 10, period: str = "Eylül 2026") -> dict:
        """SQL arrange: a PENDING operational dues liability whose due date is in the past."""
        unit_id = self.stack.sql(f"SELECT id FROM units WHERE unit_number = {int(unit_number)} LIMIT 1;")
        if not unit_id:
            raise ApiError(f"unit {unit_number} not found in seed")
        liability_id = self.stack.sql(
            "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status) "
            f"VALUES ({int(unit_id)}, '{period}', {principal}, CURRENT_DATE - {int(days_overdue)}, 'PENDING') "
            "RETURNING id;").splitlines()[0]
        self.stack.restart_backend()
        return {"unit_id": unit_id, "liability_id": liability_id, "principal": principal}

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
