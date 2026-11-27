"""Local session heartbeat leases for the 0-token coordinator (Phase 4, §4.6 Layer 3).

Every interactive session, headless CLI worker and T3 child writes a small
lease file while it works. The file records who it is, which issue/PR and
worktree it owns, and how far its context and quota are consumed. The
coordinator daemon reads those files (never an LLM) and can tell a live worker
from a stalled one.

A lease is *alive* until its TTL passes, *stale* for one more TTL (the worker
may simply be thinking or blocked on a long command), and *expired* after
twice its TTL. Only an expired lease is a watchdog candidate, so a slow step
never causes a spurious handover.

Leases live in the main checkout's ``.agents/local/sessions/`` (shared by all
worktrees, like the agent-name and token ledgers) and are ignored by git.
Credentials or prompt content never belong in a lease: only ids and counters.

Usage:
    from scripts.engineering_harness.leases import Lease, LeaseStore

    store = LeaseStore(root)
    store.heartbeat(Lease(harness="t3", session="ses_abc", issue=549, model="deepseek-flash"))
    for lease in store.expired():
        ...
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
import re
import sqlite3
from typing import Any, Callable, Iterable

SCHEMA_VERSION = 1
DEFAULT_TTL_SECONDS = 900
STALE_FACTOR = 2
STATES = ("alive", "stale", "expired")
DEFAULT_RELATIVE = Path(".agents") / "local" / "sessions"
_SLUG = re.compile(r"[^a-z0-9._-]+")
_MAX_SLUG = 80


class LeaseError(ValueError):
    """A lease or lease store is malformed (exit 2 for the CLI)."""


def slug(value: str) -> str:
    """Filesystem-safe, label-safe form of a harness or session id."""
    text = _SLUG.sub("-", str(value).strip().lower()).strip("-.")
    return text[:_MAX_SLUG] or "unknown"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def parse_timestamp(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
    except ValueError as exc:
        raise LeaseError(f"invalid timestamp: {value!r}") from exc
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def isoformat(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def decimal_pct(value: Any, name: str) -> str | None:
    """Percent values are decimal strings (never binary floats)."""
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    if isinstance(value, (bool, float)):
        raise LeaseError(f"{name} must be a decimal string or integer")
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise LeaseError(f"{name} must be a decimal number") from exc
    if not parsed.is_finite() or parsed < 0 or parsed > 100:
        raise LeaseError(f"{name} must be between 0 and 100")
    return format(parsed.normalize(), "f")


def _optional_int(value: Any, name: str, *, positive: bool = False) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise LeaseError(f"{name} must be an integer")
    if positive and value <= 0:
        raise LeaseError(f"{name} must be a positive integer")
    if value < 0:
        raise LeaseError(f"{name} must be nonnegative")
    return value


def process_start_ticks(pid: int) -> int | None:
    """Return process start time in clock ticks from /proc/<pid>/stat (field 22), or None."""
    if pid <= 1:
        return None
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    rparen = raw.rfind(")")
    if rparen == -1:
        return None
    fields = raw[rparen + 2 :].split()
    if len(fields) <= 19:
        return None
    try:
        return int(fields[19])
    except ValueError:
        return None


def process_cwd(pid: int) -> Path | None:
    """Return the live working directory of pid from /proc/<pid>/cwd, or None."""
    if pid <= 1:
        return None
    try:
        return Path(os.readlink(f"/proc/{pid}/cwd")).resolve()
    except OSError:
        return None


@dataclass(frozen=True)
class Lease:
    """One worker's heartbeat. ``ttl_seconds`` is the liveness window."""

    harness: str
    session: str
    model: str = "unknown"
    agent_name: str | None = None
    issue: int | None = None
    pr: int | None = None
    worktree: str | None = None
    branch: str | None = None
    transport: str = "cli"
    context_pct: str | None = None
    quota_pct: str | None = None
    updated_at: str = field(default_factory=lambda: isoformat(utc_now()))
    ttl_seconds: int = DEFAULT_TTL_SECONDS
    pid: int | None = None
    pid_start_ticks: int | None = None
    schema_version: int = SCHEMA_VERSION

    def validate(self) -> "Lease":
        if self.schema_version != SCHEMA_VERSION:
            raise LeaseError(f"lease schema_version must be {SCHEMA_VERSION}")
        if not str(self.harness).strip() or not str(self.session).strip():
            raise LeaseError("lease requires harness and session")
        if not str(self.model).strip():
            raise LeaseError("lease model must not be empty")
        if self.ttl_seconds <= 0:
            raise LeaseError("ttl_seconds must be a positive integer")
        parse_timestamp(self.updated_at)
        for name in ("issue", "pr", "pid", "pid_start_ticks"):
            _optional_int(getattr(self, name), name)
        # Percent counters are stored as normalised decimal strings, never floats.
        return Lease(**{**asdict(self), "harness": str(self.harness).strip(),
                        "session": str(self.session).strip(),
                        "context_pct": decimal_pct(self.context_pct, "context_pct"),
                        "quota_pct": decimal_pct(self.quota_pct, "quota_pct"),
                        "updated_at": isoformat(parse_timestamp(self.updated_at))})

    def age_seconds(self, now: datetime | None = None) -> float:
        return ((now or utc_now()) - parse_timestamp(self.updated_at)).total_seconds()

    def state(self, now: datetime | None = None, stale_factor: int = STALE_FACTOR) -> str:
        age = self.age_seconds(now)
        if age <= self.ttl_seconds:
            return "alive"
        if age <= self.ttl_seconds * stale_factor:
            return "stale"
        return "expired"

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "Lease":
        if not isinstance(data, dict):
            raise LeaseError("lease must be a JSON object")
        known = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
        unknown = set(data) - known
        if unknown:
            raise LeaseError(f"unknown lease fields: {', '.join(sorted(unknown))}")
        try:
            lease = cls(**data)
        except TypeError as exc:
            raise LeaseError(f"invalid lease fields: {exc}") from exc
        # Normalise free-form ids without changing the recorded timestamp.
        return Lease(**{**asdict(lease), "harness": str(lease.harness).strip(),
                        "session": str(lease.session).strip()}).validate()


