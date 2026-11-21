"""Liability journey through sales, vacancies and move-ins (issue #249, EPIC-13 STORY-13-14).

Replays the five detailed units of docs/testing/journey-plan/zero-to-multi-site-financial-journey.md on two
isolated sites (Site A tariff 1,000.00, Site B tariff 750.00) between January and April 2027 on the
Europe/Istanbul E2E clock. The 83 filler owner-occupants of the full journey and the zero-site onboarding
steps belong to the sibling issues #247 and #248; this module builds the minimum needed locally: two
sites with the five units, their owners and tenants, set up as follows: blocks, units, persons, ownerships, occupancies and resident users are inserted with SQL
in `_build_site` (until #247 provides the onboarding builder); only the household, title-transfer,
occupancy and payment steps go through the supported manager commands.

Expected debtors are declared in `DEBTORS` from the fixture timeline, independently of any response.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal

from support.api import Api, Session
from support.journey_attempts import JourneyClock, JourneyManifest, _slug
from support.stack import E2EStack

D = Decimal
JAN, FEB, MAR, APR = "Ocak 2027", "Şubat 2027", "Mart 2027", "Nisan 2027"
PERIODS = (JAN, FEB, MAR, APR)
DUE = {JAN: "2027-01-10", FEB: "2027-02-10", MAR: "2027-03-10", APR: "2027-04-10"}
FIRST = {JAN: "2027-01-01", FEB: "2027-02-01", MAR: "2027-03-01", APR: "2027-04-01"}
TARIFF = {"A": D("1000.00"), "B": D("750.00")}

# unit label -> (site, block name, unit number)
UNITS = {"A-01": ("A", "A", 1), "A-02": ("A", "A", 2), "A-03": ("A", "A", 3),
         "B1-01": ("B", "B1", 1), "B2-01": ("B", "B2", 1)}
PEOPLE = {
    "Ada": "Ada Aksoy", "Mina": "Mina Aksoy", "Ben": "Ben Bilgin", "Cara": "Cara Cetin", "Dan": "Dan Demir",
    "Dora": "Dora Demir", "Eli": "Eli Erdem", "Ela": "Ela Ozkan", "Fay": "Fay Fidan", "Gus": "Gus Gunes",
    "Hana": "Hana Hanci", "Ivan": "Ivan Ilhan", "Juno": "Juno Jale",
}

# (unit, period) -> (debtor role, person) that owes the charge, from the fixture timeline.
DEBTORS: dict[tuple[str, str], tuple[str, str]] = {
    **{("A-01", p): ("OWNER", "Ada") for p in (JAN, FEB)}, **{("A-01", p): ("OWNER", "Ben") for p in (MAR, APR)},
    **{("A-02", p): ("TENANT", "Dan") for p in (JAN, FEB)}, ("A-02", MAR): ("OWNER", "Cara"),
    ("A-02", APR): ("TENANT", "Eli"),
    **{("A-03", p): ("OWNER", "Fay") for p in PERIODS},
    **{("B1-01", p): ("OWNER", "Gus") for p in (JAN, FEB)}, **{("B1-01", p): ("OWNER", "Hana") for p in (MAR, APR)},
    **{("B2-01", p): ("TENANT", "Juno") for p in PERIODS},
}

# month -> [(unit, payer, role, gross amount, designated period or None)] from the journey's payment table.
PAYMENTS: dict[str, list[tuple[str, str, str, Decimal, str | None]]] = {
    JAN: [("A-01", "Ada", "OWNER", D("400.00"), None), ("A-03", "Fay", "OWNER", D("1000.00"), None),
          ("B1-01", "Gus", "OWNER", D("750.00"), None), ("B2-01", "Juno", "TENANT", D("750.00"), None)],
    FEB: [("A-01", "Ada", "OWNER", D("831.00"), None), ("A-02", "Dan", "TENANT", D("1301.67"), None),
          ("B1-01", "Gus", "OWNER", D("250.00"), None)],
    MAR: [("A-01", "Ben", "OWNER", D("500.00"), None)],
    APR: [("A-01", "Ben", "OWNER", D("1025.83"), None), ("A-02", "Eli", "TENANT", D("600.00"), None),
          ("A-03", "Fay", "OWNER", D("1000.00"), APR), ("B1-01", "Hana", "OWNER", D("1038.75"), None),
          ("B2-01", "Juno", "TENANT", D("750.00"), APR)],
}

STAGES = ("jan_accrued", "jan_paid", "feb_accrued", "feb_paid", "mar_changed", "mar_accrued", "mar_paid",
          "apr_changed", "apr_accrued", "apr_paid")


@dataclass
class Site:
    key: str
    site_id: str
    manager: Session
    units: dict[str, str] = field(default_factory=dict)   # unit label -> unit id
    people: dict[str, str] = field(default_factory=dict)  # short name -> person id


@dataclass
class Posting:
    """One receipt with the state of its unit's other debtors immediately before and after it."""

    unit: str
    payer: str
    month: str
    receipt: dict
    before: dict
    after: dict
    other_site_cash_before: Decimal
    other_site_cash_after: Decimal


