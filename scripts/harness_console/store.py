"""Append-only SQLite WAL command queue and control state for Phase 5.

Every operator intervention (pause, resume, kill, steer, handover, pin,
takeover, set-budget, mark-status, set-gate, approve, dispatch) is recorded
in ``operator_commands`` with a SHA-256 hash chain and protected against
UPDATE/DELETE via SQLite triggers. Materialized control tables (``pauses``,
``pins``, ``steering_notes``, ``budget_overrides``, ``approval_gates``,
``approvals``, and ``command_acks``) allow both the Control Console and the
0-token Coordinator Daemon to query effective overrides in O(1) without
mutating command history.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
from typing import Any, Iterator
import uuid

from scripts.engineering_harness.contracts import canonical, redact
from scripts.token_tracker.quotas import decimal_str, money

SCHEMA_VERSION = 1
DEFAULT_DB_RELATIVE = Path(".agents") / "local" / "harness_console.sqlite3"

COMMAND_TYPES = (
    "dispatch",
    "pause",
    "resume",
    "kill",
    "steer",
    "handover",
    "pin",
    "unpin",
    "takeover",
    "set_budget",
    "mark_status",
    "set_gate",
    "approve",
)
TARGET_TYPES = ("all", "issue", "run", "provider", "tier", "command", "task")
TRANSPORTS = ("cli", "web", "mcp", "coordinator")
ACK_STATUSES = ("applied", "deferred", "failed")


class ConsoleError(ValueError):
    """Configuration, validation, or operator command error."""


def find_main_checkout() -> Path:
    """Resolve the shared main git checkout so all worktrees share local state."""
    repo_root = Path(__file__).resolve().parents[2]
    done = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True,
        text=True,
        check=False,
    )
    if done.returncode == 0 and done.stdout.strip():
        git_dir = Path(done.stdout.strip())
        return git_dir.parent if git_dir.name == ".git" else git_dir
    return repo_root


def default_local_root(env: dict[str, str] | None = None) -> Path:
    lookup = os.environ if env is None else env
    if lookup.get("HARNESS_LOCAL_ROOT"):
        return Path(lookup["HARNESS_LOCAL_ROOT"]).resolve()
    return find_main_checkout() / ".agents" / "local"


def default_console_db_path(env: dict[str, str] | None = None) -> Path:
    lookup = os.environ if env is None else env
    if lookup.get("HARNESS_CONSOLE_DB"):
        return Path(lookup["HARNESS_CONSOLE_DB"]).resolve()
    return default_local_root(lookup) / "harness_console.sqlite3"


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def normalize_budget_provider(provider: str) -> str:
    """Normalize provider aliases such as copilot-deepseek to canonical 'copilot'."""
    norm = str(provider or "").strip().lower().replace("_", "-")
    if norm in ("copilot", "copilot-deepseek", "deepseek", "copilot-cli"):
        return "copilot"
    if not norm:
        raise ConsoleError("provider must not be empty")
    return norm


def scope_key(target_type: str, target_id: str | int | None) -> str:
    if target_type == "all":
        return "all"
    if target_id is None or str(target_id).strip() == "":
        raise ConsoleError(f"target_id is required for target_type={target_type}")
    return f"{target_type}:{str(target_id).strip()}"


def _command_hash(
    *,
    command_id: str,
    created_at: str,
    actor: str,
    transport: str,
    command: str,
    target_type: str,
    target_id: str | None,
    payload_json: str,
    prev_hash: str,
) -> str:
    body = canonical(
        {
            "command_id": command_id,
            "created_at": created_at,
            "actor": actor,
            "transport": transport,
            "command": command,
            "target_type": target_type,
            "target_id": target_id,
            "payload": json.loads(payload_json),
            "prev_hash": prev_hash,
        }
    )
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


class ConsoleStore:
    """SQLite WAL store for the append-only operator command queue and active controls."""

    def __init__(self, db_path: Path | str | None = None) -> None:
        self.path = Path(db_path or default_console_db_path()).resolve()
        if self.path.is_symlink():
            raise ConsoleError("Console database must not be a symlink")
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        ignore = self.path.parent / ".gitignore"
        if self.path.parent.name == "local" and not ignore.exists():
            ignore.write_text("*\n", encoding="utf-8")

        self.db = sqlite3.connect(str(self.path), timeout=30.0, isolation_level=None, check_same_thread=False)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self._init_schema()

    def _init_schema(self) -> None:
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS operator_commands (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                command_id    TEXT NOT NULL UNIQUE,
                created_at    TEXT NOT NULL,
                actor         TEXT NOT NULL,
                transport     TEXT NOT NULL,
                command       TEXT NOT NULL,
                target_type   TEXT NOT NULL,
                target_id     TEXT,
                payload_json  TEXT NOT NULL,
                prev_hash     TEXT NOT NULL,
                hash          TEXT NOT NULL
            );

            CREATE TRIGGER IF NOT EXISTS operator_commands_no_update
            BEFORE UPDATE ON operator_commands
            BEGIN
                SELECT RAISE(ABORT, 'operator_commands is append-only');
            END;

            CREATE TRIGGER IF NOT EXISTS operator_commands_no_delete
            BEFORE DELETE ON operator_commands
            BEGIN
                SELECT RAISE(ABORT, 'operator_commands is append-only');
            END;

            CREATE TABLE IF NOT EXISTS command_acks (
                command_id       TEXT PRIMARY KEY REFERENCES operator_commands(command_id),
                acknowledged_at  TEXT NOT NULL,
                executor         TEXT NOT NULL,
                status           TEXT NOT NULL,
                result_json      TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS pauses (
                scope_key    TEXT PRIMARY KEY,
                target_type  TEXT NOT NULL,
                target_id    TEXT,
                reason       TEXT NOT NULL,
                actor        TEXT NOT NULL,
                paused_at    TEXT NOT NULL,
                command_id   TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS pins (
                scope_key    TEXT PRIMARY KEY,
                target_type  TEXT NOT NULL,
                target_id    TEXT NOT NULL,
                provider     TEXT NOT NULL,
                model        TEXT,
                transport    TEXT,
                actor        TEXT NOT NULL,
                pinned_at    TEXT NOT NULL,
                command_id   TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS steering_notes (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                target_type  TEXT NOT NULL,
                target_id    TEXT NOT NULL,
                note         TEXT NOT NULL,
                actor        TEXT NOT NULL,
                created_at   TEXT NOT NULL,
                command_id   TEXT NOT NULL,
                consumed_at  TEXT
            );

            CREATE TABLE IF NOT EXISTS budget_overrides (
                provider     TEXT PRIMARY KEY,
                budget_usd   TEXT NOT NULL,
                actor        TEXT NOT NULL,
                updated_at   TEXT NOT NULL,
                command_id   TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS approval_gates (
                tier              TEXT PRIMARY KEY,
                require_approval  INTEGER NOT NULL,
                actor             TEXT NOT NULL,
                updated_at        TEXT NOT NULL,
                command_id        TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS approvals (
                scope_key    TEXT PRIMARY KEY,
                target_type  TEXT NOT NULL,
                target_id    TEXT NOT NULL,
                actor        TEXT NOT NULL,
                approved_at  TEXT NOT NULL,
                command_id   TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_cmd_created ON operator_commands(id DESC);
            CREATE INDEX IF NOT EXISTS idx_cmd_target ON operator_commands(target_type, target_id);
            CREATE INDEX IF NOT EXISTS idx_steer_target ON steering_notes(target_type, target_id, consumed_at);
            """
        )

    def close(self) -> None:
        if getattr(self, "db", None) is not None:
            self.db.close()
            self.db = None  # type: ignore[assignment]

    @contextmanager
    def transaction(self) -> Iterator[None]:
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        else:
            self.db.execute("COMMIT")

    def enqueue(
        self,
        *,
        command: str,
        target_type: str,
        target_id: str | int | None = None,
        payload: dict[str, Any] | None = None,
        actor: str = "operator",
        transport: str = "cli",
        created_at: str | None = None,
    ) -> dict[str, Any]:
        """Append one operator command and update materialized control state atomically."""
        if command not in COMMAND_TYPES:
            raise ConsoleError(f"unsupported command: {command}")
        if target_type not in TARGET_TYPES:
            raise ConsoleError(f"unsupported target_type: {target_type}")
        if transport not in TRANSPORTS:
            raise ConsoleError(f"unsupported transport: {transport}")

        norm_target_id = None if target_id is None else str(target_id).strip()
        if target_type != "all" and not norm_target_id:
            raise ConsoleError(f"target_id is required when target_type={target_type}")
        norm_actor = str(actor or "operator").strip() or "operator"
        timestamp = created_at or utc_now_iso()
        command_id = f"cmd-{uuid.uuid4().hex[:16]}"
        sanitized_payload = json.loads(redact(canonical(payload or {})))
        payload_json = canonical(sanitized_payload)

        with self.transaction():
            row = self.db.execute("SELECT hash FROM operator_commands ORDER BY id DESC LIMIT 1").fetchone()
            prev_hash = row["hash"] if row else ""
            digest_hex = _command_hash(
                command_id=command_id,
                created_at=timestamp,
                actor=norm_actor,
                transport=transport,
                command=command,
                target_type=target_type,
                target_id=norm_target_id,
                payload_json=payload_json,
                prev_hash=prev_hash,
            )
            self.db.execute(
                """
                INSERT INTO operator_commands (
                    command_id, created_at, actor, transport, command,
                    target_type, target_id, payload_json, prev_hash, hash
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    command_id,
                    timestamp,
                    norm_actor,
                    transport,
                    command,
                    target_type,
                    norm_target_id,
                    payload_json,
                    prev_hash,
                    digest_hex,
                ),
            )
            self._apply_materialized(
                command_id=command_id,
                timestamp=timestamp,
                actor=norm_actor,
                command=command,
                target_type=target_type,
                target_id=norm_target_id,
                payload=sanitized_payload,
            )

        return {
            "command_id": command_id,
            "created_at": timestamp,
            "actor": norm_actor,
            "transport": transport,
            "command": command,
            "target_type": target_type,
            "target_id": norm_target_id,
            "payload": sanitized_payload,
            "prev_hash": prev_hash,
            "hash": digest_hex,
        }

    def _apply_materialized(
        self,
        *,
        command_id: str,
        timestamp: str,
        actor: str,
        command: str,
        target_type: str,
        target_id: str | None,
        payload: dict[str, Any],
    ) -> None:
        if command in ("pause", "takeover"):
            skey = scope_key(target_type, target_id)
            reason = str(payload.get("reason") or ("operator_takeover" if command == "takeover" else "operator_pause"))
            self.db.execute(
                """
                INSERT INTO pauses (scope_key, target_type, target_id, reason, actor, paused_at, command_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(scope_key) DO UPDATE SET
                    reason=excluded.reason,
                    actor=excluded.actor,
                    paused_at=excluded.paused_at,
                    command_id=excluded.command_id
                """,
                (skey, target_type, target_id, reason, actor, timestamp, command_id),
            )
        elif command == "resume":
            skey = scope_key(target_type, target_id)
            self.db.execute("DELETE FROM pauses WHERE scope_key=?", (skey,))
        elif command in ("pin", "handover"):
            to_target = str(payload.get("to") or "").strip()
            if to_target and target_type in ("issue", "run"):
                skey = scope_key(target_type, target_id)
                self.db.execute(
                    """
                    INSERT INTO pins (scope_key, target_type, target_id, provider, model, transport, actor, pinned_at, command_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(scope_key) DO UPDATE SET
                        provider=excluded.provider,
                        model=excluded.model,
                        transport=excluded.transport,
                        actor=excluded.actor,
                        pinned_at=excluded.pinned_at,
                        command_id=excluded.command_id
                    """,
                    (
                        skey,
                        target_type,
                        str(target_id),
                        to_target,
                        payload.get("model"),
                        payload.get("transport"),
                        actor,
                        timestamp,
                        command_id,
                    ),
                )
        elif command == "unpin":
            skey = scope_key(target_type, target_id)
            self.db.execute("DELETE FROM pins WHERE scope_key=?", (skey,))
        elif command == "steer":
            note = str(payload.get("note") or "").strip()
            if not note:
                raise ConsoleError("steer requires a non-empty note")
            self.db.execute(
                """
                INSERT INTO steering_notes (target_type, target_id, note, actor, created_at, command_id, consumed_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """,
                (target_type, str(target_id), note, actor, timestamp, command_id),
            )
        elif command == "set_budget":
            provider = normalize_budget_provider(str(target_id or payload.get("provider") or ""))
            usd_str = decimal_str(money(payload.get("usd")), places=2)
            self.db.execute(
                """
                INSERT INTO budget_overrides (provider, budget_usd, actor, updated_at, command_id)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(provider) DO UPDATE SET
                    budget_usd=excluded.budget_usd,
                    actor=excluded.actor,
                    updated_at=excluded.updated_at,
                    command_id=excluded.command_id
                """,
                (provider, usd_str, actor, timestamp, command_id),
            )
        elif command == "set_gate":
            tier = str(target_id or payload.get("tier") or "").strip().lower()
            if not tier:
                raise ConsoleError("set_gate requires a tier")
            req = 1 if bool(payload.get("require_approval", True)) else 0
            self.db.execute(
                """
                INSERT INTO approval_gates (tier, require_approval, actor, updated_at, command_id)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(tier) DO UPDATE SET
                    require_approval=excluded.require_approval,
                    actor=excluded.actor,
                    updated_at=excluded.updated_at,
                    command_id=excluded.command_id
                """,
                (tier, req, actor, timestamp, command_id),
            )
        elif command == "approve":
            skey = scope_key(target_type, target_id)
            self.db.execute(
                """
                INSERT INTO approvals (scope_key, target_type, target_id, actor, approved_at, command_id)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(scope_key) DO UPDATE SET
                    actor=excluded.actor,
                    approved_at=excluded.approved_at,
                    command_id=excluded.command_id
                """,
                (skey, target_type, str(target_id), actor, timestamp, command_id),
            )

    def acknowledge(
        self,
        command_id: str,
        *,
        status: str = "applied",
        result: dict[str, Any] | None = None,
        executor: str = "coordinator",
    ) -> dict[str, Any]:
        if status not in ACK_STATUSES:
            raise ConsoleError(f"ack status must be one of {', '.join(ACK_STATUSES)}")
        now_iso = utc_now_iso()
        sanitized = json.loads(redact(canonical(result or {})))
        result_json = canonical(sanitized)
        with self.transaction():
            exists = self.db.execute(
                "SELECT 1 FROM operator_commands WHERE command_id=?", (command_id,)
            ).fetchone()
            if exists is None:
                raise ConsoleError(f"unknown command_id: {command_id}")
            self.db.execute(
                """
                INSERT INTO command_acks (command_id, acknowledged_at, executor, status, result_json)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(command_id) DO UPDATE SET
                    acknowledged_at=excluded.acknowledged_at,
                    executor=excluded.executor,
                    status=excluded.status,
                    result_json=excluded.result_json
                """,
                (command_id, now_iso, executor, status, result_json),
            )
        return {
            "command_id": command_id,
            "acknowledged_at": now_iso,
            "executor": executor,
            "status": status,
            "result": sanitized,
        }

    def list_commands(
        self,
        *,
        limit: int = 50,
        unacked_only: bool = False,
        target_type: str | None = None,
        target_id: str | int | None = None,
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if unacked_only:
            clauses.append("a.command_id IS NULL")
        if target_type is not None:
            clauses.append("c.target_type = ?")
            params.append(target_type)
        if target_id is not None:
            clauses.append("c.target_id = ?")
            params.append(str(target_id))
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        sql = f"""
            SELECT c.*, a.acknowledged_at, a.executor, a.status AS ack_status, a.result_json
            FROM operator_commands c
            LEFT JOIN command_acks a ON a.command_id = c.command_id
            {where}
            ORDER BY c.id DESC
            LIMIT ?
        """
        params.append(max(1, min(int(limit), 500)))
        rows = self.db.execute(sql, params).fetchall()
        out = []
        for row in rows:
            out.append(
                {
                    "id": row["id"],
                    "command_id": row["command_id"],
                    "created_at": row["created_at"],
                    "actor": row["actor"],
                    "transport": row["transport"],
                    "command": row["command"],
                    "target_type": row["target_type"],
                    "target_id": row["target_id"],
                    "payload": json.loads(row["payload_json"]),
                    "prev_hash": row["prev_hash"],
                    "hash": row["hash"],
                    "ack": None
                    if row["ack_status"] is None
                    else {
                        "acknowledged_at": row["acknowledged_at"],
                        "executor": row["executor"],
                        "status": row["ack_status"],
                        "result": json.loads(row["result_json"]),
                    },
                }
            )
        return out

    def audit_chain(self) -> bool:
        """Verify the SHA-256 hash chain over operator_commands."""
        rows = self.db.execute("SELECT * FROM operator_commands ORDER BY id ASC").fetchall()
        previous = ""
        for row in rows:
            expected = _command_hash(
                command_id=row["command_id"],
                created_at=row["created_at"],
                actor=row["actor"],
                transport=row["transport"],
                command=row["command"],
                target_type=row["target_type"],
                target_id=row["target_id"],
                payload_json=row["payload_json"],
                prev_hash=previous,
            )
            if row["prev_hash"] != previous or row["hash"] != expected:
                return False
            previous = row["hash"]
        return True

    def is_paused(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        provider: str | None = None,
    ) -> dict[str, Any] | None:
        keys = ["all"]
        if issue is not None:
            keys.append(f"issue:{issue}")
        if run_id:
            keys.append(f"run:{run_id}")
        if provider:
            keys.append(f"provider:{provider.strip().lower()}")
        placeholders = ",".join("?" for _ in keys)
        row = self.db.execute(
            f"SELECT * FROM pauses WHERE scope_key IN ({placeholders}) ORDER BY paused_at DESC LIMIT 1",
            keys,
        ).fetchone()
        return dict(row) if row else None

    def get_pin(self, *, issue: int | None = None, run_id: str | None = None) -> dict[str, Any] | None:
        keys: list[str] = []
        if issue is not None:
            keys.append(f"issue:{issue}")
        if run_id:
            keys.append(f"run:{run_id}")
        if not keys:
            return None
        placeholders = ",".join("?" for _ in keys)
        row = self.db.execute(
            f"SELECT * FROM pins WHERE scope_key IN ({placeholders}) ORDER BY pinned_at DESC LIMIT 1",
            keys,
        ).fetchone()
        return dict(row) if row else None

    def pending_steering(self, *, issue: int | None = None, run_id: str | None = None) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if issue is not None:
            clauses.append("(target_type='issue' AND target_id=?)")
            params.append(str(issue))
        if run_id:
            clauses.append("(target_type='run' AND target_id=?)")
            params.append(str(run_id))
        if not clauses:
            return []
        rows = self.db.execute(
            f"SELECT * FROM steering_notes WHERE consumed_at IS NULL AND ({' OR '.join(clauses)}) ORDER BY id ASC",
            params,
        ).fetchall()
        return [dict(r) for r in rows]

    def mark_steering_consumed(self, note_ids: list[int]) -> int:
        if not note_ids:
            return 0
        now_iso = utc_now_iso()
        placeholders = ",".join("?" for _ in note_ids)
        with self.transaction():
            cur = self.db.execute(
                f"UPDATE steering_notes SET consumed_at=? WHERE id IN ({placeholders}) AND consumed_at IS NULL",
                [now_iso, *note_ids],
            )
            return int(cur.rowcount or 0)

    def get_budget_override(self, provider: str) -> Decimal | None:
        norm = normalize_budget_provider(provider)
        row = self.db.execute(
            "SELECT budget_usd FROM budget_overrides WHERE provider=?", (norm,)
        ).fetchone()
        return money(row["budget_usd"]) if row else None

    def gate_requires_approval(self, tier: str) -> bool:
        row = self.db.execute(
            "SELECT require_approval FROM approval_gates WHERE tier=?",
            (str(tier).strip().lower(),),
        ).fetchone()
        return bool(row and row["require_approval"])

    def is_approved(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        handover_id: str | None = None,
    ) -> bool:
        keys: list[str] = []
        if issue is not None:
            keys.append(f"issue:{issue}")
        if run_id:
            keys.append(f"run:{run_id}")
        if handover_id:
            keys.append(f"task:{handover_id}")
        if not keys:
            return False
        placeholders = ",".join("?" for _ in keys)
        row = self.db.execute(
            f"SELECT 1 FROM approvals WHERE scope_key IN ({placeholders}) LIMIT 1", keys
        ).fetchone()
        return row is not None

    def state_snapshot(self) -> dict[str, Any]:
        pauses = [dict(r) for r in self.db.execute("SELECT * FROM pauses ORDER BY paused_at DESC").fetchall()]
        pins = [dict(r) for r in self.db.execute("SELECT * FROM pins ORDER BY pinned_at DESC").fetchall()]
        steering = [
            dict(r)
            for r in self.db.execute(
                "SELECT * FROM steering_notes WHERE consumed_at IS NULL ORDER BY id ASC"
            ).fetchall()
        ]
        budgets = [
            dict(r) for r in self.db.execute("SELECT * FROM budget_overrides ORDER BY provider ASC").fetchall()
        ]
        gates = [
            {**dict(r), "require_approval": bool(r["require_approval"])}
            for r in self.db.execute("SELECT * FROM approval_gates ORDER BY tier ASC").fetchall()
        ]
        approvals = [
            dict(r) for r in self.db.execute("SELECT * FROM approvals ORDER BY approved_at DESC").fetchall()
        ]
        return {
            "schema_version": SCHEMA_VERSION,
            "db_path": str(self.path),
            "pauses": pauses,
            "pins": pins,
            "pending_steering": steering,
            "budget_overrides": budgets,
            "approval_gates": gates,
            "approvals": approvals,
        }
