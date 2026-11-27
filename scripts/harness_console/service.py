"""Unified Control Console service shared by Web UI, CLI, and MCP Adapter."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import time
from typing import Any, Callable

from scripts import handover as handover_tool
from scripts.engineering_harness import leases, routing, t3
from scripts.engineering_harness.contracts import redact
from scripts.engineering_harness.engine import Engine
from scripts.engineering_harness.store import Store as RunsStore
from scripts.token_tracker.ledger import TokenLedger
from scripts.token_tracker.quotas import QuotaConfig, decimal_str, money

from .queries import ConsoleQueryMixin, read_json_safe
from .store import (
    ConsoleError,
    ConsoleStore,
    default_console_db_path,
    default_local_root,
    find_main_checkout,
    normalize_budget_provider,
)

DEFAULT_QUOTAS_PATH = Path(__file__).resolve().parents[2] / "config" / "provider-quotas.json"
DEFAULT_REGISTRY_PATH = t3.DEFAULT_REGISTRY
DEFAULT_LAUNCHERS_PATH = Path(__file__).resolve().parents[2] / "config" / "engineering-harness" / "launchers.json"
DEFAULT_KILL_WAIT_SECONDS = 5.0


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
        rparen = raw.rfind(")")
        if rparen != -1:
            fields = raw[rparen + 2 :].split()
            if fields and fields[0] in ("Z", "X"):
                return False
    except OSError:
        pass
    return True


def _verify_and_kill_lease(lease: dict[str, Any], *, wait_seconds: float = DEFAULT_KILL_WAIT_SECONDS) -> dict[str, Any]:
    """Signal a lease PID only when fresh AND process identity is verified.

    Waits up to ``wait_seconds`` for exit so a subsequent WIP capture never
    races a live worker holding ``index.lock`` or writing files.
    """
    pid = lease["pid"]
    state = lease.get("state")
    if state != "alive":
        return {"attempted": False, "pid": pid, "not_signalled": "lease_expired", "lease_state": state}

    if pid <= 1 or pid == os.getpid():
        return {"attempted": False, "pid": pid, "not_signalled": "unsafe_pid"}

    if not _pid_alive(pid):
        return {"attempted": False, "pid": pid, "not_signalled": "not_running"}

    recorded_ticks = lease.get("pid_start_ticks")
    ticks_matched = False
    if recorded_ticks is not None:
        live_ticks = leases.process_start_ticks(pid)
        if live_ticks is None or live_ticks != recorded_ticks:
            return {"attempted": False, "pid": pid, "not_signalled": "pid_mismatch"}
        ticks_matched = True

    worktree = lease.get("worktree")
    cwd_matched = False
    if worktree:
        live_cwd = leases.process_cwd(pid)
        if live_cwd is not None:
            if not live_cwd.is_relative_to(Path(worktree).resolve()):
                return {"attempted": False, "pid": pid, "not_signalled": "cwd_outside_worktree"}
            cwd_matched = True

    if not ticks_matched and not cwd_matched:
        return {"attempted": False, "pid": pid, "not_signalled": "identity_unverified"}

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return {"attempted": False, "pid": pid, "not_signalled": "not_running"}
    except PermissionError:
        return {"attempted": False, "pid": pid, "not_signalled": "permission_denied"}
    except OSError as exc:
        return {"attempted": False, "pid": pid, "error": str(exc)}

    deadline = time.monotonic() + max(0.0, float(wait_seconds))
    exited = not _pid_alive(pid)
    while not exited and time.monotonic() < deadline:
        time.sleep(0.05)
        exited = not _pid_alive(pid)

    return {"attempted": True, "pid": pid, "signal": "SIGTERM", "exited": exited}


class ConsoleService(ConsoleQueryMixin):
    """Unified observability and operator control facade for Phase 5."""

    def __init__(
        self,
        *,
        local_root: Path | str | None = None,
        repo_root: Path | str | None = None,
        console_db: Path | str | None = None,
        ledger_db: Path | str | None = None,
        runs_db: Path | str | None = None,
        sessions_dir: Path | str | None = None,
        handovers_dir: Path | str | None = None,
        agent_names_path: Path | str | None = None,
        quotas_path: Path | str | None = None,
        registry_path: Path | str | None = None,
        launchers_path: Path | str | None = None,
        t3_catalog_path: Path | str | None = None,
        offline: bool = False,
        gh_runner: Callable[[list[str]], str] | None = None,
        kill_wait_seconds: float = DEFAULT_KILL_WAIT_SECONDS,
    ) -> None:
        self.local_root = Path(local_root).resolve() if local_root else default_local_root()
        self.repo_root = Path(repo_root).resolve() if repo_root else find_main_checkout()
        self.console_db = (
            Path(console_db).resolve()
            if console_db
            else (self.local_root / "harness_console.sqlite3" if local_root else default_console_db_path())
        )
        self.ledger_db = Path(ledger_db).resolve() if ledger_db else (self.local_root / "token_ledger.sqlite3")
        if runs_db is not None:
            self.runs_db = Path(runs_db).resolve()
        else:
            repo_runs = self.repo_root / ".engineering-harness" / "runs.sqlite3"
            local_runs = self.local_root / "runs.sqlite3"
            self.runs_db = local_runs if (not repo_runs.is_file() and local_runs.is_file()) else repo_runs
        self.sessions_dir = Path(sessions_dir).resolve() if sessions_dir else (self.local_root / "sessions")
        self.handovers_dir = Path(handovers_dir).resolve() if handovers_dir else (self.local_root / "handovers")
        self.agent_names_path = (
            Path(agent_names_path).resolve() if agent_names_path else (self.local_root / "agent-names.json")
        )
        self.quotas_path = Path(quotas_path).resolve() if quotas_path else DEFAULT_QUOTAS_PATH
        self.registry_path = Path(registry_path).resolve() if registry_path else DEFAULT_REGISTRY_PATH
        self.launchers_path = Path(launchers_path).resolve() if launchers_path else DEFAULT_LAUNCHERS_PATH
        self.t3_catalog_path = Path(t3_catalog_path).resolve() if t3_catalog_path else None
        self.offline = offline
        self._gh_runner = gh_runner
        self.kill_wait_seconds = float(kill_wait_seconds)
        self.store = ConsoleStore(self.console_db)

    def close(self) -> None:
        self.store.close()

    def _quota_config(self) -> QuotaConfig:
        return QuotaConfig(self.quotas_path)

    # ---------------------------------------------------------- interventions

    def dispatch_task(
        self,
        *,
        task: str,
        complexity: str | None = None,
        files: int | None = None,
        financial: bool = False,
        schema: bool = False,
        auth: bool = False,
        scope: str = "fullstack",
        policy_path: Path | str | None = None,
        revision: str = "HEAD",
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        task_text = str(task or "").strip()
        if not task_text:
            raise ConsoleError("dispatch_task requires a non-empty task description")
        registry = read_json_safe(self.registry_path)
        catalog = read_json_safe(self.t3_catalog_path) if self.t3_catalog_path else None
        health = self.provider_health()
        capabilities = None
        if isinstance(registry, dict):
            if isinstance(catalog, dict):
                capabilities = t3.capabilities_from_catalog(registry, catalog, health=health)
            else:
                capabilities = {"schema_version": 1, "targets": t3.validate_registry(registry)}
        plan = routing.plan(
            task_text,
            files_count=files,
            financial=financial,
            schema=schema,
            auth=auth,
            requested=complexity,
            scope=scope,
            capabilities=capabilities,
            health=health,
        )
        run_id = None
        if policy_path is not None:
            from scripts.engineering_harness.contracts import validate_policy

            policy = validate_policy(json.loads(Path(policy_path).read_text(encoding="utf-8")))
            store = RunsStore(self.runs_db.parent)
            try:
                run_id = Engine(store).create(
                    self.repo_root,
                    task_text,
                    policy,
                    revision=revision,
                    files_count=files,
                    financial=financial,
                    schema=schema,
                    auth=auth,
                    requested=complexity,
                    scope=scope,
                    capabilities=capabilities,
                )
            finally:
                store.close()
        cmd = self.store.enqueue(
            command="dispatch",
            target_type="run" if run_id else "task",
            target_id=run_id or f"plan-{plan['complexity']}",
            payload={
                "task": task_text,
                "complexity": plan["complexity"],
                "scope": scope,
                "run_id": run_id,
                "requires_approval": self.store.gate_requires_approval(plan["complexity"]),
            },
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "run_id": run_id, "plan": plan}

    def pause(
        self,
        *,
        all_scopes: bool = False,
        issue: int | None = None,
        run_id: str | None = None,
        provider: str | None = None,
        reason: str = "operator_pause",
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        target_type, target_id = self._resolve_scope(all_scopes=all_scopes, issue=issue, run_id=run_id, provider=provider)
        cmd = self.store.enqueue(
            command="pause",
            target_type=target_type,
            target_id=target_id,
            payload={"reason": reason},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "paused": self.store.state_snapshot()["pauses"]}

    def resume(
        self,
        *,
        all_scopes: bool = False,
        issue: int | None = None,
        run_id: str | None = None,
        provider: str | None = None,
        reason: str = "operator_resume",
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        target_type, target_id = self._resolve_scope(all_scopes=all_scopes, issue=issue, run_id=run_id, provider=provider)
        cmd = self.store.enqueue(
            command="resume",
            target_type=target_type,
            target_id=target_id,
            payload={"reason": reason},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "paused": self.store.state_snapshot()["pauses"]}

    def kill(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        reason: str = "operator_kill",
        actor: str = "operator",
        transport: str = "cli",
        wait_seconds: float | None = None,
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("kill requires --issue or --run")

        target_type = "run" if run_id and issue is None else "issue"
        target_id = run_id if target_type == "run" else str(issue)
        cmd = self.store.enqueue(
            command="kill",
            target_type=target_type,
            target_id=target_id,
            payload={"phase": "attempted", "reason": reason, "issue": issue, "run_id": run_id},
            actor=actor,
            transport=transport,
        )

        actions: dict[str, Any] = {
            "run_cancel": None,
            "process_kills": [],
            "wip_captures": [],
            "t3_task_cancel_required": [],
        }
        timeout = self.kill_wait_seconds if wait_seconds is None else float(wait_seconds)

        try:
            if run_id:
                if not self.runs_db.is_file():
                    raise ConsoleError(f"Run database not found at {self.runs_db}")
                rstore = RunsStore(self.runs_db.parent)
                try:
                    active = rstore.active(run_id)
                    for att in active:
                        if att["envelope"].get("transport") == "t3":
                            actions["t3_task_cancel_required"].append(
                                {"run_id": run_id, "attempt_id": att["id"], "task_id": att["task_id"]}
                            )
                    status = Engine(rstore).cancel(run_id)
                    actions["run_cancel"] = {"run_id": run_id, "status": status}
                finally:
                    rstore.close()

            if issue is not None:
                board = self.active_board(issue=issue)
                deferred_worktrees: set[str] = set()
                for lease in board["leases"]:
                    if isinstance(lease.get("pid"), int):
                        sig_res = _verify_and_kill_lease(lease, wait_seconds=timeout)
                        actions["process_kills"].append(sig_res)
                        if sig_res.get("attempted") and not sig_res.get("exited") and lease.get("worktree"):
                            deferred_worktrees.add(str(Path(lease["worktree"]).resolve()))
                    if lease.get("transport") == "t3":
                        actions["t3_task_cancel_required"].append(
                            {"issue": issue, "harness": lease.get("harness"), "session": lease.get("session")}
                        )

                captured_worktrees: set[str] = set()
                for lease in board["leases"]:
                    wt = lease.get("worktree")
                    if not wt or not Path(wt).is_dir():
                        continue
                    wt_resolved = str(Path(wt).resolve())
                    if wt_resolved in captured_worktrees:
                        continue
                    captured_worktrees.add(wt_resolved)
                    if wt_resolved in deferred_worktrees:
                        actions["wip_captures"].append(
                            {"worktree": wt, "capture_deferred": True, "reason": "process_still_running"}
                        )
                        continue
                    try:
                        changed = handover_tool.changed_paths(Path(wt))
                        if changed:
                            captured = handover_tool.capture(
                                Path(wt),
                                handover_tool.CaptureOptions(
                                    issue=issue,
                                    reason="manual",
                                    pr=lease.get("pr"),
                                    provider=lease.get("transport") or "unknown",
                                    harness=lease.get("harness") or "unknown",
                                    model=lease.get("model") or "unknown",
                                    agent_name=lease.get("agent_name"),
                                    session_id=lease.get("session"),
                                    push=False,
                                    root=self.handovers_dir,
                                ),
                            )
                            actions["wip_captures"].append(
                                {
                                    "worktree": wt,
                                    "handover_id": captured["envelope"]["handover_id"],
                                    "wip_committed": captured["wip"].committed,
                                    "sha": captured["wip"].sha,
                                    "patch": captured["wip"].patch,
                                }
                            )
                    except Exception as exc:
                        actions["wip_captures"].append({"worktree": wt, "error": str(exc)})
        except Exception as exc:
            self.store.acknowledge(
                cmd["command_id"],
                status="failed",
                result={"error": str(exc), **actions},
                executor=f"console:{transport}",
            )
            raise

        self.store.acknowledge(
            cmd["command_id"],
            status="applied",
            result=actions,
            executor=f"console:{transport}",
        )
        return {"ok": True, "command": cmd, "actions": actions}

    def steer(
        self,
        *,
        note: str,
        issue: int | None = None,
        run_id: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("steer requires --issue or --run")
        clean_note = redact(str(note or "").strip())
        if not clean_note:
            raise ConsoleError("steer requires a non-empty --note")
        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="steer",
            target_type=target_type,
            target_id=target_id,
            payload={"note": clean_note, "issue": issue, "run_id": run_id},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "note": clean_note}

    def handover(
        self,
        *,
        to: str,
        issue: int | None = None,
        run_id: str | None = None,
        reason: str = "manual",
        pin: bool = True,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("handover requires --issue or --run")
        to_val = str(to or "").strip()
        if not to_val:
            raise ConsoleError("handover requires --to <provider|t3-instance>")
        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="handover",
            target_type=target_type,
            target_id=target_id,
            payload={"to": to_val, "reason": reason, "pin": pin, "issue": issue, "run_id": run_id},
            actor=actor,
            transport=transport,
        )
        if not pin:
            self.store.enqueue(
                command="unpin",
                target_type=target_type,
                target_id=target_id,
                payload={"reason": "handover_without_pin"},
                actor=actor,
                transport=transport,
            )
        return {"ok": True, "command": cmd, "pinned_to": to_val if pin else None}

    def pin(
        self,
        *,
        to: str,
        issue: int | None = None,
        run_id: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("pin requires --issue or --run")
        to_val = str(to or "").strip()
        if not to_val:
            raise ConsoleError("pin requires --to <provider|t3-instance>")
        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="pin",
            target_type=target_type,
            target_id=target_id,
            payload={"to": to_val},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "pin": self.store.get_pin(issue=issue, run_id=run_id)}

    def unpin(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("unpin requires --issue or --run")
        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="unpin",
            target_type=target_type,
            target_id=target_id,
            payload={},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd}

    def takeover(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        release_claim: bool = False,
        harness: str | None = None,
        session: str | None = None,
        pr: int | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is None and not run_id:
            raise ConsoleError("takeover requires --issue or --run")
        board = self.active_board(issue=issue, run_id=run_id)
        worktree = None
        branch = None
        detected_harness = harness
        detected_session = session
        detected_pr = pr

        if issue is not None:
            for item in board["items"]:
                if item["issue"] == issue:
                    worktree = item.get("worktree")
                    branch = item.get("branch")
                    detected_harness = detected_harness or item.get("harness")
                    detected_pr = detected_pr or item.get("pr")
                    break
            for lease in board["leases"]:
                if lease.get("issue") == issue:
                    detected_harness = detected_harness or lease.get("harness")
                    detected_session = detected_session or lease.get("session")
                    worktree = worktree or lease.get("worktree")
                    branch = branch or lease.get("branch")
                    detected_pr = detected_pr or lease.get("pr")
                    break

        claim_release = None
        if release_claim and issue is not None and not self.offline:
            if detected_harness and detected_session:
                argv = [
                    "python3",
                    str(Path(__file__).resolve().parents[1] / "issue_claim.py"),
                    "release",
                    str(issue),
                    "--harness",
                    detected_harness,
                    "--session",
                    detected_session,
                    "--json",
                ]
                if detected_pr:
                    argv += ["--pr", str(detected_pr)]
                done = subprocess.run(argv, cwd=str(self.repo_root), capture_output=True, text=True, check=False)
                claim_release = {"returncode": done.returncode, "output": (done.stdout or done.stderr).strip()}
            else:
                claim_release = {"skipped": True, "reason": "missing_harness_or_session"}

        target_type = "issue" if issue is not None else "run"
        target_id = str(issue) if issue is not None else str(run_id)
        cmd = self.store.enqueue(
            command="takeover",
            target_type=target_type,
            target_id=target_id,
            payload={
                "reason": "operator_takeover",
                "worktree": worktree,
                "branch": branch,
                "release_claim": release_claim,
            },
            actor=actor,
            transport=transport,
        )
        return {
            "ok": True,
            "command": cmd,
            "issue": issue,
            "run_id": run_id,
            "worktree": worktree,
            "branch": branch,
            "claim_release": claim_release,
        }

    def set_budget(
        self,
        *,
        provider: str,
        usd: str,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        norm = normalize_budget_provider(provider)
        amount = decimal_str(money(usd), places=2)
        cmd = self.store.enqueue(
            command="set_budget",
            target_type="provider",
            target_id=norm,
            payload={"provider": norm, "usd": amount},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "provider": norm, "budget_usd": amount}

    def mark_status(
        self,
        *,
        provider: str,
        status: str,
        model_family: str = "all",
        reset_at: str | None = None,
        utilization_pct: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        norm_provider = str(provider or "").strip().lower()
        norm_status = str(status or "").strip().upper()
        if norm_status not in ("HEALTHY", "THROTTLED", "EXHAUSTED"):
            raise ConsoleError("status must be HEALTHY, THROTTLED, or EXHAUSTED")
        if not norm_provider:
            raise ConsoleError("provider must not be empty")
        ledger = TokenLedger(db_path=self.ledger_db, quota_config=self._quota_config())
        try:
            snap_id = ledger.record_quota_snapshot(
                provider=norm_provider,
                model_family=model_family,
                status=norm_status,
                reset_at=reset_at,
                utilization_pct=utilization_pct,
                source="manual_status",
            )
        finally:
            ledger.close()
        cmd = self.store.enqueue(
            command="mark_status",
            target_type="provider",
            target_id=norm_provider,
            payload={
                "provider": norm_provider,
                "status": norm_status,
                "model_family": model_family,
                "reset_at": reset_at,
                "quota_snapshot_id": snap_id,
            },
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "provider": norm_provider, "status": norm_status, "snapshot_id": snap_id}

    def set_gate(
        self,
        *,
        tier: str,
        require_approval: bool = True,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        norm_tier = str(tier or "").strip().lower()
        if norm_tier not in routing.TIERS:
            raise ConsoleError(f"tier must be one of {', '.join(routing.TIERS)}")
        cmd = self.store.enqueue(
            command="set_gate",
            target_type="tier",
            target_id=norm_tier,
            payload={"tier": norm_tier, "require_approval": bool(require_approval)},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "tier": norm_tier, "require_approval": bool(require_approval)}

    def approve(
        self,
        *,
        issue: int | None = None,
        run_id: str | None = None,
        handover_id: str | None = None,
        actor: str = "operator",
        transport: str = "cli",
    ) -> dict[str, Any]:
        if issue is not None:
            target_type, target_id = "issue", str(issue)
        elif run_id:
            target_type, target_id = "run", run_id
        elif handover_id:
            target_type, target_id = "task", handover_id
        else:
            raise ConsoleError("approve requires --issue, --run, or --handover-id")
        cmd = self.store.enqueue(
            command="approve",
            target_type=target_type,
            target_id=target_id,
            payload={},
            actor=actor,
            transport=transport,
        )
        return {"ok": True, "command": cmd, "approved": {"target_type": target_type, "target_id": target_id}}

    @staticmethod
    def _resolve_scope(
        *,
        all_scopes: bool,
        issue: int | None,
        run_id: str | None,
        provider: str | None,
    ) -> tuple[str, str | None]:
        chosen = [
            ("all", None) if all_scopes else None,
            ("issue", str(issue)) if issue is not None else None,
            ("run", run_id) if run_id else None,
            ("provider", provider.strip().lower()) if provider else None,
        ]
        active = [c for c in chosen if c is not None]
        if len(active) != 1:
            raise ConsoleError("specify exactly one of --all, --issue, --run, or --provider")
        return active[0]