class LiabilityJourney:
    def __init__(self, api: Api, stack: E2EStack, saas: Session, manifest: JourneyManifest) -> None:
        manifest.bind_database(stack.db_name)
        self.api, self.stack, self.manifest = api, stack, manifest
        self.sites: dict[str, Site] = {}
        self.postings: list[Posting] = []
        self.history: dict[str, dict[str, dict]] = {}
        self.stage = "built"
        self.clock = JourneyClock(api, "2026-12-15")
        self._attempt = _slug(manifest.attempt_id)[:10]
        self._build_site("A", ("A",), {"A-01": ("Ada", "OWNER_OCC"), "A-02": ("Cara", "RENTED:Dan"),
                                       "A-03": ("Fay", "OWNER_OCC")})
        self._build_site("B", ("B1", "B2"), {"B1-01": ("Gus", "OWNER_OCC"), "B2-01": ("Ivan", "RENTED:Juno")})
        self._add_household("A-01", "Mina", "CHILD")
        self._add_household("A-02", "Dora", "CHILD")

    # ---- construction ---------------------------------------------------------------------------
    @staticmethod
    def _phone(short: str) -> str:
        return f"+90 533 000 {list(PEOPLE).index(short) + 10:02d} 00"

    def _email(self, key: str) -> str:
        return f"{self._attempt}.{key.lower()}@journey.e2e.test"

    def _build_site(self, key: str, blocks: tuple[str, ...], plan: dict[str, tuple[str, str]]) -> None:
        name = f"Journey liability {key} {self._attempt}"
        manager_email = f"journey.liability.{key.lower()}.{self._attempt}@e2e.test"
        creds = self.api.create_site(self.saas_session(), name, manager_email, admin_name=f"Manager {key}", blocks=())
        site_id = str(creds["site_id"])
        self.manifest.record("site_ids", site_id)
        password = f"E2E-Liability-{self._attempt}-Permanent-1!"
        self.api.change_password(manager_email, str(creds["temporary_password"]), password)
        manager_user = self.api.login(manager_email, password).user["id"]
        self.manifest.record("user_ids", manager_user)
        password_hash = self.stack.sql(f"SELECT password_hash FROM users WHERE id = {int(manager_user)};")
        site = int(site_id)
        sql = ["BEGIN;", f"DELETE FROM blocks WHERE site_id = {site};",
               f"UPDATE sites SET proration_enabled = FALSE, due_day = 10, accrual_day = 1, grace_days = 0 WHERE id = {site};",
               f"INSERT INTO house_types (site_id, type_name, dues_amount, description) VALUES "
               f"({site}, 'Tariff', {TARIFF[key]}, 'Journey liability tariff');"]
        for block in blocks:
            sql.append(f"INSERT INTO blocks (site_id, block_name, total_floors) VALUES ({site}, '{block}', 3);")
        for label, (unit_site, block, number) in UNITS.items():
            if unit_site != key:
                continue
            sql.append(
                "INSERT INTO units (block_id, site_id, unit_number, floor, land_share, occupancy_status, house_type, "
                "house_type_id, created_at) SELECT b.id, "
                f"{site}, {number}, 1, 1, 'VACANT', h.type_name, h.id, TIMESTAMPTZ '2026-12-01 00:00:00+00' "
                f"FROM blocks b JOIN house_types h ON h.site_id = b.site_id WHERE b.site_id = {site} "
                f"AND b.block_name = '{block}';")
        names: list[str] = []
        for _, (owner, occupant) in plan.items():
            names.append(owner)
            if occupant.startswith("RENTED:"):
                names.append(occupant.split(":")[1])
        for short in names:
            sql.append(
                "INSERT INTO persons (site_id, full_name, email, person_type) VALUES "
                f"({site}, '{PEOPLE[short]}', '{self._email(short)}', "
                f"'{'HOME_OWNER' if short in {p[0] for p in plan.values()} else 'HOME_RESIDENT'}');")
        for label, (owner, occupant) in plan.items():
            unit_filter = (f"u.site_id = {site} AND u.unit_number = {UNITS[label][2]} "
                           f"AND u.block_id = (SELECT id FROM blocks WHERE site_id = {site} "
                           f"AND block_name = '{UNITS[label][1]}')")
            owner_person = f"(SELECT id FROM persons WHERE site_id = {site} AND email = '{self._email(owner)}')"
            sql.append(f"UPDATE units u SET owner_person_id = {owner_person} WHERE {unit_filter};")
            sql.append("INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
                       f"SELECT u.id, {owner_person}, 100.00, DATE '2026-12-01', TRUE FROM units u WHERE {unit_filter};")
            if occupant == "OWNER_OCC":
                sql.append("UPDATE units u SET occupancy_status = 'OWNER_OCCUPIED' WHERE " + unit_filter + ";")
                sql.append("INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
                           f"SELECT u.id, {owner_person}, 'OWNER', DATE '2026-12-01', TRUE FROM units u WHERE {unit_filter};")
            else:
                tenant = occupant.split(":")[1]
                tenant_person = f"(SELECT id FROM persons WHERE site_id = {site} AND email = '{self._email(tenant)}')"
                sql.append(f"UPDATE units u SET occupancy_status = 'TENANT_OCCUPIED', tenant_person_id = {tenant_person} "
                           f"WHERE {unit_filter};")
                sql.append("INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
                           f"SELECT u.id, {tenant_person}, 'TENANT', DATE '2026-12-01', TRUE FROM units u WHERE {unit_filter};")
        emails = ", ".join(f"'{self._email(short)}'" for short in names)
        sql.append("INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password) "
                   f"SELECT p.site_id, p.id, p.email, '{password_hash}', "
                   "CASE WHEN p.person_type = 'HOME_OWNER' THEN 'HOME_OWNER' ELSE 'HOME_RESIDENT' END, FALSE "
                   f"FROM persons p WHERE p.site_id = {site} AND p.email IN ({emails});")
        sql.append("INSERT INTO user_site_roles (user_id, site_id, role) SELECT id, site_id, role FROM users "
                   f"WHERE site_id = {site} AND email IN ({emails}) ON CONFLICT (user_id, site_id, role) DO NOTHING;")
        sql.append("COMMIT;")
        self.stack.sql(" ".join(sql))
        self.stack.restart_backend()
        self.clock.set_date(self.clock.current_date.isoformat())
        manager = self.api.login(manager_email, password)
        built = Site(key, site_id, manager)
        for label, (unit_site, block, number) in UNITS.items():
            if unit_site == key:
                built.units[label] = self.stack.sql(
                    f"SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id WHERE u.site_id = {site} "
                    f"AND b.block_name = '{block}' AND u.unit_number = {number};")
                self.manifest.record("unit_ids", built.units[label])
        for short in names:
            built.people[short] = self.stack.sql(
                f"SELECT id FROM persons WHERE site_id = {site} AND email = '{self._email(short)}';")
            self.manifest.record("person_ids", built.people[short])
        self._manager_credentials = getattr(self, "_manager_credentials", {})
        self._manager_credentials[key] = (manager_email, password)
        self.sites[key] = built

    def saas_session(self) -> Session:
        from support import stack as st
        return self.api.login(st.SAAS_ADMIN_EMAIL, st.SAAS_ADMIN_PASSWORD)

    def _add_household(self, unit: str, member: str, relationship: str) -> None:
        site = self.site_of(unit)
        self.api.call("POST", f"/api/v1/home-residents/members/{site.units[unit]}?site_id={site.site_id}",
                      site.manager.token, body={
                          "person": {"kind": "new", "card": {"full_name": PEOPLE[member], "email": self._email(member),
                                                             "phone": self._phone(member)}},
                          "relationship": relationship})
        site.people[member] = self.stack.sql(
            f"SELECT id FROM persons WHERE site_id = {int(site.site_id)} AND email = '{self._email(member)}';")

    # ---- helpers --------------------------------------------------------------------------------
    def site_of(self, unit: str) -> Site:
        return self.sites[UNITS[unit][0]]

    def unit_id(self, unit: str) -> str:
        return self.site_of(unit).units[unit]

    def person_id(self, unit: str, short: str) -> str:
        return self.site_of(unit).people[short]

    def at(self, date: str, *, tick: bool = True) -> None:
        """Moves the clock; `tick=False` keeps the scheduler's own accrual from running before the day's changes."""
        self.clock.advance_to(date)
        if tick:
            self.clock.tick()

    def accrue(self, period: str) -> None:
        for site in self.sites.values():
            self.api.accrue_period(site.manager, period, D("0"), DUE[period])

    def _email_of_new(self, short: str) -> str:
        return self._email(short)

    def transition(self, unit: str, command: str, **body: object) -> dict:
        site = self.site_of(unit)
        return self.api.call(
            "POST", f"/api/v1/site-admin/units/{site.units[unit]}/occupancy-transitions?site_id={site.site_id}",
            site.manager.token, body={"command": command, "effective_date": self.clock.current_date.isoformat(), **body})

    def new_person(self, short: str) -> dict:
        return {"full_name": PEOPLE[short], "email": self._email(short), "phone": self._phone(short)}

    def sell(self, unit: str, buyer: str, moves_in: bool) -> None:
        site = self.site_of(unit)
        email, password = self._manager_credentials[site.key]
        self.api.call("POST", "/api/v1/auth/step-up", site.manager.token, body={"password": password})
        self.api.call("POST", f"/api/v1/site-admin/units/{site.units[unit]}/transfer-ownership", site.manager.token, body={
            "unit_id": site.units[unit], "new_owner_name": PEOPLE[buyer], "new_owner_email": self._email(buyer),
            "transfer_date": self.clock.current_date.isoformat(), "new_owner_moves_in": moves_in})
        site.people[buyer] = self.stack.sql(
            f"SELECT id FROM persons WHERE site_id = {int(site.site_id)} AND email = '{self._email(buyer)}';")
        self.manifest.record("person_ids", site.people[buyer])

    # ---- read model -----------------------------------------------------------------------------
    def charges(self, unit: str) -> dict[tuple[str, str], dict]:
        """Operational liability rows of a unit keyed by (period, role): the ledger the statement is built from."""
        raw = self.stack.sql(
            "SELECT d.period || '|' || d.debtor_type || '|' || d.principal_amount || '|' || d.paid_principal || '|' || "
            "d.paid_penalty || '|' || d.status || '|' || COALESCE(p.full_name, '') FROM dues_liabilities d "
            "LEFT JOIN persons p ON p.id = d.liable_person_id "
            f"WHERE d.unit_id = {int(self.unit_id(unit))} AND d.expense_type = 'OPERATIONAL_DUES' "
            "AND d.status <> 'CANCELLED' ORDER BY d.id;")
        rows = {}
        for line in raw.splitlines():
            period, role, principal, paid_principal, paid_penalty, status, liable = line.split("|")
            rows[(period, role)] = {"principal": D(principal), "paid_principal": D(paid_principal),
                                    "paid_penalty": D(paid_penalty), "status": status, "liable": liable}
        return rows

    def statement(self, unit: str) -> dict:
        return self.api.resident_statement(self.site_of(unit).manager, self.unit_id(unit))

    def open_items(self, unit: str) -> dict[tuple[str, str], tuple[Decimal, Decimal]]:
        """(period, role) -> (principal outstanding, fee outstanding) from the manager's unit statement."""
        items = {}
        for debtor in self.statement(unit)["debtors"]:
            for item in debtor["open_items"]:
                if item["expense_type"] == "OPERATIONAL_DUES":
                    items[(item["period"], debtor["debtor_type"])] = (
                        D(str(item["principal_outstanding"])), D(str(item["penalty_outstanding"])))
        return items

    def snapshot(self, unit: str) -> dict:
        return {"open": self.open_items(unit), "charges": self.charges(unit)}

    def cash(self, site_key: str) -> Decimal:
        """Posted operating cash: the sum of the site's receipts (opening cash is zero, there are no expenses)."""
        value = self.stack.sql(
            f"SELECT COALESCE(sum(total_amount), 0) FROM payment_receipts WHERE site_id = {int(self.sites[site_key].site_id)};")
        return D(value)

    # ---- timeline -------------------------------------------------------------------------------
    def pay(self, unit: str, payer: str, role: str, amount: Decimal, month: str, period: str | None = None) -> Posting:
        site = self.site_of(unit)
        other = "B" if site.key == "A" else "A"
        before, cash_before = self.snapshot(unit), self.cash(other)
        body = {"site_id": site.site_id, "unit_id": site.units[unit], "amount": str(amount),
                "payer_name": PEOPLE[payer], "payer_role": role, "payment_channel": "MANUAL_CASH",
                "description": f"{unit} {month}", "idempotency_key": f"j249-{self._attempt}-{unit}-{month}-{payer}"}
        if period:
            body["designation"] = {"periods": [period]}
        receipt = self.api.call("POST", "/api/v1/payments/record-manual", site.manager.token, body=body)
        posting = Posting(unit, payer, month, receipt, before, self.snapshot(unit), cash_before, self.cash(other))
        self.postings.append(posting)
        return posting

    def posting(self, unit: str, payer: str, month: str) -> Posting:
        return next(p for p in self.postings if (p.unit, p.payer, p.month) == (unit, payer, month))

    def pay_month(self, month: str) -> None:
        self.at(DUE[month])
        for unit, payer, role, amount, designated in PAYMENTS[month]:
            self.pay(unit, payer, role, amount, month, designated)

    def run_through(self, stage: str) -> "LiabilityJourney":
        """Plays the timeline up to and including `stage` (one of STAGES)."""
        last = STAGES.index(stage)
        done = STAGES.index(self.stage) + 1 if self.stage in STAGES else 0
        steps = [
            ("jan_accrued", lambda: (self.at(FIRST[JAN]), self.accrue(JAN))),
            ("jan_paid", lambda: self.pay_month(JAN)),
            ("feb_accrued", lambda: (self.at(FIRST[FEB]), self.accrue(FEB))),
            ("feb_paid", lambda: self.pay_month(FEB)),
            ("mar_changed", self._march_changes),
            ("mar_accrued", lambda: self.accrue(MAR)),
            ("mar_paid", lambda: self.pay_month(MAR)),
            ("apr_changed", self._april_changes),
            ("apr_accrued", lambda: self.accrue(APR)),
            ("apr_paid", lambda: self.pay_month(APR)),
        ]
        for name, action in steps[done: last + 1]:
            action()
            self.stage = name
            self.history[name] = {unit: self.open_items(unit) for unit in ("A-03", "B2-01")}
        return self

    def _march_changes(self) -> None:
        self.at(FIRST[MAR], tick=False)
        self.sell("A-01", "Ben", moves_in=True)        # Ada sells A-01 to Ben, who moves in
        self.sell("B1-01", "Hana", moves_in=False)     # Gus sells B1-01 to Hana, who leaves it vacant
        self.transition("A-02", "MOVE_OUT")            # Dan moves out of A-02
        self.transition("A-03", "MOVE_OUT")            # Fay moves out of A-03 and retains title

    def _april_changes(self) -> None:
        self.at(FIRST[APR], tick=False)
        self.transition("A-02", "TENANT_MOVE_IN", **self.new_person("Eli"))
        self.sites["A"].people["Eli"] = self.stack.sql(
            f"SELECT id FROM persons WHERE site_id = {int(self.sites['A'].site_id)} AND email = '{self._email('Eli')}';")
        self._add_household("A-02", "Ela", "CHILD")
        self.transition("B1-01", "OWNER_MOVE_IN")      # Hana moves into B1-01; A-03 stays vacant

    # ---- roster and occupancy reads --------------------------------------------------------------
    def occupancies(self, unit: str) -> list[dict]:
        raw = self.stack.sql(
            "SELECT p.full_name || '|' || o.occupancy_type || '|' || o.start_date || '|' || COALESCE(o.end_date::text, '') "
            "|| '|' || o.is_active FROM unit_occupancies o JOIN persons p ON p.id = o.person_id "
            f"WHERE o.unit_id = {int(self.unit_id(unit))} ORDER BY o.id;")
        rows = []
        for line in raw.splitlines():
            name, kind, start, end, active = line.split("|")
            rows.append({"name": name, "type": kind, "start": start, "end": end, "active": active == "true"})
        return rows

    def ownerships(self, unit: str) -> list[dict]:
        raw = self.stack.sql(
            "SELECT p.full_name || '|' || o.start_date || '|' || COALESCE(o.end_date::text, '') || '|' || o.is_active "
            f"FROM unit_ownerships o JOIN persons p ON p.id = o.person_id WHERE o.unit_id = {int(self.unit_id(unit))} "
            "ORDER BY o.id;")
        rows = []
        for line in raw.splitlines():
            name, start, end, active = line.split("|")
            rows.append({"name": name, "start": start, "end": end, "active": active == "true"})
        return rows

    def roster(self, unit: str) -> list[str]:
        site = self.site_of(unit)
        members = self.api.call("GET", f"/api/v1/home-residents/members/{site.units[unit]}?site_id={site.site_id}",
                                site.manager.token)
        return sorted(member["full_name"] for member in members)

    def archived_household(self, unit: str, primary: str) -> list[str]:
        """Household members archived under a closed occupancy of `primary` in the unit."""
        raw = self.stack.sql(
            "SELECT m.full_name FROM occupancy_members m JOIN unit_occupancies o ON o.id = m.occupancy_id "
            "JOIN persons po ON po.id = o.person_id "
            f"WHERE o.unit_id = {int(self.unit_id(unit))} AND NOT o.is_active AND po.full_name = '{PEOPLE[primary]}' "
            "ORDER BY m.full_name;")
        return raw.splitlines()
