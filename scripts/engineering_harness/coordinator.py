"""Deterministic 0-token coordinator for reviewer-coordinated auto-handover.

Phase 4 (Track A) of ``token-aware-harness-and-handover-analysis.md`` splits
coordination in two tiers. This module is Tier 1: pure Python that validates a
handover checkpoint, picks the next qualified healthy provider, transfers the
claim and dispatches over one of the three transports. It never calls an LLM
and never edits a branch. The reviewer LLM (Tier 2) is only *escalated to*:
invalid checkpoints, thrashing (2+ handovers or 2+ failed repairs) and a task
with no healthy qualified provider are recorded as escalation briefs.

Transports
    t3          write a ``t3-dispatch`` payload for the orchestrator. A T3
                child shares the candidate checkout, so the payload requires
                ``task_cancel`` of the outgoing child before it is consumed.
    cli         spawn a headless CLI (``claude -p``, ``codex exec --json``,
                ``gemini -p`` or the local Copilot CLI) in a fresh worktree on
                the PR branch. A non-zero exit or a rate-limit message is
                captured deterministically by ``handover.py capture``.
    pickup      write a ready-to-paste brief for an interactive IDE/Desktop
                session and stop; no process is started.

Every decision is reproducible from files on disk, so a dry run and a live run
differ only in whether a process is spawned.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
import re
import subprocess
from typing import Any, Callable, Iterable, Sequence

from . import t3
from .leases import (DEFAULT_RELATIVE as LEASES_RELATIVE, LeaseError, LeaseStore,
                     default_root as default_leases_root, isoformat, slug,
                     t3_leases, utc_now)
from .routing import (HarnessError, QuotaParkedError, canonical_provider, route,
                      ROLES, TIERS)

SCHEMA_VERSION = 1
DEFAULT_LAUNCHERS = Path(__file__).resolve().parents[2] / "config" / "engineering-harness" / "launchers.json"
MAX_HANDOVERS_FALLBACK = 3
ESCALATION_THRESHOLD = 2  # 2+ handovers or 2+ failed repairs wakes the reviewer
TRANSPORT_ORDER = ("t3", "cli", "copilot_cli")
TRANSPORTS = (*TRANSPORT_ORDER, "pickup")

INVALID_CHECKPOINT = "invalid_checkpoint"
THRASH = "thrash"
HANDOVER_CAP = "handover_cap"
NO_HEALTHY_PROVIDER = "no_healthy_provider"
NO_QUALIFIED_PROVIDER = "no_qualified_provider"
DIRTY_WORKTREE_PRESERVED = "dirty_worktree_preserved"
STALE_LEASE = "stale_lease"
T3_LEASE_EXPIRED = "t3_lease_expired"
ESCALATION_REASONS = (INVALID_CHECKPOINT, THRASH, HANDOVER_CAP, NO_HEALTHY_PROVIDER,
                      NO_QUALIFIED_PROVIDER, DIRTY_WORKTREE_PRESERVED, STALE_LEASE,
                      T3_LEASE_EXPIRED)
PLACEHOLDERS = ("{model}", "{prompt}", "{effort}")
_RATE_LIMIT = re.compile(r"\b(429|rate[ _-]?limit|quota|usage limit|too many requests)\b", re.IGNORECASE)


class CoordinatorError(ValueError):
    """Configuration or operator error (exit 2 for the CLI)."""


def max_handovers() -> int:
    """The soft anti-thrash cap, defined once by issue_claim.py."""
    try:
        from scripts.issue_claim import MAX_HANDOVERS
        return int(MAX_HANDOVERS)
    except Exception:  # pragma: no cover - import guard for standalone use
        return MAX_HANDOVERS_FALLBACK


def utc_iso() -> str:
    return isoformat(utc_now())


# --------------------------------------------------------------------- signals


@dataclass(frozen=True)
class Signal:
    """What the outgoing worker reported; validated before any action."""

    issue: int
    reason: str = "manual"
    role: str = "developer"
    tier: str = "medium"
    from_provider: str = "unknown"
    from_harness: str = "unknown"
    from_session: str = "unknown"
    excluded_providers: tuple[str, ...] = ()
    pr: int | None = None
    worktree: str | None = None
    failed_repairs: int = 0

    def validate(self) -> "Signal":
        from scripts import handover as handover_tool

        if isinstance(self.issue, bool) or not isinstance(self.issue, int) or self.issue <= 0:
            raise CoordinatorError("issue must be a positive integer")
        if self.reason not in handover_tool.REASONS:
            raise CoordinatorError(f"reason must be one of {', '.join(handover_tool.REASONS)}")
        if self.role not in ROLES:
            raise CoordinatorError(f"role must be one of {', '.join(ROLES)}")
        if self.tier not in TIERS:
            raise CoordinatorError(f"tier must be one of {', '.join(TIERS)}")
        if isinstance(self.failed_repairs, bool) or not isinstance(self.failed_repairs, int) or self.failed_repairs < 0:
            raise CoordinatorError("failed_repairs must be a nonnegative integer")
        if self.pr is not None and (isinstance(self.pr, bool) or not isinstance(self.pr, int) or self.pr <= 0):
            raise CoordinatorError("pr must be a positive integer")
        return self


@dataclass(frozen=True)
class Decision:
    """A deterministic routing outcome; serialisable for `--json`."""

    action: str
    reason: str
    detail: str = ""
    transport: str | None = None
    target: dict | None = None
    escalation: dict | None = None
    resume_after: str | None = None
    handover_count: int = 0
    excluded_providers: tuple[str, ...] = ()

    def to_dict(self) -> dict:
        return {"action": self.action, "reason": self.reason, "detail": self.detail,
                "transport": self.transport,
                "target": None if self.target is None else {
                    "provider": self.target.get("provider"), "model": self.target.get("model"),
                    "canonical_provider": canonical_provider(self.target),
                    "priority": self.target.get("priority", 1)},
                "escalation": self.escalation, "resume_after": self.resume_after,
                "handover_count": self.handover_count,
                "excluded_providers": list(self.excluded_providers)}


def escalation(reason: str, detail: str, *, issue: int | None = None, pr: int | None = None,
               handover_id: str | None = None, resume_after: str | None = None) -> dict:
    """A structured wake-up for the Tier-2 reviewer (never a code review itself)."""
    if reason not in ESCALATION_REASONS:
        raise CoordinatorError(f"unknown escalation reason: {reason}")
    body = (
        f"Coordinator escalation: **{reason}**\n\n{detail}\n\n"
        + (f"Resume after: `{resume_after}`\n\n" if resume_after else "")
        + "This is a deterministic 0-token coordination result. The reviewer decides whether to "
          "park the task for a quota reset, re-route it, or ask the operator for help. The reviewer "
          "does not edit the branch or merge (Rules 14 and 16)."
    )
    return {"schema_version": SCHEMA_VERSION, "reason": reason, "detail": detail,
            "issue": issue, "pr": pr, "handover_id": handover_id,
            "resume_after": resume_after,
            "reviewer": {"tool": "scripts/review_bot.py", "event": "COMMENT", "body": body},
            "created_at": utc_iso()}


# ------------------------------------------------------------------- selection


def load_registry(path: Path | str = t3.DEFAULT_REGISTRY) -> dict:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CoordinatorError(f"cannot read registry {path}: {exc}") from exc
    t3.validate_registry(data)
    return data


def targets_from_registry(registry: dict, catalog: dict | None = None,
                          health: dict | None = None, launchers: dict | None = None) -> list[dict]:
    """Registry targets, plus headless-CLI twins for providers with a launcher.

    The registry's T3 and CLI rows are the capability truth. A provider that a
    headless CLI can also run (claude, codex, gemini, copilot) gets a synthetic
    ``<provider>-cli`` twin so cross-transport spill needs no duplicate registry
    row: ``canonical_provider`` still resolves to the shared Track B health key.
    """
    if catalog is not None:
        live = t3.capabilities_from_catalog(registry, catalog, health)
        base = list(live["targets"]) + [t for t in t3.validate_registry(registry)
                                       if t.get("transport") != "t3"]
    else:
        base = t3.validate_registry(registry)
    return base + cli_targets(base, launchers if launchers is not None else load_launchers())


def cli_targets(targets: Sequence[dict], launchers: dict) -> list[dict]:
    """Synthetic headless-CLI twins; a CLI-only provider keeps its health key."""
    existing = {(canonical_provider(t), t["model"]) for t in targets
                if t.get("transport") in ("cli", "copilot_cli")}
    twins = []
    for target in targets:
        if target.get("transport") != "t3":
            continue
        provider = canonical_provider(target)
        launcher = launchers["launchers"].get(provider)
        if launcher is None or (provider, target["model"]) in existing:
            continue
        existing.add((provider, target["model"]))
        twins.append({**target, "provider": f"{provider}-cli",
                      "transport": launcher.get("transport", "cli")})
    return twins


def _eligible(targets: Iterable[dict], excluded: set[str], available_t3: set[str] | None) -> list[dict]:
    kept = []
    for target in targets:
        if canonical_provider(target) in excluded:
            continue
        if target.get("transport") == "t3" and available_t3 is not None \
                and target.get("provider") not in available_t3:
            continue
        kept.append(target)
    return kept


def _attempt(subset: list[dict], signal: Signal, health: dict | None) -> tuple[dict | None, str, str | None]:
    """Route within one transport; returns (target, error-class, resume_after)."""
    if not subset:
        return None, "empty", None
    try:
        return route({"schema_version": 1, "targets": subset}, signal.role, signal.tier, health=health), "", None
    except QuotaParkedError as exc:
        return None, NO_HEALTHY_PROVIDER, exc.resume_after
    except HarnessError:
        return None, NO_QUALIFIED_PROVIDER, None


def decide(signal: Signal, *, targets: Sequence[dict], health: dict | None = None,
           handover_count: int = 0, transport: str = "auto",
           available_t3: set[str] | None = None) -> Decision:
    """Pick the next transport/provider, or park with a reviewer escalation."""
    signal.validate()
    if transport not in (*TRANSPORTS, "auto"):
        raise CoordinatorError(f"transport must be auto or one of {', '.join(TRANSPORTS)}")
    cap = max_handovers()
    if handover_count >= cap:
        detail = (f"#{signal.issue} already had {handover_count} handovers "
                  f"(MAX_HANDOVERS={cap}); the task is parked for the reviewer or a human.")
        return Decision("park", HANDOVER_CAP, detail, escalation=escalation(
            HANDOVER_CAP, detail, issue=signal.issue, pr=signal.pr,
            handover_id=f"ho-{signal.issue}-{handover_count:03d}"), handover_count=handover_count,
            excluded_providers=tuple(signal.excluded_providers))

    excluded = {provider.lower() for provider in signal.excluded_providers}
    eligible = _eligible(targets, excluded, available_t3)
    orders = (transport,) if transport != "auto" else TRANSPORT_ORDER
    parked: list[str | None] = []
    failures: list[str] = []
    for name in orders:
        if name == "pickup":
            chosen, failure, resume_after = _attempt(eligible, signal, health)
        else:
            chosen, failure, resume_after = _attempt(
                [t for t in eligible if t.get("transport") == name], signal, health)
        if chosen is None:
            failures.append(failure)
            if resume_after:
                parked.append(resume_after)
            continue
        escalate = None
        if handover_count + 1 >= ESCALATION_THRESHOLD or signal.failed_repairs >= ESCALATION_THRESHOLD:
            detail = (f"#{signal.issue} reached {handover_count + 1} handovers "
                      f"({signal.failed_repairs} failed repairs); the next provider was selected "
                      "deterministically, so the reviewer should check for thrashing or an "
                      "architectural mismatch.")
            escalate = escalation(THRASH, detail, issue=signal.issue, pr=signal.pr,
                                  handover_id=f"ho-{signal.issue}-{handover_count + 1:03d}")
        return Decision("dispatch", "handover", f"dispatch {signal.reason} handover over {name}",
                        transport=name, target=chosen, escalation=escalate,
                        handover_count=handover_count + 1,
                        excluded_providers=tuple(signal.excluded_providers))

    if parked:
        resume_after = min(parked)  # ISO-8601 UTC strings sort chronologically
        detail = (f"No healthy qualified provider for {signal.role}/{signal.tier} "
                  f"({' / '.join(sorted(set(failures)))}); resume after {resume_after}.")
        return Decision("park", NO_HEALTHY_PROVIDER, detail, resume_after=resume_after,
                        escalation=escalation(NO_HEALTHY_PROVIDER, detail, issue=signal.issue,
                                              pr=signal.pr, resume_after=resume_after),
                        handover_count=handover_count,
                        excluded_providers=tuple(signal.excluded_providers))
    detail = (f"No target in the registry is qualified for {signal.role}/{signal.tier} "
              f"(transport={transport}); a provider will not be downgraded below the risk floor.")
    return Decision("park", NO_QUALIFIED_PROVIDER, detail,
                    escalation=escalation(NO_QUALIFIED_PROVIDER, detail, issue=signal.issue,
                                          pr=signal.pr),
                    handover_count=handover_count,
                    excluded_providers=tuple(signal.excluded_providers))


# ------------------------------------------------------------------- launchers


def load_launchers(path: Path | str = DEFAULT_LAUNCHERS) -> dict:
    """Headless CLI argv templates, keyed by canonical provider."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CoordinatorError(f"cannot read launchers {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("schema_version") != 1 \
            or not isinstance(data.get("launchers"), dict):
        raise CoordinatorError("launchers require schema_version=1 and a launchers object")
    for provider, entry in data["launchers"].items():
        argv = entry.get("argv") if isinstance(entry, dict) else None
        if not isinstance(argv, list) or not argv or any(not isinstance(part, str) or not part for part in argv):
            raise CoordinatorError(f"launcher {provider} requires a nonempty argv list")
        if not any("{prompt}" in part for part in argv):
            raise CoordinatorError(f"launcher {provider} argv requires a {{prompt}} placeholder")
        unknown = set(part for part in argv for part in re.findall(r"\{[a-z_]+\}", part)) - set(PLACEHOLDERS)
        if unknown:
            raise CoordinatorError(f"launcher {provider} uses unknown placeholders: {', '.join(sorted(unknown))}")
    return data


def command_for(target: dict, prompt: str, launchers: dict,
                effort: str | None = None) -> list[str]:
    provider = canonical_provider(target)
    entry = launchers["launchers"].get(provider)
    if entry is None:
        raise CoordinatorError(f"no headless launcher for provider {provider}; use the pickup queue")
    values = {"{model}": str(target.get("model", "")), "{prompt}": prompt,
              "{effort}": effort or ""}
    return [part.replace("{model}", values["{model}"]).replace("{prompt}", values["{prompt}"])
            .replace("{effort}", values["{effort}"]) for part in entry["argv"]]


def detect_rate_limit(text: str | None) -> bool:
    return bool(text and _RATE_LIMIT.search(text))


# -------------------------------------------------------------------- dispatch


@dataclass
class DispatchOptions:
    """Where dispatch artifacts live and whether to actually spawn a process."""

    root: Path
    repo: Path
    worktree: Path | None = None
    branch: str | None = None
    pr: int | None = None
    envelope_path: Path | None = None
    dry_run: bool = False
    launchers: dict = field(default_factory=load_launchers)
    incoming_harness: str | None = None
    incoming_session: str | None = None
    spawn_timeout: int = 1800
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run
    capture_fn: Callable[..., dict] | None = None

    def directories(self) -> dict[str, Path]:
        return {"dispatch": self.root / "dispatch", "pickup": self.root / "handovers" / "pickup",
                "logs": self.root / "coordinator" / "logs",
                "state": self.root / "coordinator" / "dispatched",
                "escalations": self.root / "coordinator" / "escalations"}


def _atomic_json(path: Path, payload: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)
    return path


def incoming_identity(decision: Decision, handover_id: str,
                      options: DispatchOptions) -> dict:
    """The identity recorded by `issue_claim.py transfer` for the incoming worker."""
    if options.incoming_harness:
        harness = options.incoming_harness
    elif decision.transport == "t3":
        harness = "t3"
    else:
        harness = canonical_provider(decision.target or {})
    session = options.incoming_session or f"dispatch-{slug(handover_id)}"
    return {"harness": harness, "session": session, "model": (decision.target or {}).get("model", "unknown")}


def _prompt(envelope: dict, target: dict) -> str:
    from scripts import handover as handover_tool

    return (f"You are taking over issue #{envelope['git_state']['issue']} as "
            f"{target.get('model')} ({canonical_provider(target)}). Read the checkpoint below, "
            "check out the branch in a worktree, finish the remaining work, run the gates, then "
            "send the PR for review. Do not force-remove worktrees or replay the old transcript.\n\n"
            + handover_tool.render(envelope))


def _pickup_brief(envelope: dict, target: dict, options: DispatchOptions) -> str:
    from scripts import handover as handover_tool

    branch = options.branch or envelope["git_state"]["branch"]
    issue = envelope["git_state"]["issue"]
    pr = options.pr or envelope["git_state"].get("pr")
    accept = (f"python3 scripts/issue_claim.py accept {issue} --harness <harness> --session <session>"
              + (f" --pr {pr}" if pr else ""))
    lines = [
        f"# Handover pickup: issue #{issue}",
        "",
        f"- Target: **{target.get('model')}** ({canonical_provider(target)})",
        f"- Branch: `{branch}`",
        f"- Worktree: `{options.worktree or envelope['git_state']['worktree_path']}`",
        f"- Handover: `{envelope['handover_id']}`",
        "",
        "Start by reading the checkpoint, then check out the branch in a fresh worktree:",
        "",
        "```bash",
        f"git worktree add --detach <path> {branch}",
        accept,
        "```",
        "",
        handover_tool.render(envelope),
    ]
    return "\n".join(lines) + "\n"


def prepare_worktree(repo: Path, branch: str, path: Path,
                     runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> Path:
    """Create a fresh detached worktree at ``branch``; never reuse or force-remove one.

    ``--detach`` is deliberate: the outgoing session may still hold a worktree
    on the branch, and Rule 11 forbids force-removing it. The incoming worker
    commits in this worktree and pushes back to ``branch``.
    """
    if path.exists():
        raise CoordinatorError(f"worktree path already exists: {path}; refusing to reuse or overwrite it")
    done = runner(["git", "-C", str(repo), "worktree", "add", "--detach", str(path), branch],
                  capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise CoordinatorError(f"cannot create worktree {path}: {done.stderr.strip()}")
    return path


def dispatch(decision: Decision, envelope: dict, options: DispatchOptions) -> dict:
    """Materialise one dispatch; returns a JSON record (no LLM involved)."""
    if decision.action != "dispatch" or decision.target is None or decision.transport is None:
        raise CoordinatorError("only a dispatch decision can be dispatched")
    directories = options.directories()
    handover_id = envelope["handover_id"]
    issue = envelope["git_state"]["issue"]
    identity = incoming_identity(decision, handover_id, options)
    prompt = _prompt(envelope, decision.target)
    record: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION, "handover_id": handover_id, "issue": issue,
        "pr": options.pr or envelope["git_state"].get("pr"),
        "transport": decision.transport, "target": decision.to_dict()["target"],
        "incoming": identity, "branch": options.branch or envelope["git_state"]["branch"],
        "worktree": str(options.worktree) if options.worktree else envelope["git_state"]["worktree_path"],
        "dry_run": options.dry_run, "created_at": utc_iso(),
    }
    if decision.transport == "t3":
        payload = {**record, "kind": "t3-dispatch", "prompt": prompt,
                   "envelope_path": str(options.envelope_path or ""),
                   "delegate_task": {"title": f"Handover #{issue}: finish and send the PR",
                                     "mode": "wait", "provider": decision.target.get("provider"),
                                     "model": decision.target.get("model"), "prompt": prompt},
                   "requires": {"task_cancel_before_dispatch": True,
                                "accept": (f"python3 scripts/issue_claim.py accept {issue} "
                                           f"--harness {identity['harness']} --session "
                                           f"{identity['session']}")}}
        path = directories["dispatch"] / "t3" / f"{handover_id}.json"
        if not options.dry_run:
            record["payload_path"] = str(_atomic_json(path, payload))
        record["status"] = "dry_run" if options.dry_run else "queued"
    elif decision.transport in ("cli", "copilot_cli"):
        argv = command_for(decision.target, prompt, options.launchers,
                           effort=(decision.target.get("selected_options") or {}).get("effort"))
        record["command"] = argv
        log = directories["logs"] / f"{handover_id}.log"
        record["log_path"] = str(log)
        if options.dry_run:
            record["status"] = "dry_run"
        else:
            if options.worktree is None:
                raise CoordinatorError("a CLI dispatch requires --worktree")
            log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            env = {**os.environ, "AGENT_SESSION_ID": identity["session"],
                   "AGENT_MODEL": identity["model"]}
            done = None
            with open(log, "w", encoding="utf-8") as handle:
                try:
                    done = options.runner(argv, cwd=str(options.worktree), capture_output=True, text=True,
                                          timeout=options.spawn_timeout, env=env)
                    handle.write((done.stdout or "") + (done.stderr or ""))
                except Exception as exc:  # timeout, missing binary: preserve the work deterministically
                    handle.write(f"dispatch failed: {exc}\n")
                    record["status"] = "failed"
                    record["error"] = str(exc)
                    record.update(_capture_failure(options, decision, envelope, "crash"))
            if done is not None:
                record["exit_code"] = done.returncode
                record["rate_limited"] = detect_rate_limit((done.stderr or "") + (done.stdout or ""))
                if done.returncode == 0:
                    record["status"] = "completed"
                else:
                    record["status"] = "failed"
                    record.update(_capture_failure(options, decision, envelope,
                                                   "provider_quota_exhausted" if record["rate_limited"] else "crash"))
    else:  # pickup
        path = directories["pickup"] / f"{handover_id}.md"
        if not options.dry_run:
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_text(_pickup_brief(envelope, decision.target, options), encoding="utf-8")
        record["pickup_path"] = str(path)
        record["status"] = "dry_run" if options.dry_run else "queued"
    if not options.dry_run:
        _atomic_json(directories["state"] / f"{handover_id}.json", record)
    return record


def _capture_failure(options: DispatchOptions, decision: Decision, envelope: dict, reason: str) -> dict:
    """Layer-2 defense: deterministically checkpoint a failed CLI worker."""
    if options.capture_fn is not None:
        return {"captured": options.capture_fn(reason=reason, envelope=envelope)}
    if options.worktree is None:
        return {"capture_error": "no worktree to capture"}
    from scripts import handover as handover_tool
    from .leases import slug as lease_slug

    try:
        result = handover_tool.capture(Path(options.worktree), handover_tool.CaptureOptions(
            issue=envelope["git_state"]["issue"], reason=reason, pr=options.pr,
            provider=canonical_provider(decision.target or {}),
            harness=decision.transport or "cli", model=str((decision.target or {}).get("model", "unknown")),
            session_id=f"dispatch-{lease_slug(envelope['handover_id'])}",
            role="developer", root=Path(options.root) / "handovers"))
        return {"captured": result["path"], "wip_committed": result["wip"].committed}
    except Exception as exc:  # capture must never hide the original failure
        return {"capture_error": str(exc)}


# -------------------------------------------------------------- watchdog (L3)


def _changed(worktree: Path) -> list[str]:
    from scripts import handover as handover_tool

    return handover_tool.changed_paths(worktree)


def write_escalation(root: Path, record: dict, *, key: str) -> Path:
    return _atomic_json(root / "coordinator" / "escalations" / f"{slug(key)}.json", record)


def recover(root: Path | str | None = None, *, now: datetime | None = None, dry_run: bool = False,
            stale_factor: int = 2, capture_fn: Callable[..., dict] | None = None,
            t3_db: Path | str | None = None, sessions_root: Path | str | None = None) -> dict:
    """Layer-3 watchdog: snapshot expired workers without deleting their work.

    A dirty expired worktree is captured with ``handover.py`` (a ``wip`` commit
    on its branch or a replayable patch). The worktree itself is never removed,
    reset or force-cleaned. A T3 attempt lease requires ``task_cancel`` before
    its candidate may be exported, so the coordinator escalates instead of
    touching the candidate.

    ``root`` is the local state root (``.agents/local``); ``sessions_root``
    overrides where lease files live.
    """
    moment = now or utc_now()
    local_root = Path(root) if root is not None else default_leases_root().parent
    leases_root = Path(sessions_root) if sessions_root is not None else local_root / LEASES_RELATIVE.name
    store = LeaseStore(leases_root, now=lambda: moment)
    actions: list[dict] = []
    for lease in store.expired(stale_factor):
        entry: dict[str, Any] = {"kind": "local", "lease": lease.to_dict()}
        worktree = Path(lease.worktree) if lease.worktree else None
        if worktree is None or not worktree.is_dir():
            detail = (f"Session {lease.harness}/{lease.session} expired and its worktree "
                      f"{lease.worktree or '(unset)'} is not available; nothing was changed.")
            record = escalation(STALE_LEASE, detail, issue=lease.issue, pr=lease.pr)
            entry.update(action="escalate", escalation=record)
            if not dry_run:
                write_escalation(local_root, record, key=f"{lease.harness}-{lease.session}")
            actions.append(entry)
            continue
        try:
            changed = _changed(worktree)
        except Exception as exc:
            detail = f"Cannot inspect {worktree}: {exc}; the worktree was left untouched."
            record = escalation(STALE_LEASE, detail, issue=lease.issue, pr=lease.pr)
            entry.update(action="escalate", escalation=record)
            if not dry_run:
                write_escalation(local_root, record, key=f"{lease.harness}-{lease.session}")
            actions.append(entry)
            continue
        if not changed:
            entry.update(action="clean", detail="Worktree is clean; the claim can be transferred.")
            if not dry_run:
                store.remove(lease)
            actions.append(entry)
            continue
        if not lease.issue:
            detail = (f"Expired session {lease.harness}/{lease.session} has uncommitted work in {worktree}, "
                      "but it recorded no issue number, so no handover envelope can be built. The worktree "
                      "is preserved as-is.")
            record = escalation(STALE_LEASE, detail, pr=lease.pr)
            entry.update(action="escalate", changed=changed[:20], escalation=record)
            if not dry_run:
                write_escalation(local_root, record, key=f"{lease.harness}-{lease.session}")
            actions.append(entry)
            continue
        if dry_run:
            entry.update(action="would_capture", changed=changed[:20])
            actions.append(entry)
            continue
        try:
            if capture_fn is not None:
                captured = capture_fn(lease=lease, worktree=worktree, changed=changed)
            else:
                from scripts import handover as handover_tool

                captured = handover_tool.capture(worktree, handover_tool.CaptureOptions(
                    issue=lease.issue or 0, reason="stale_lease", pr=lease.pr,
                    provider=lease.transport, harness=lease.harness, model=lease.model,
                    agent_name=lease.agent_name, session_id=lease.session,
                    root=local_root / "handovers"))
            entry.update(action="captured", changed=changed[:20], captured=captured)
        except Exception as exc:
            detail = (f"Expired session {lease.harness}/{lease.session} has uncommitted work in "
                      f"{worktree}, but capture failed: {exc}. The worktree is preserved as-is.")
            record = escalation(DIRTY_WORKTREE_PRESERVED, detail, issue=lease.issue, pr=lease.pr)
            entry.update(action="escalate", changed=changed[:20], escalation=record)
            if not dry_run:
                write_escalation(local_root, record, key=f"{lease.harness}-{lease.session}")
            actions.append(entry)
            continue
        detail = (f"Session {lease.harness}/{lease.session} expired with uncommitted work; it was "
                  "checkpointed deterministically. The worktree was not removed.")
        record = escalation(DIRTY_WORKTREE_PRESERVED, detail, issue=lease.issue, pr=lease.pr)
        entry["escalation"] = record
        if not dry_run:
            write_escalation(local_root, record, key=f"{lease.harness}-{lease.session}")
            store.remove(lease)
        actions.append(entry)

    if t3_db is not None:
        try:
            expired = t3_leases(t3_db, moment.timestamp())
        except LeaseError as exc:
            expired = []
            actions.append({"kind": "t3", "action": "escalate", "detail": str(exc)})
        for attempt in expired:
            detail = (f"T3 attempt {attempt.attempt_id} (run {attempt.run_id}, task {attempt.task_id}) "
                      "missed its heartbeat lease. task_cancel the child, then export the candidate "
                      "with `handover.py export-t3 --child-cancelled`.")
            record = escalation(T3_LEASE_EXPIRED, detail, handover_id=attempt.attempt_id)
            entry = {"kind": "t3", "attempt": {"attempt_id": attempt.attempt_id, "run_id": attempt.run_id,
                                               "task_id": attempt.task_id}, "action": "escalate",
                     "escalation": record}
            if not dry_run:
                write_escalation(local_root, record, key=f"t3-{attempt.attempt_id}")
            actions.append(entry)

    return {"schema_version": SCHEMA_VERSION, "checked_at": isoformat(moment),
            "dry_run": dry_run, "actions": actions,
            "counts": {kind: sum(1 for a in actions if a.get("action") == kind)
                       for kind in ("captured", "clean", "escalate", "would_capture")}}


# --------------------------------------------------------------- pending work


def known_handover_issues(handover_root: Path | str) -> set[int]:
    """Issue numbers with at least one valid envelope (dispatched or not)."""
    from scripts import handover as handover_tool

    directory = Path(handover_root)
    issues: set[int] = set()
    if not directory.is_dir():
        return issues
    for path in directory.glob("*.json"):
        envelope, errors = handover_tool.validate_file(path)
        if envelope is not None and not errors:
            issues.add(int(envelope["git_state"]["issue"]))
    return issues


def pending_handovers(handover_root: Path | str, state_root: Path | str) -> list[dict]:
    """Envelopes whose checkpoint exists but has no dispatch record yet."""
    from scripts import handover as handover_tool

    handover_dir = Path(handover_root)
    state_dir = Path(state_root) / "coordinator" / "dispatched"
    pending = []
    if not handover_dir.is_dir():
        return pending
    for path in sorted(handover_dir.glob("*.json")):
        envelope, errors = handover_tool.validate_file(path)
        if envelope is None:
            pending.append({"path": str(path), "errors": errors})
            continue
        if not (state_dir / f"{envelope['handover_id']}.json").exists():
            pending.append({"path": str(path), "handover_id": envelope["handover_id"],
                            "issue": envelope["git_state"]["issue"],
                            "reason": envelope["reason"], "errors": []})
    return pending


def write_lease_heartbeat(root: Path | str | None = None, **fields: Any) -> Path:
    store = LeaseStore(root)
    return store.write(Lease(**fields))


# ---------------------------------------------------------------- simulation


def evaluate_case(case: dict, registry: dict | None = None) -> dict:
    """Run one synthetic trigger through the decision engine (dry run)."""
    if not isinstance(case, dict) or not case.get("id"):
        raise CoordinatorError("each simulation case requires an id")
    registry = registry or load_registry()
    signal = Signal(**case.get("signal", {})).validate()
    targets = case.get("targets") or targets_from_registry(registry)
    decision = decide(signal, targets=targets, health=case.get("health"),
                      handover_count=int(case.get("handover_count", 0)),
                      transport=case.get("transport", "auto"),
                      available_t3=set(case["available_t3"]) if case.get("available_t3") is not None else None)
    expect = case.get("expect") or {}
    actual = {"action": decision.action, "transport": decision.transport,
              "provider": (decision.target or {}).get("provider"),
              "model": (decision.target or {}).get("model"),
              "canonical_provider": canonical_provider(decision.target) if decision.target else None,
              "reason": decision.reason,
              "escalation": (decision.escalation or {}).get("reason"),
              "resume_after": decision.resume_after,
              "handover_count": decision.handover_count}
    mismatches = {key: {"expected": value, "actual": actual.get(key)}
                  for key, value in expect.items() if actual.get(key) != value}
    return {"id": case["id"], "ok": not mismatches, "mismatches": mismatches,
            "decision": decision.to_dict(), "actual": actual}


def run_simulation(cases: dict, registry: dict | None = None) -> dict:
    if not isinstance(cases, dict) or cases.get("schema_version") != 1 \
            or not isinstance(cases.get("scenarios"), list) or not cases["scenarios"]:
        raise CoordinatorError("scenarios require schema_version=1 and a nonempty scenarios list")
    registry = registry or load_registry()
    results = [evaluate_case(case, registry) for case in cases["scenarios"]]
    return {"schema_version": SCHEMA_VERSION, "passed": sum(1 for r in results if r["ok"]),
            "failed": sum(1 for r in results if not r["ok"]), "results": results}
