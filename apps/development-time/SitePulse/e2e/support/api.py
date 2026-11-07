"""Backend client and Arrange-step data builders for GUI tests.

Builders prefer real REST endpoints. Where the API has no way to express the
needed state (e.g. a dues liability that is already overdue, since the backend
has no clock control) the builder writes SQL and restarts the backend so its
in-memory state reloads; such builders are marked "SQL arrange".
"""
from __future__ import annotations

import json
import urllib.error
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
