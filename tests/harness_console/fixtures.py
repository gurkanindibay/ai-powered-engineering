"""Shared synthetic SQLite, lease, handover, and git fixtures for Phase 5 tests."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import tempfile

from scripts import handover as handover_tool
from scripts.engineering_harness import contracts, leases
from scripts.engineering_harness.store import Store as RunsStore
from scripts.harness_console.service import ConsoleService
from scripts.token_tracker.ledger import TokenLedger


def make_git_repo(path: Path, branch: str = "feature/issue-550") -> Path:
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "-C", str(path), "init", "--quiet", "-b", "main"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(path),
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "base",
        ],
        check=True,
    )
    subprocess.run(["git", "-C", str(path), "checkout", "--quiet", "-b", branch], check=True)
    (path / "work.txt").write_text("initial\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(path), "add", "work.txt"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(path),
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "--quiet",
            "-m",
            "initial work",
        ],
        check=True,
    )
    return path


class SyntheticHarnessEnv:
    """Isolated temp workspace with synthetic SQLite DBs, leases, envelopes, and pickups."""

    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.local_root = self.root / "local"
        self.repo_root = make_git_repo(self.root / "repo")
        self.console_db = self.local_root / "harness_console.sqlite3"
        self.ledger_db = self.local_root / "token_ledger.sqlite3"
        self.runs_db = self.root / ".engineering-harness" / "runs.sqlite3"
        self.sessions_dir = self.local_root / "sessions"
        self.handovers_dir = self.local_root / "handovers"
        self.agent_names_path = self.local_root / "agent-names.json"

        self.local_root.mkdir(parents=True, exist_ok=True)
        self.sessions_dir.mkdir(parents=True, exist_ok=True)
        self.handovers_dir.mkdir(parents=True, exist_ok=True)

        self.run_id, self.attempt_id = self._seed_runs_db()
        self._seed_ledger_db()
        self._seed_leases_and_names()
        self._seed_handovers_and_logs()

    def cleanup(self) -> None:
        self.tmp.cleanup()

    def make_service(self) -> ConsoleService:
        return ConsoleService(
            local_root=self.local_root,
            repo_root=self.repo_root,
            console_db=self.console_db,
            ledger_db=self.ledger_db,
            runs_db=self.runs_db,
            sessions_dir=self.sessions_dir,
            handovers_dir=self.handovers_dir,
            agent_names_path=self.agent_names_path,
            offline=True,
        )

    def _seed_runs_db(self) -> tuple[str, str]:
        store = RunsStore(self.runs_db.parent)
        try:
            policy = {
                "schema_version": 1,
                "image": "sha256:" + ("0" * 64),
                "bridge": ["python3", "-m", "engineering_harness.gateway_bridge"],
                "network": "none",
                "limits": {
                    "tokens": 50000,
                    "seconds": 3600,
                    "attempt_tokens": 10000,
                    "attempt_seconds": 900,
                    "memory_mb": 512,
                    "cpus": 1,
                    "pids": 64,
                    "output_bytes": 65536,
                    "cost": "10.00",
                    "max_repairs": 2,
                },
                "role_paths": {r: [] for r in ("coordinator", "product_owner", "business_analyst", "architect", "backend_developer", "frontend_developer", "developer", "tester")},
                "protected_paths": [".env"],
                "gates": [{"id": "unit", "argv": ["true"], "cwd": ".", "timeout": 60, "test_pattern": None}],
                "acceptance": {"works": ["unit"]},
                "preferences": {},
            }
            plan = {
                "complexity": "high",
                "stages": [{"id": "stage-1", "role": "developer", "depends_on": []}],
            }
            run_id = store.create(str(self.repo_root), "a" * 40, "b" * 40, policy, plan, run_id="run-550-test")
            attempt_id = "att-550-001"
            envelope = {
                "schema_version": 1,
                "run_id": run_id,
                "task_id": "stage-1",
                "attempt_id": attempt_id,
                "transport": "t3",
                "candidate": "b" * 40,
                "target": {"provider": "claudeAgent", "model": "claude-sonnet-5-5"},
            }
            store.claim(run_id, envelope, reserve="1.50", token_limit=4000)
            return run_id, attempt_id
        finally:
            store.close()

    def _seed_ledger_db(self) -> None:
        ledger = TokenLedger(db_path=self.ledger_db)
        try:
            now_iso = datetime.now(timezone.utc).isoformat()
            ledger.record_usage_event(
                source_event_key="test:claude:1",
                recorded_at=now_iso,
                provider="claude",
                harness="t3",
                model="claude-sonnet-5-5",
                session_id="ses_550",
                agent_name="Alparslan",
                issue_number=550,
                pr_number=560,
                harness_run_id=self.run_id,
                harness_attempt_id=self.attempt_id,
                input_tokens=1200,
                output_tokens=300,
                estimated_cost_usd="0.008100",
                accuracy="exact",
                billing_mode="subscription",
            )
            ledger.record_usage_event(
                source_event_key="test:copilot:1",
                recorded_at=now_iso,
                provider="copilot",
                harness="copilot_cli",
                model="deepseek-r1",
                session_id="ses_ds",
                issue_number=550,
                input_tokens=10000,
                output_tokens=2000,
                estimated_cost_usd="12.000000",
                accuracy="estimated",
                billing_mode="api",
            )
        finally:
            ledger.close()

    def _seed_leases_and_names(self) -> None:
        store = leases.LeaseStore(self.sessions_dir)
        store.write(
            leases.Lease(
                harness="claude_code",
                session="ses_550",
                model="claude-sonnet-5-5",
                agent_name="Alparslan",
                issue=550,
                pr=560,
                worktree=str(self.repo_root),
                branch="feature/issue-550",
                transport="cli",
                context_pct="68",
                quota_pct="22",
            )
        )
        self.agent_names_path.write_text(
            json.dumps(
                {
                    "reservations": [
                        {
                            "name": "Alparslan",
                            "harness": "claude_code",
                            "session": "ses_550",
                            "model": "claude-sonnet-5-5",
                            "issues": [550],
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )

    def _seed_handovers_and_logs(self) -> None:
        env_data = {
            "schema_version": 1,
            "handover_id": "ho-550-001",
            "created_at": "2026-11-27T18:00:00Z",
            "reason": "context_ceiling",
            "from": {
                "provider": "claude",
                "harness": "claude_code",
                "model": "claude-sonnet-5-5",
                "agent_name": "Alparslan",
                "session_id": "ses_550",
            },
            "target_constraints": {
                "risk_tier": "medium",
                "role": "developer",
                "excluded_providers": [],
            },
            "git_state": {
                "issue": 550,
                "pr": 560,
                "branch": "feature/issue-550",
                "base_sha": "a" * 40,
                "head_sha": "b" * 40,
                "wip_committed": True,
                "worktree_path": str(self.repo_root),
            },
            "progress": {
                "completed": ["Added SQLite command store"],
                "remaining": ["Finish MCP adapter"],
                "last_verification": {"command": "pytest", "status": "passed", "summary": "all green"},
            },
            "decisions": ["Use WAL mode"],
            "key_pointers": ["scripts/harness_console/store.py:1"],
        }
        env_data["checksum_sha256"] = handover_tool.checksum(env_data)
        self.envelope_path = self.handovers_dir / "550-001.json"
        self.envelope_path.write_text(json.dumps(env_data, indent=2), encoding="utf-8")

        pickup_dir = self.handovers_dir / "pickup"
        pickup_dir.mkdir(parents=True, exist_ok=True)
        (pickup_dir / "ho-550-001.md").write_text(
            "# Handover pickup: issue #550\n\n- Branch: `feature/issue-550`\n",
            encoding="utf-8",
        )

        logs_dir = self.local_root / "coordinator" / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        (logs_dir / "ho-550-001.log").write_text(
            "Starting worker for #550\napi_key=SECRET_SHOULD_BE_REDACTED\n",
            encoding="utf-8",
        )