def default_root(env: dict[str, str] | None = None) -> Path:
    """The main checkout's local state dir, shared by every worktree."""
    env = env if env is not None else os.environ
    if env.get("HARNESS_SESSIONS_DIR"):
        return Path(env["HARNESS_SESSIONS_DIR"])
    import subprocess

    here = Path(__file__).resolve().parents[2]
    done = subprocess.run(["git", "-C", str(here), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                          capture_output=True, text=True, check=False)
    if done.returncode == 0 and done.stdout.strip():
        common = Path(done.stdout.strip())
        return (common.parent if common.name == ".git" else common) / DEFAULT_RELATIVE
    return here / DEFAULT_RELATIVE


def lease_path(root: Path, harness: str, session: str) -> Path:
    return Path(root) / f"{slug(harness)}-{slug(session)}.json"


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink(missing_ok=True)


class LeaseStore:
    """Read/write leases under one directory; ``now`` is injectable for tests."""

    def __init__(self, root: Path | str | None = None, now: Callable[[], datetime] = utc_now):
        self.root = Path(root) if root is not None else default_root()
        self._now = now

    def write(self, lease: Lease) -> Path:
        lease = lease.validate()
        path = lease_path(self.root, lease.harness, lease.session)
        _atomic_write(path, json.dumps(lease.to_dict(), sort_keys=True) + "\n")
        return path

    def heartbeat(self, lease: Lease) -> Path:
        """Refresh ``updated_at`` (and the given counters) of a lease."""
        ticks = lease.pid_start_ticks
        if lease.pid is not None and ticks is None:
            ticks = process_start_ticks(lease.pid)
        return self.write(Lease(**{**asdict(lease), "pid_start_ticks": ticks, "updated_at": isoformat(self._now())}))

    def read(self, path: Path) -> Lease:
        try:
            return Lease.from_dict(json.loads(Path(path).read_text(encoding="utf-8")))
        except (OSError, ValueError) as exc:
            raise LeaseError(f"cannot read lease {path}: {exc}") from exc

    def all(self) -> list[Lease]:
        if not self.root.is_dir():
            return []
        leases = []
        for path in sorted(self.root.glob("*.json")):
            try:
                leases.append(self.read(path))
            except LeaseError:
                continue  # A corrupt lease must not stop the daemon; it is reported by `scan`.
        return leases

    def corrupt(self) -> list[str]:
        if not self.root.is_dir():
            return []
        bad = []
        for path in sorted(self.root.glob("*.json")):
            try:
                self.read(path)
            except LeaseError:
                bad.append(str(path))
        return bad

    def for_session(self, session: str) -> Lease | None:
        """Guardrail lookup: the newest lease with this session id."""
        matches = [lease for lease in self.all() if lease.session == str(session).strip()]
        return max(matches, key=lambda lease: lease.updated_at) if matches else None

    def expired(self, stale_factor: int = STALE_FACTOR) -> list[Lease]:
        now = self._now()
        return [lease for lease in self.all() if lease.state(now, stale_factor) == "expired"]

    def remove(self, lease: Lease) -> bool:
        path = lease_path(self.root, lease.harness, lease.session)
        if path.exists():
            path.unlink()
            return True
        return False


@dataclass(frozen=True)
class T3Lease:
    """An active attempt lease from the durable harness ``runs.sqlite3``."""

    attempt_id: str
    run_id: str
    task_id: str
    expires_epoch: float

    def expired(self, now_epoch: float) -> bool:
        return self.expires_epoch < now_epoch


def t3_leases(db_path: Path | str, now_epoch: float | None = None) -> list[T3Lease]:
    """Read RUNNING attempt leases without writing to the run database.

    The database is opened read-only: the coordinator observes the durable
    harness, it never claims or finishes an attempt on its own.
    """
    path = Path(db_path)
    if not path.is_file():
        return []
    uri = f"file:{path.resolve()}?mode=ro"
    try:
        db = sqlite3.connect(uri, uri=True, timeout=5)
    except sqlite3.Error as exc:
        raise LeaseError(f"cannot read T3 lease database {path}: {exc}") from exc
    try:
        db.row_factory = sqlite3.Row
        rows = db.execute("SELECT id, run_id, task_id, lease FROM attempts WHERE status='RUNNING'").fetchall()
    except sqlite3.Error as exc:
        raise LeaseError(f"cannot read T3 attempt leases: {exc}") from exc
    finally:
        db.close()
    now = now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp()
    return [T3Lease(attempt_id=row["id"], run_id=row["run_id"], task_id=row["task_id"],
                    expires_epoch=float(row["lease"])) for row in rows
            if float(row["lease"]) < now]


def scan(root: Path | str | None, stale_factor: int = STALE_FACTOR,
         now: datetime | None = None) -> dict:
    """One read-only snapshot of the local leases, grouped by state."""
    store = LeaseStore(root, now=(lambda: now) if now else utc_now)
    moment = now or utc_now()
    leases = store.all()
    groups: dict[str, list[dict]] = {state: [] for state in STATES}
    for lease in leases:
        state = lease.state(moment, stale_factor)
        detail = lease.to_dict()
        detail["state"] = state
        groups[state].append(detail)
    return {"schema_version": SCHEMA_VERSION, "checked_at": isoformat(moment),
            "root": str(store.root), "counts": {state: len(items) for state, items in groups.items()},
            "leases": groups, "corrupt": store.corrupt()}


def pct(value: str | None) -> Decimal | None:
    return Decimal(value) if value not in (None, "") else None


def leases_at_or_above(leases: Iterable[Lease], context_pct: str | Decimal | None = None,
                       quota_pct: str | Decimal | None = None) -> list[Lease]:
    """Leases whose recorded context or quota crossed the given soft gates."""
    context_gate = Decimal(str(context_pct)) if context_pct is not None else None
    quota_gate = Decimal(str(quota_pct)) if quota_pct is not None else None
    hits = []
    for lease in leases:
        context = pct(lease.context_pct)
        quota = pct(lease.quota_pct)
        if (context_gate is not None and context is not None and context >= context_gate) or \
                (quota_gate is not None and quota is not None and quota >= quota_gate):
            hits.append(lease)
    return hits
