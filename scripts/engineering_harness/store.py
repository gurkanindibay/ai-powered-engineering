"""Transactional scheduling, conservative budget reservations and append-only audit events."""
from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import sqlite3
import time
import uuid

from .contracts import canonical, digest, redact
from .routing import BusyError, HarnessError, money

TERMINAL = {"READY_FOR_REVIEW", "BLOCKED", "CANCELLED", "TIMED_OUT", "FAILED"}


class Store:
    def __init__(self, directory: Path):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        path = self.directory / "runs.sqlite3"
        if path.is_symlink():
            raise HarnessError("Run database must not be a symlink")
        self.db = sqlite3.connect(path, timeout=30, isolation_level=None)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS runs (
            id TEXT PRIMARY KEY, status TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
            created REAL NOT NULL, deadline REAL NOT NULL, repository TEXT NOT NULL,
            source_revision TEXT NOT NULL, candidate TEXT NOT NULL, policy TEXT NOT NULL,
            plan TEXT NOT NULL, cost TEXT NOT NULL DEFAULT '0', tokens INTEGER NOT NULL DEFAULT 0,
            gate_attempts INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS tasks (
            run_id TEXT NOT NULL REFERENCES runs(id), id TEXT NOT NULL, role TEXT NOT NULL,
            status TEXT NOT NULL, depends TEXT NOT NULL, repairs INTEGER NOT NULL DEFAULT 0,
            result TEXT, PRIMARY KEY(run_id,id));
        CREATE TABLE IF NOT EXISTS attempts (
            id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT NOT NULL,
            status TEXT NOT NULL, lease REAL NOT NULL, envelope TEXT NOT NULL,
            reservation TEXT NOT NULL, tokens INTEGER NOT NULL, result_hash TEXT,
            result TEXT, FOREIGN KEY(run_id,task_id) REFERENCES tasks(run_id,id));
        CREATE TABLE IF NOT EXISTS events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL REFERENCES runs(id),
            created REAL NOT NULL, body TEXT NOT NULL, previous TEXT NOT NULL, hash TEXT NOT NULL);
        CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
          BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
        CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
          BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
        """)

    def close(self):
        self.db.close()

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        else:
            self.db.execute("COMMIT")

    def event(self, run_id: str, kind: str, **details):
        previous = self.db.execute("SELECT hash FROM events WHERE run_id=? ORDER BY seq DESC LIMIT 1", (run_id,)).fetchone()
        previous = previous[0] if previous else ""
        body = json.loads(redact(canonical({"kind": kind, **details})))
        created = time.time()
        event_hash = digest({"run_id": run_id, "created": created, "previous": previous, "body": body})
        self.db.execute("INSERT INTO events(run_id,created,body,previous,hash) VALUES(?,?,?,?,?)",
                        (run_id, created, canonical(body), previous, event_hash))

    def create(self, repository: str, source_revision: str, candidate: str, policy: dict, plan: dict, run_id: str | None = None) -> str:
        run_id = run_id or uuid.uuid4().hex
        now = time.time()
        with self.transaction():
            self.db.execute("INSERT INTO runs(id,status,created,deadline,repository,source_revision,candidate,policy,plan) VALUES(?,?,?,?,?,?,?,?,?)",
                            (run_id, "QUEUED", now, now + policy["limits"]["seconds"], repository, source_revision, candidate, canonical(policy), canonical(plan)))
            for stage in plan["stages"]:
                self.db.execute("INSERT INTO tasks(run_id,id,role,status,depends) VALUES(?,?,?,?,?)",
                                (run_id, stage["id"], stage["role"], "PENDING", canonical(stage["depends_on"])))
            self.event(run_id, "created", source_revision=source_revision, candidate=candidate,
                       policy_hash=digest(policy), plan_hash=digest(plan))
        return run_id

    def run(self, run_id: str) -> dict:
        row = self.db.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
        if row is None:
            raise HarnessError("Unknown run")
        value = dict(row)
        for field in ("policy", "plan"):
            value[field] = json.loads(value[field])
        return value

    def tasks(self, run_id: str) -> list[dict]:
        self.run(run_id)
        return [dict(row) for row in self.db.execute("SELECT * FROM tasks WHERE run_id=? ORDER BY id", (run_id,))]

    def attempt(self, attempt_id: str) -> dict:
        row = self.db.execute("SELECT * FROM attempts WHERE id=?", (attempt_id,)).fetchone()
        if row is None:
            raise HarnessError("Unknown attempt")
        value = dict(row)
        value["envelope"] = json.loads(value["envelope"])
        return value

    def active(self, run_id: str) -> list[dict]:
        return [self.attempt(row[0]) for row in self.db.execute("SELECT id FROM attempts WHERE run_id=? AND status='RUNNING'", (run_id,))]

    def claim(self, run_id: str, envelope: dict, reserve: str, token_limit: int) -> dict:
        with self.transaction():
            run = self.run(run_id)
            if run["status"] in TERMINAL:
                raise HarnessError(f"Run is {run['status']}")
            if self.active(run_id):
                raise BusyError("Run has a live attempt; reconcile before redispatch")
            if time.time() >= run["deadline"]:
                raise HarnessError("Run wall-clock budget exhausted")
            limits = run["policy"]["limits"]
            if money(run["cost"]) + money(reserve) > money(limits["cost"]) or run["tokens"] + token_limit > limits["tokens"]:
                raise HarnessError("Run cost/token budget exhausted before dispatch")
            task_id = envelope["task_id"]
            tasks = {task["id"]: task for task in self.tasks(run_id)}
            task = tasks.get(task_id)
            if task is None or task["status"] not in ("PENDING", "REPAIRING"):
                raise BusyError("Task is not runnable")
            if any(tasks[d]["status"] != "COMPLETED" for d in json.loads(task["depends"])):
                raise HarnessError("Task dependencies are not complete")
            if envelope["candidate"] != run["candidate"]:
                raise HarnessError("Candidate changed before claim")
            self.db.execute("INSERT INTO attempts VALUES(?,?,?,?,?,?,?,?,?,?)",
                            (envelope["attempt_id"], run_id, task_id, "RUNNING", time.time() + limits["attempt_seconds"] + 30,
                             canonical(envelope), str(money(reserve)), token_limit, None, None))
            # Reservations are charged up front. Unknown usage never silently refunds them.
            self.db.execute("UPDATE runs SET status='RUNNING',revision=revision+1,cost=?,tokens=tokens+? WHERE id=?",
                            (str(money(run["cost"]) + money(reserve)), token_limit, run_id))
            self.db.execute("UPDATE tasks SET status='RUNNING' WHERE run_id=? AND id=?", (run_id, task_id))
            self.event(run_id, "claimed", attempt_id=envelope["attempt_id"], task_id=task_id,
                       input_hash=digest(envelope), reserved_cost=reserve, reserved_tokens=token_limit)
        return self.attempt(envelope["attempt_id"])

    def heartbeat(self, attempt_id: str):
        with self.transaction():
            attempt = self.attempt(attempt_id)
            run = self.run(attempt["run_id"])
            if attempt["status"] != "RUNNING" or run["status"] in TERMINAL:
                raise HarnessError("Cannot heartbeat an inactive attempt")
            self.db.execute("UPDATE attempts SET lease=? WHERE id=?", (time.time() + run["policy"]["limits"]["attempt_seconds"] + 30, attempt_id))

    def finish(self, attempt_id: str, result: dict, candidate: str, cost: str, tokens: int) -> bool:
        """Idempotent completion; duplicate callbacks cannot refund or integrate twice."""
        result_hash = digest(result)
        with self.transaction():
            attempt = self.attempt(attempt_id)
            run = self.run(attempt["run_id"])
            if attempt["result_hash"] == result_hash:
                return False
            if attempt["status"] != "RUNNING" or run["status"] in TERMINAL:
                raise HarnessError("Attempt is inactive or has a conflicting completion")
            if attempt["lease"] < time.time() or run["deadline"] < time.time():
                raise HarnessError("Late completion requires reconciliation")
            if run["candidate"] != attempt["envelope"]["candidate"]:
                raise HarnessError("Attempt was verified against a stale candidate")
            usage_overrun = tokens > attempt["tokens"] or money(cost) > money(attempt["reservation"])
            status = result["status"]
            task_status = "COMPLETED" if status == "completed" and not usage_overrun else "BLOCKED"
            task = next(t for t in self.tasks(run["id"]) if t["id"] == attempt["task_id"])
            repairs = task["repairs"]
            if status == "code_defect" and not usage_overrun and repairs < run["policy"]["limits"]["max_repairs"]:
                task_status = "REPAIRING"
                repairs += 1
            new_cost = money(run["cost"]) - money(attempt["reservation"]) + money(cost)
            self.db.execute("UPDATE attempts SET status=?, result_hash=?,result=? WHERE id=?",
                            ("COMPLETED", result_hash, canonical(result), attempt_id))
            self.db.execute("UPDATE tasks SET status=?,repairs=?,result=? WHERE run_id=? AND id=?",
                            (task_status, repairs, canonical(result), run["id"], task["id"]))
            new_state = "BLOCKED" if task_status == "BLOCKED" else ("REPAIRING" if task_status == "REPAIRING" else "QUEUED")
            self.db.execute("UPDATE runs SET status=?,revision=revision+1,candidate=?,cost=?,tokens=tokens-?+? WHERE id=?",
                            (new_state, candidate, str(new_cost), attempt["tokens"], tokens, run["id"]))
            self.event(run["id"], "completed", attempt_id=attempt_id, result_hash=result_hash,
                       status=task_status, candidate=candidate, usage_overrun=usage_overrun, actual_cost=cost, actual_tokens=tokens)
        return True

    def stop(self, run_id: str, status: str, reason: str):
        if status not in {"BLOCKED", "CANCELLED", "TIMED_OUT", "FAILED"}:
            raise HarnessError("Invalid stop status")
        with self.transaction():
            run = self.run(run_id)
            if run["status"] in TERMINAL:
                return
            self.db.execute("UPDATE runs SET status=?,revision=revision+1 WHERE id=?", (status, run_id))
            self.db.execute("UPDATE tasks SET status=? WHERE run_id=? AND status!='COMPLETED'", (status, run_id))
            self.db.execute("UPDATE attempts SET status=? WHERE run_id=? AND status='RUNNING'", (status, run_id))
            self.event(run_id, "stopped", status=status, reason=reason)

    def begin_verification(self, run_id: str) -> dict:
        with self.transaction():
            run = self.run(run_id)
            if run["status"] in TERMINAL or self.active(run_id):
                raise HarnessError("Run cannot enter verification")
            if any(t["status"] != "COMPLETED" for t in self.tasks(run_id)):
                raise HarnessError("All agent stages must complete before verification")
            if run["deadline"] <= time.time():
                raise HarnessError("Run wall-clock budget exhausted")
            if run["status"] == "VERIFYING":
                raise HarnessError("Verification already active; reconcile its interrupted execution")
            self.db.execute("UPDATE runs SET status='VERIFYING',revision=revision+1,gate_attempts=gate_attempts+1 WHERE id=?", (run_id,))
            self.event(run_id, "verification_started", candidate=run["candidate"], attempt=run["gate_attempts"] + 1)
        return self.run(run_id)

    def verified(self, run_id: str, candidate: str, evidence_hash: str, passed: bool, diagnostics: list | None = None, repair_role: str | None = None):
        with self.transaction():
            run = self.run(run_id)
            if run["status"] != "VERIFYING" or candidate != run["candidate"]:
                raise HarnessError("Verification is cancelled or candidate evidence is stale")
            status = "READY_FOR_REVIEW" if passed and run["deadline"] > time.time() else "BLOCKED"
            if not passed and run["deadline"] > time.time():
                tasks = self.tasks(run_id)
                makers = [t for t in tasks if t["role"] in ("developer", "backend_developer", "frontend_developer")]
                maker = next((t for t in makers if t["role"] == repair_role), makers[-1])
                if maker["repairs"] < run["policy"]["limits"]["max_repairs"]:
                    failure = {"status": "code_defect", "verification_evidence": evidence_hash,
                               "summary": "Required verification failed. Inspect the supplied gate diagnostics.",
                               "diagnostics": diagnostics or []}
                    self.db.execute("UPDATE tasks SET status='REPAIRING',repairs=repairs+1,result=? WHERE run_id=? AND id=?",
                                    (canonical(failure), run_id, maker["id"]))
                    for task in tasks[tasks.index(maker) + 1:]:
                        self.db.execute("UPDATE tasks SET status='PENDING',result=NULL WHERE run_id=? AND id=?", (run_id, task["id"]))
                    status = "REPAIRING"
            self.db.execute("UPDATE runs SET status=?,revision=revision+1 WHERE id=?", (status, run_id))
            self.event(run_id, "verification_finished", status=status, candidate=candidate, evidence_hash=evidence_hash)

    def events(self, run_id: str) -> list[dict]:
        self.run(run_id)
        return [dict(r) for r in self.db.execute("SELECT * FROM events WHERE run_id=? ORDER BY seq", (run_id,))]

    def audit(self, run_id: str) -> bool:
        previous = ""
        for event in self.events(run_id):
            expected = digest({"run_id": run_id, "created": event["created"], "previous": previous, "body": json.loads(event["body"])})
            if event["previous"] != previous or event["hash"] != expected:
                return False
            body = json.loads(event["body"])
            if body.get("kind") == "evidence":
                name = body["artifact"]
                if not isinstance(name, str) or "/" in name or "\\" in name:
                    return False
                path = self.directory / "evidence" / run_id / f"{name}.json"
                try:
                    if path.is_symlink() or digest(json.loads(path.read_text())) != body["content_hash"]:
                        return False
                except (OSError, ValueError):
                    return False
            previous = expected
        return True
