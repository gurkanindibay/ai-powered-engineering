#!/usr/bin/env python3
"""Canonical, provider-neutral handover envelopes and deterministic WIP capture.

Implements Phase 3 (Track A) of
``apps/development-time/SitePulse/docs/engineering-process/token-aware-harness-and-handover-analysis.md``:
a schema-versioned JSON envelope (``<= 64 KiB``) that lets an incoming session
continue a task in ~2-4 KiB instead of replaying a large transcript.

Subcommands:
    capture     Build and store ``.agents/local/handovers/<issue>-<seq>.json`` and,
                when the worktree is dirty, commit the edits deterministically to
                ``wip/handover-<seq>`` (or save a ``.patch`` fallback).  No LLM call
                is involved, so a hard 429, quota cutoff or crash still checkpoints.
    validate    Check schema, checksum, size and value ranges of an envelope.
    render      Print the collapsible Markdown summary for a Draft PR comment,
                optionally posting it with ``--post-pr``.
    export-t3   Export a T3 candidate checkout onto a PR branch after the outgoing
                child was cancelled (``--child-cancelled`` is mandatory).

Usage:
    python3 scripts/handover.py capture --issue 548 --reason provider_quota_exhausted \\
        --from-provider claude --from-harness claude_code --from-model claude-sonnet-5-5 --json
    python3 scripts/handover.py validate .agents/local/handovers/548-001.json --json
    python3 scripts/handover.py render .agents/local/handovers/548-001.json --post-pr 553
    python3 scripts/handover.py export-t3 --candidate /tmp/candidate --branch feature/x \\
        --issue 548 --pr 553 --child-cancelled --from-provider codex --json

Paths listed in ``PROTECTED`` patterns (credentials, ``.env``, keys, harness local
state) are never committed, never patched and never referenced as pointers.

Exit codes: 0 ok, 1 invalid envelope or refused operation, 2 usage/git failure.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

SCHEMA_VERSION = 1
MAX_ENVELOPE_BYTES = 64 * 1024
DEFAULT_ROOT = Path(".agents/local/handovers")
COMMIT_PREFIX = "wip/handover-"
REASONS = ("context_ceiling", "quota_warning", "provider_quota_exhausted",
           "stale_lease", "tier_escalation", "manual", "crash")
RISK_TIERS = ("low", "medium", "high", "critical")
ROLES = ("coordinator", "product_owner", "business_analyst", "architect",
         "backend_developer", "frontend_developer", "developer", "tester")
VERIFICATION_STATUSES = ("passed", "failed", "unverified")
ENVELOPE_FIELDS = {"schema_version", "handover_id", "created_at", "reason", "from",
                   "target_constraints", "git_state", "progress", "decisions",
                   "key_pointers", "checksum_sha256"}
OPTIONAL_FIELDS = {"t3_context"}

# Simulated secret-looking paths. Never capture, patch or hand over these.
_SAFE_ENV_EXAMPLES = {".env.example", ".env.sample", ".env.template"}
_PROTECTED_DIRS = ("/.ssh/", "/.aws/", "/.gnupg/", "/.codex/", "/.gemini/", "/.claude/",
                   "/.agents/local/")
_SECRET_FILE = re.compile(
    r"(?i)^(\.env(\..+)?|\.netrc|credentials(\..+)?|secrets?(\..+)?|"
    r"id_(rsa|ed25519|ecdsa|dsa)(\.pub)?|.+\.(pem|key|p12|pfx|jks|keystore|kdbx|ppk))$")
_SHA = re.compile(r"^[0-9a-f]{7,40}$")
_HANDOVER_ID = re.compile(r"^ho-(\d+)-(\d{3})$")
_ISO_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

Runner = Callable[[list[str], str | None], str]


class HandoverError(ValueError):
    """Usage, git or validation failure."""


@dataclass
class WipCapture:
    """What happened to the dirty edits of a worktree during capture."""

    committed: bool = False
    sha: str | None = None
    patch: str | None = None
    pushed: bool = False
    detail: str = ""


@dataclass
class CaptureOptions:
    """Deterministic operator input; every field has a safe default."""

    issue: int
    reason: str = "manual"
    pr: int | None = None
    provider: str = "unknown"
    harness: str = "unknown"
    model: str = "unknown"
    agent_name: str | None = None
    session_id: str | None = None
    risk_tier: str = "medium"
    role: str = "developer"
    excluded_providers: list[str] = field(default_factory=list)
    completed: list[str] = field(default_factory=list)
    remaining: list[str] = field(default_factory=list)
    decisions: list[str] = field(default_factory=list)
    key_pointers: list[str] = field(default_factory=list)
    verify_command: str | None = None
    verify_status: str | None = None
    verify_summary: str | None = None
    base: str | None = None
    seq: int | None = None
    push: bool = True
    root: Path | None = None
    t3_context: dict | None = None


@dataclass
class ExportOptions:
    """Cross-transport export of a T3 candidate checkout onto a PR branch."""

    candidate: Path
    branch: str
    issue: int
    pr: int | None = None
    repo: Path | None = None
    base: str | None = None
    seq: int | None = None
    provider: str = "t3"
    harness: str = "t3"
    model: str = "unknown"
    agent_name: str | None = None
    session_id: str | None = None
    risk_tier: str = "medium"
    role: str = "developer"
    excluded_providers: list[str] = field(default_factory=list)
    completed: list[str] = field(default_factory=list)
    remaining: list[str] = field(default_factory=list)
    decisions: list[str] = field(default_factory=list)
    key_pointers: list[str] = field(default_factory=list)
    thread_id: str | None = None
    child_id: str | None = None
    child_cancelled: bool = False
    push: bool = True
    root: Path | None = None


# --------------------------------------------------------------------------- git


def _git(worktree: Path | str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    """Run git in ``worktree``; commit identity is pinned so capture never stalls."""
    command = ["git", "-c", "commit.gpgsign=false", "-c", "user.name=Handover Capture",
               "-c", "user.email=handover@localhost", *args]
    try:
        proc = subprocess.run(command, cwd=str(worktree), capture_output=True)
    except OSError as exc:
        raise HandoverError("git could not run") from exc
    if check and proc.returncode:
        detail = proc.stderr.decode(errors="replace").strip()[:300]
        raise HandoverError(f"git {args[0]} failed: {detail}")
    return proc


def _text(worktree: Path | str, *args: str) -> str:
    return _git(worktree, *args).stdout.decode(errors="replace").strip()


def repo_root(path: Path) -> Path:
    return Path(_text(path, "rev-parse", "--show-toplevel"))


def head_sha(worktree: Path) -> str:
    return _text(worktree, "rev-parse", "HEAD")


def branch_name(worktree: Path) -> str:
    name = _text(worktree, "rev-parse", "--abbrev-ref", "HEAD")
    return "" if name == "HEAD" else name


def root_commit(worktree: Path) -> str:
    """The candidate snapshot commit a T3 workspace starts from."""
    roots = _text(worktree, "rev-list", "--max-parents=0", "HEAD").splitlines()
    if not roots:
        raise HandoverError("git has no root commit to use as a handover base")
    return roots[-1]


def default_base(worktree: Path) -> str:
    """Merge base with the default branch, or the repository root commit."""
    for candidate in ("origin/master", "origin/main", "master", "main"):
        if _git(worktree, "rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}",
                check=False).returncode == 0:
            merge_base = _git(worktree, "merge-base", "HEAD", candidate, check=False)
            if merge_base.returncode == 0:
                return merge_base.stdout.decode().strip()
    return root_commit(worktree)


def changed_paths(worktree: Path) -> list[str]:
    """Tracked and untracked changed paths, sorted, relative to the worktree root."""
    tracked = _git(worktree, "diff", "--name-only", "-z", "HEAD").stdout.decode(errors="replace")
    untracked = _git(worktree, "ls-files", "--others", "--exclude-standard", "-z").stdout.decode(errors="replace")
    return sorted({path for path in (tracked + untracked).split("\x00") if path})


def is_protected(path: str) -> bool:
    """Credential-looking or harness-local paths must never leave the machine."""
    normalised = "/" + path.replace("\\", "/").strip("/") + "/"
    if any(fragment in normalised for fragment in _PROTECTED_DIRS):
        return True
    name = Path(path).name
    if name in _SAFE_ENV_EXAMPLES:
        return False
    return bool(_SECRET_FILE.match(name))


def split_paths(paths: Iterable[str]) -> tuple[list[str], list[str]]:
    """(safe, protected) split; deterministic order."""
    safe, protected = [], []
    for path in paths:
        (protected if is_protected(path) else safe).append(path)
    return safe, protected


def next_seq(root: Path, issue: int) -> int:
    pattern = re.compile(rf"^{issue}-(\d{{3}})\.json$")
    existing = [int(m.group(1)) for path in root.glob(f"{issue}-*.json")
                if (m := pattern.match(path.name))] if root.exists() else []
    seq = max(existing, default=0) + 1
    if seq > 999:
        raise HandoverError(f"issue #{issue} already has 999 handovers")
    return seq


def envelope_text(envelope: dict) -> str:
    """Readable JSON, compact canonical JSON when pretty printing would break the cap."""
    pretty = json.dumps(envelope, indent=2, sort_keys=True) + "\n"
    return pretty if len(pretty.encode()) <= MAX_ENVELOPE_BYTES else canonical(envelope) + "\n"


def _write_private(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass  # shared checkouts may already exist with different ownership
    with path.open("w", encoding="utf-8") as handle:
        handle.write(content)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


# ------------------------------------------------------------------- WIP capture


def _patch_bytes(worktree: Path, paths: list[str]) -> bytes:
    """Binary-safe patch of the given tracked and untracked paths."""
    patch = _git(worktree, "diff", "--binary", "HEAD", "--", *paths).stdout
    untracked = _git(worktree, "ls-files", "--others", "--exclude-standard", "-z").stdout.decode(
        errors="replace").split("\x00")
    for extra in (p for p in untracked if p in paths):
        patch += _git(worktree, "diff", "--no-index", "--binary", "/dev/null", extra,
                      check=False).stdout
    return patch


def commit_wip(worktree: Path, handover_root: Path, handover_id: str, seq: int, reason: str,
               paths: list[str], *, push: bool) -> WipCapture:
    """Commit exactly ``paths`` to ``wip/handover-<seq>``; fall back to a patch.

    The fallback is what makes capture crash-safe: a failing hook, a locked index
    or a read-only worktree still leaves a reviewed, replayable patch behind.
    """
    if not paths:
        return WipCapture(detail="worktree clean")
    prefix = f"{COMMIT_PREFIX}{seq:03d}"
    staged = _git(worktree, "add", "--", *paths, check=False)
    commit = None
    if staged.returncode == 0:
        # --only commits exactly these paths (index included), so a protected file that was
        # already staged before capture is never recorded in the WIP commit or pushed.
        commit = _git(worktree, "commit", "--quiet", "--only", "-m",
                      f"{prefix}: {reason} checkpoint",
                      "-m", f"Deterministic handover capture {handover_id}; "
                            "squash or drop this commit when the incoming session finishes.",
                      "--", *paths, check=False)
    if commit is None or commit.returncode:
        patch_path = handover_root / f"{handover_id}.patch"
        patch_path.parent.mkdir(parents=True, exist_ok=True)
        with patch_path.open("wb") as handle:
            handle.write(_patch_bytes(worktree, paths))
        detail = (staged.stderr or (commit.stderr if commit else b"")).decode(
            errors="replace").strip()[:200] or "commit refused"
        return WipCapture(patch=str(patch_path), detail=f"{detail}; saved patch instead")

    sha = head_sha(worktree)
    pushed = False
    detail = "committed"
    if push:
        upstream = _git(worktree, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}",
                        check=False)
        if upstream.returncode == 0:
            pushed = _git(worktree, "push", "--quiet", check=False).returncode == 0
            detail = "committed and pushed" if pushed else "committed; push failed"
        else:
            detail = "committed; no upstream to push to"
    return WipCapture(committed=True, sha=sha, pushed=pushed, detail=detail)


def complete_commits(worktree: Path, base: str) -> list[str]:
    if not base or base == head_sha(worktree):
        return []
    log = _text(worktree, "log", "--format=%h %s", "--no-merges", f"{base}..HEAD")
    return [line for line in log.splitlines()
            if line and not line.split(" ", 1)[1].startswith(COMMIT_PREFIX)][:20]


# ------------------------------------------------------------------- envelopes


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False)


def checksum(envelope: dict) -> str:
    payload = {key: value for key, value in envelope.items() if key != "checksum_sha256"}
    return hashlib.sha256(canonical(payload).encode()).hexdigest()


def envelope_bytes(envelope: dict) -> int:
    return len(canonical(envelope).encode())


def fit_envelope(envelope: dict) -> dict:
    """Trim the free-text lists until the envelope fits the 64 KiB cap."""
    lists = [(envelope["progress"], "completed"), (envelope["progress"], "remaining"),
             (envelope, "decisions"), (envelope, "key_pointers")]
    while envelope_bytes(envelope) > MAX_ENVELOPE_BYTES:
        trimmed = False
        for owner, key in lists:
            if owner[key]:
                owner[key].pop()
                trimmed = True
                break
        if not trimmed:
            raise HandoverError(
                f"handover envelope is larger than {MAX_ENVELOPE_BYTES} bytes even after trimming")
    return envelope


def _verification(options: CaptureOptions, dirty: bool) -> dict:
    if dirty:
        return {"command": options.verify_command or "git status --porcelain",
                "status": "unverified",
                "summary": "Worktree was mid-edit when captured; earlier verification is stale."}
    if options.verify_status and options.verify_status not in VERIFICATION_STATUSES:
        raise HandoverError(f"verification status must be one of {', '.join(VERIFICATION_STATUSES)}")
    if options.verify_command:
        return {"command": options.verify_command,
                "status": options.verify_status or "unverified",
                "summary": options.verify_summary or ""}
    return {"command": "git status --porcelain", "status": "unverified",
            "summary": "No test run was recorded before the handover."}


def build_envelope(worktree: Path, options: CaptureOptions, wip: WipCapture,
                   dirty: bool, protected: list[str], seq: int, base: str) -> dict:
    safe_pointers = [pointer for pointer in options.key_pointers if not is_protected(pointer)]
    key_pointers = safe_pointers or _derived_pointers(worktree, base)
    completed = list(options.completed) or complete_commits(worktree, base)
    remaining = list(options.remaining)
    if not remaining:
        remaining = ["Continue the task from this checkpoint, then run the standard gates."]
    remaining += [f"Not captured (protected path): {path}" for path in protected]
    excluded = list(options.excluded_providers)
    if not excluded and options.provider not in ("", "unknown"):
        excluded = [options.provider]
    envelope = {
        "schema_version": SCHEMA_VERSION,
        "handover_id": f"ho-{options.issue}-{seq:03d}",
        "created_at": datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "reason": options.reason,
        "from": {"provider": options.provider, "harness": options.harness,
                 "model": options.model, "agent_name": options.agent_name,
                 "session_id": options.session_id},
        "target_constraints": {"risk_tier": options.risk_tier, "role": options.role,
                               "excluded_providers": excluded},
        "git_state": {"issue": options.issue, "pr": options.pr,
                      "branch": branch_name(worktree) or "(detached)",
                      "base_sha": base, "head_sha": head_sha(worktree),
                      "wip_committed": wip.committed,
                      "worktree_path": str(worktree.resolve())},
        "progress": {"completed": completed, "remaining": remaining,
                     "last_verification": _verification(options, dirty)},
        "decisions": list(options.decisions),
        "key_pointers": key_pointers,
    }
    if options.t3_context:
        envelope["t3_context"] = dict(options.t3_context)
    envelope["checksum_sha256"] = checksum(envelope)
    fit_envelope(envelope)  # trimming changes the payload, so the checksum is recomputed
    envelope["checksum_sha256"] = checksum(envelope)
    return envelope


def _derived_pointers(worktree: Path, base: str) -> list[str]:
    """Deterministic pointers from the changed files, newest diff first."""
    diff = _git(worktree, "diff", "--name-only", f"{base}..HEAD", check=False)
    files = [line for line in diff.stdout.decode(errors="replace").splitlines() if line]
    return [f"{path} (changed in this handover)" for path in files if not is_protected(path)][:10]


def capture(worktree: Path, options: CaptureOptions) -> dict:
    """Deterministically capture a worktree into a validated envelope file."""
    if options.reason not in REASONS:
        raise HandoverError(f"reason must be one of {', '.join(REASONS)}")
    if options.risk_tier not in RISK_TIERS:
        raise HandoverError(f"risk tier must be one of {', '.join(RISK_TIERS)}")
    if options.role not in ROLES:
        raise HandoverError(f"role must be one of {', '.join(ROLES)}")
    worktree = worktree.resolve()
    root = repo_root(worktree)
    handover_root = (options.root or root / DEFAULT_ROOT).resolve()
    seq = options.seq or next_seq(handover_root, options.issue)
    target = handover_root / f"{options.issue}-{seq:03d}.json"
    if target.exists():
        raise HandoverError(f"handover envelope already exists: {target}")

    paths = changed_paths(worktree)
    safe, protected = split_paths(paths)
    handover_id = f"ho-{options.issue}-{seq:03d}"
    base = options.base or default_base(worktree)  # before the WIP commit moves the branch
    wip = commit_wip(worktree, handover_root, handover_id, seq, options.reason, safe,
                     push=options.push)
    envelope = build_envelope(worktree, options, wip, bool(paths), protected, seq, base)
    errors = validate_envelope(envelope)
    if errors:
        raise HandoverError("; ".join(errors))
    _write_private(target, envelope_text(envelope))
    return {"envelope": envelope, "path": str(target), "seq": seq, "wip": wip,
            "protected": protected}


# ------------------------------------------------------------------ validation


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise HandoverError(message)


def _validate_envelope(envelope: dict) -> None:
    _require(isinstance(envelope, dict), "envelope must be a JSON object")
    keys = set(envelope)
    _require(keys <= ENVELOPE_FIELDS | OPTIONAL_FIELDS,
             f"unknown fields: {sorted(keys - (ENVELOPE_FIELDS | OPTIONAL_FIELDS))}")
    _require(ENVELOPE_FIELDS <= keys, f"missing fields: {sorted(ENVELOPE_FIELDS - keys)}")
    _require(envelope["schema_version"] == SCHEMA_VERSION, "schema_version must be 1")
    _require(isinstance(envelope["handover_id"], str)
             and bool(_HANDOVER_ID.match(envelope["handover_id"])),
             "handover_id must look like ho-<issue>-<seq>")
    _require(isinstance(envelope["created_at"], str)
             and bool(_ISO_Z.match(envelope["created_at"])),
             "created_at must be an ISO-8601 UTC timestamp ending in Z")
    _require(envelope["reason"] in REASONS, f"reason must be one of {', '.join(REASONS)}")
    origin = envelope["from"]
    _require(isinstance(origin, dict)
             and set(origin) == {"provider", "harness", "model", "agent_name", "session_id"},
             "from must contain provider, harness, model, agent_name and session_id")
    for key in ("provider", "harness", "model"):
        _require(isinstance(origin[key], str) and origin[key].strip() != "",
                 f"from.{key} must be a nonempty string")
    for key in ("agent_name", "session_id"):
        _require(origin[key] is None or isinstance(origin[key], str),
                 f"from.{key} must be a string or null")
    constraints = envelope["target_constraints"]
    _require(isinstance(constraints, dict)
             and set(constraints) == {"risk_tier", "role", "excluded_providers"},
             "target_constraints must contain risk_tier, role and excluded_providers")
    _require(constraints["risk_tier"] in RISK_TIERS, "target_constraints.risk_tier is invalid")
    _require(constraints["role"] in ROLES, "target_constraints.role is invalid")
    _require(isinstance(constraints["excluded_providers"], list)
             and all(isinstance(p, str) and p for p in constraints["excluded_providers"]),
             "excluded_providers must be a list of provider names")
    state = envelope["git_state"]
    _require(isinstance(state, dict)
             and set(state) == {"issue", "pr", "branch", "base_sha", "head_sha",
                                "wip_committed", "worktree_path"},
             "git_state must contain issue, pr, branch, base_sha, head_sha, wip_committed and worktree_path")
    _require(type(state["issue"]) is int and state["issue"] > 0, "git_state.issue must be positive")
    _require(state["pr"] is None or (type(state["pr"]) is int and state["pr"] > 0),
             "git_state.pr must be a positive number or null")
    _require(isinstance(state["branch"], str) and state["branch"], "git_state.branch is required")
    for key in ("base_sha", "head_sha"):
        _require(isinstance(state[key], str) and bool(_SHA.match(state[key])),
                 f"git_state.{key} must be a hexadecimal commit id")
    _require(isinstance(state["wip_committed"], bool), "git_state.wip_committed must be a boolean")
    _require(state["worktree_path"] is None or isinstance(state["worktree_path"], str),
             "git_state.worktree_path must be a string or null")
    identifier = _HANDOVER_ID.match(envelope["handover_id"])
    _require(identifier is not None and int(identifier.group(1)) == state["issue"],
             "handover_id does not belong to this issue")
    progress = envelope["progress"]
    _require(isinstance(progress, dict) and set(progress) == {"completed", "remaining", "last_verification"},
             "progress must contain completed, remaining and last_verification")
    for key in ("completed", "remaining"):
        _require(isinstance(progress[key], list)
                 and all(isinstance(item, str) for item in progress[key]),
                 f"progress.{key} must be a list of strings")
    verification = progress["last_verification"]
    _require(isinstance(verification, dict)
             and set(verification) == {"command", "status", "summary"},
             "last_verification must contain command, status and summary")
    _require(isinstance(verification["command"], str) and verification["command"],
             "last_verification.command is required")
    _require(verification["status"] in VERIFICATION_STATUSES,
             f"last_verification.status must be one of {', '.join(VERIFICATION_STATUSES)}")
    _require(isinstance(verification["summary"], str), "last_verification.summary must be a string")
    for key in ("decisions", "key_pointers"):
        _require(isinstance(envelope[key], list)
                 and all(isinstance(item, str) for item in envelope[key]),
                 f"{key} must be a list of strings")
    _require(isinstance(envelope["checksum_sha256"], str), "checksum_sha256 is required")
    _require(envelope["checksum_sha256"] == checksum(envelope),
             "checksum_sha256 does not match the envelope content")
    _require(envelope_bytes(envelope) <= MAX_ENVELOPE_BYTES,
             f"envelope exceeds the {MAX_ENVELOPE_BYTES // 1024} KiB cap")
    if "t3_context" in envelope:
        _require(isinstance(envelope["t3_context"], dict), "t3_context must be an object")


def validate_envelope(envelope: dict) -> list[str]:
    """Return every validation error; an empty list means the envelope is valid."""
    try:
        _validate_envelope(envelope)
    except HandoverError as exc:
        return [str(exc)]
    return []


def validate_file(path: Path) -> tuple[dict | None, list[str]]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return None, [f"cannot read envelope: {exc}"]
    try:
        envelope = json.loads(text)
    except ValueError as exc:
        return None, [f"envelope is not valid JSON: {exc}"]
    errors = validate_envelope(envelope)
    if len(text.encode()) > MAX_ENVELOPE_BYTES:
        errors.append(f"envelope file exceeds the {MAX_ENVELOPE_BYTES // 1024} KiB cap")
    return envelope, errors


# -------------------------------------------------------------------- render


def _escape(value) -> str:
    return html.escape(str(value), quote=True)


def render(envelope: dict) -> str:
    """Collapsible Markdown summary for a Draft PR comment (never raw secrets)."""
    errors = validate_envelope(envelope)
    if errors:
        raise HandoverError("; ".join(errors))
    state = envelope["git_state"]
    origin = envelope["from"]
    verification = envelope["progress"]["last_verification"]
    target = "next healthy provider"
    lines = [
        "<details>",
        f"<summary><b>Handover {_escape(envelope['handover_id'])}</b> — "
        f"{_escape(envelope['reason'])} ({_escape(origin['provider'])} → {target})</summary>",
        "",
        f"- **Issue / PR**: #{state['issue']}"
        + (f" / #{state['pr']}" if state["pr"] else ""),
        f"- **Branch**: `{_escape(state['branch'])}` "
        f"(`{_escape(str(state['base_sha'])[:7])}` → `{_escape(str(state['head_sha'])[:7])}`, "
        f"WIP commit: {'yes' if state['wip_committed'] else 'no'})",
        f"- **From**: {_escape(origin['harness'])} / `{_escape(origin['model'])}`"
        + (f" as {_escape(origin['agent_name'])}" if origin["agent_name"] else ""),
        f"- **Target constraints**: tier `{_escape(envelope['target_constraints']['risk_tier'])}`, "
        f"role `{_escape(envelope['target_constraints']['role'])}`"
        + (f", excluded: {_escape(', '.join(envelope['target_constraints']['excluded_providers']))}"
           if envelope["target_constraints"]["excluded_providers"] else ""),
        f"- **Created**: {_escape(envelope['created_at'])}",
        "",
        "### Completed",
        *([f"- {_escape(item)}" for item in envelope["progress"]["completed"]] or ["- _none recorded_"]),
        "",
        "### Remaining",
        *([f"- {_escape(item)}" for item in envelope["progress"]["remaining"]] or ["- _none recorded_"]),
        "",
        f"**Last verification** ({_escape(verification['status'])}): "
        f"`{_escape(verification['command'])}`"
        + (f" — {_escape(verification['summary'])}" if verification["summary"] else ""),
    ]
    if envelope["decisions"]:
        lines += ["", "### Decisions", *[f"- {_escape(item)}" for item in envelope["decisions"]]]
    if envelope["key_pointers"]:
        lines += ["", "### Key pointers", *[f"- `{_escape(item)}`" for item in envelope["key_pointers"]]]
    lines += ["", "</details>"]
    body = "\n".join(lines) + "\n"
    if len(body) > MAX_ENVELOPE_BYTES:
        body = body[:MAX_ENVELOPE_BYTES - 40].rstrip() + "\n\n_(summary truncated)_\n</details>\n"
    return body


# ----------------------------------------------------------------- export-t3


def _branch_checked_out(repo: Path, branch: str) -> str | None:
    """Worktree path that has ``branch`` checked out, if any."""
    for block in _text(repo, "worktree", "list", "--porcelain").split("\n\n"):
        fields = dict(line.split(" ", 1) for line in block.splitlines() if " " in line)
        if fields.get("branch") == f"refs/heads/{branch}":
            return fields.get("worktree")
    return None


def _resolve_branch(repo: Path, branch: str) -> str:
    for candidate in (f"refs/heads/{branch}", f"refs/remotes/origin/{branch}"):
        if _git(repo, "rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}",
                check=False).returncode == 0:
            return candidate
    raise HandoverError(f"PR branch {branch} does not exist; push the draft branch first")


def export_t3(options: ExportOptions) -> dict:
    """Export a cancelled T3 candidate checkout onto a PR branch, deterministically.

    Refuses until the caller confirms ``task_cancel`` terminated the outgoing
    child: exporting while it may still write would race the WIP capture.
    """
    if not options.child_cancelled:
        raise HandoverError(
            "refusing to export a T3 candidate before task_cancel confirms the child terminated; "
            "pass --child-cancelled only after the child is stopped")
    candidate = options.candidate.resolve()
    repo = (options.repo or Path.cwd()).resolve()
    repo = Path(_text(repo, "rev-parse", "--show-toplevel"))
    source_commit = _text(repo, "rev-parse", _resolve_branch(repo, options.branch))
    if candidate == repo:
        raise HandoverError("the T3 candidate must be a separate checkout, not the PR repository")

    # 1. Capture the candidate deterministically: commit exactly the safe changes.
    handover_root = (options.root or repo / DEFAULT_ROOT).resolve()
    seq = options.seq or next_seq(handover_root, options.issue)
    handover_id = f"ho-{options.issue}-{seq:03d}"
    source = options.base or root_commit(candidate)  # the snapshot the T3 workspace started from
    candidate_paths = changed_paths(candidate)
    safe, protected = split_paths(candidate_paths)
    wip = commit_wip(candidate, handover_root, handover_id, seq, "manual", safe,
                     push=False)
    if wip.patch:
        raise HandoverError(f"T3 candidate could not be committed ({wip.detail}); inspect the patch")
    candidate_head = head_sha(candidate)

    # 2. Turn the candidate work into one patch relative to its source revision. The diff is
    #    filtered by the same credential boundary as capture: a protected file the child
    #    committed itself must never reach the PR branch.
    diff_paths = [path for path in _text(candidate, "diff", "--name-only",
                                         f"{source}..{candidate_head}").splitlines() if path]
    leaked = [path for path in diff_paths if is_protected(path)]
    if leaked:
        raise HandoverError("T3 candidate history contains protected paths and cannot be exported: "
                            + ", ".join(leaked))
    safe_diff = [path for path in diff_paths if not is_protected(path)]
    patch = (_git(candidate, "diff", "--binary", f"{source}..{candidate_head}", "--",
                  *safe_diff).stdout if safe_diff else b"")
    if safe and not patch:
        raise HandoverError("T3 candidate has changes but the diff is empty")

    # 3. Apply the patch on the PR branch in a detached temporary worktree, which
    #    may coexist with the branch checked out in the operator's own worktree.
    with tempfile.TemporaryDirectory(prefix="handover-export-") as temporary:
        worktree = Path(temporary) / "pr"
        _git(repo, "worktree", "add", "--detach", "--quiet", str(worktree), source_commit)
        try:
            if patch:
                apply = subprocess.run(
                    ["git", "-c", "commit.gpgsign=false", "apply", "--binary", "--index", "-"],
                    cwd=str(worktree), input=patch, capture_output=True)
                if apply.returncode:
                    raise HandoverError(
                        "cannot apply the T3 candidate patch to the PR branch: "
                        f"{apply.stderr.decode(errors='replace').strip()[:300]}")
                _git(worktree, "commit", "--quiet", "-m",
                     f"{COMMIT_PREFIX}{seq:03d}: export T3 candidate {candidate_head[:7]}",
                     "-m", f"Deterministic cross-transport export {handover_id}.")
            exported_head = head_sha(worktree)
            pushed = False
            if exported_head == _text(repo, "rev-parse", source_commit):
                pass  # nothing was exported, so the PR branch already holds the candidate state
            elif options.push:
                remote_branch = f"refs/remotes/origin/{options.branch}"
                if _git(repo, "rev-parse", "--verify", "--quiet", f"{remote_branch}^{{commit}}",
                        check=False).returncode == 0:
                    pushed = _git(worktree, "push", "--quiet", "origin",
                                  f"HEAD:refs/heads/{options.branch}", check=False).returncode == 0
                    if not pushed:
                        raise HandoverError(
                            f"cannot push the exported branch to origin/{options.branch}; "
                            "resolve the remote state and retry")
                else:
                    raise HandoverError(
                        f"origin/{options.branch} does not exist; pass --no-push for a local export")
            else:
                checked_out = _branch_checked_out(repo, options.branch)
                if checked_out:
                    raise HandoverError(
                        f"{options.branch} is checked out at {checked_out}; push the export to origin "
                        "instead of moving a live branch under that worktree")
                _git(repo, "update-ref", f"refs/heads/{options.branch}", exported_head)
        finally:
            _git(repo, "worktree", "remove", "--force", str(worktree), check=False)
            _git(repo, "worktree", "prune", check=False)

    # The envelope describes the PR branch, not the candidate: its base is the branch
    # commit the export applied onto. Using the candidate's root here would make
    # git log/diff run against a commit the PR repository does not contain.
    completed = options.completed or [
        f"Exported the T3 candidate snapshot {candidate_head[:7]} onto {options.branch}"]
    pointers = options.key_pointers or [
        f"{path} (exported from T3 candidate)" for path in safe_diff[:10]
    ] or ["No file changed in this export"]
    capture_options = CaptureOptions(
        issue=options.issue, pr=options.pr, reason="manual", provider=options.provider,
        harness=options.harness, model=options.model, agent_name=options.agent_name,
        session_id=options.session_id, risk_tier=options.risk_tier, role=options.role,
        excluded_providers=options.excluded_providers,
        completed=completed, remaining=options.remaining, decisions=options.decisions,
        key_pointers=pointers, base=source_commit, seq=seq, push=False, root=handover_root,
        t3_context={"thread_id": options.thread_id, "child_id": options.child_id,
                    "candidate": str(candidate), "exported_head": exported_head,
                    "child_cancelled": True})
    wip = WipCapture(committed=exported_head != source_commit, sha=exported_head,
                     pushed=pushed, detail="exported" if pushed else "exported locally")
    envelope = build_envelope(repo, capture_options, wip, bool(candidate_paths), protected, seq,
                              source_commit)
    envelope["git_state"].update({"branch": options.branch, "head_sha": exported_head})
    envelope["checksum_sha256"] = checksum(envelope)
    fit_envelope(envelope)
    envelope["checksum_sha256"] = checksum(envelope)
    errors = validate_envelope(envelope)
    if errors:
        raise HandoverError("; ".join(errors))
    target = handover_root / f"{options.issue}-{seq:03d}.json"
    _write_private(target, envelope_text(envelope))
    return {"envelope": envelope, "path": str(target), "branch": options.branch,
            "head_sha": exported_head, "pushed": pushed, "protected": protected}


# ------------------------------------------------------------------------ CLI


def gh(args: list[str], stdin: str | None = None) -> str:
    try:
        proc = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        raise HandoverError("gh CLI not found") from exc
    if proc.returncode:
        detail = f"{proc.stderr.strip()} {proc.stdout.strip()}".strip()
        raise HandoverError(f"gh {' '.join(args[:2])} failed: {detail[:300]}")
    return proc.stdout


def post_comment(runner: Runner, pr: int, body: str) -> str:
    return runner(["pr", "comment", str(pr), "--body-file", "-"], body)


def _add_capture_arguments(parser: argparse.ArgumentParser,
                           base_help: str = "base revision (default: merge base with the default branch)") -> None:
    parser.add_argument("--issue", type=int, required=True, help="issue number this handover belongs to")
    parser.add_argument("--pr", type=int, help="draft PR that carries the branch")
    parser.add_argument("--reason", default="manual", choices=REASONS)
    parser.add_argument("--from-provider", default="unknown", help="outgoing provider (claude, codex, gemini, copilot, t3)")
    parser.add_argument("--from-harness", default="unknown", help="outgoing harness (claude_code, codex_cli, antigravity, t3, ...)")
    parser.add_argument("--from-model", default="unknown", help="outgoing model id")
    parser.add_argument("--from-agent", help="outgoing agent name from agent_names.py")
    parser.add_argument("--from-session", help="outgoing harness session id")
    parser.add_argument("--risk-tier", default="medium", choices=RISK_TIERS)
    parser.add_argument("--role", default="developer", choices=ROLES)
    parser.add_argument("--exclude-provider", action="append", default=[], dest="excluded_providers")
    parser.add_argument("--completed", action="append", default=[], help="completed step (repeatable)")
    parser.add_argument("--remaining", action="append", default=[], help="remaining step (repeatable)")
    parser.add_argument("--decision", action="append", default=[], dest="decisions")
    parser.add_argument("--key-pointer", action="append", default=[], dest="key_pointers")
    parser.add_argument("--verify-command", help="last verification command")
    parser.add_argument("--verify-status", choices=VERIFICATION_STATUSES)
    parser.add_argument("--verify-summary", help="last verification summary")
    parser.add_argument("--base", help=base_help)
    parser.add_argument("--seq", type=int, help="handover sequence (default: next free for the issue)")
    parser.add_argument("--root", type=Path, help="envelope directory (default: .agents/local/handovers)")
    parser.add_argument("--no-push", action="store_true", help="do not push the WIP commit")


def _capture_options(args: argparse.Namespace) -> CaptureOptions:
    return CaptureOptions(
        issue=args.issue, pr=args.pr, reason=args.reason, provider=args.from_provider,
        harness=args.from_harness, model=args.from_model, agent_name=args.from_agent,
        session_id=args.from_session, risk_tier=args.risk_tier, role=args.role,
        excluded_providers=list(args.excluded_providers), completed=list(args.completed),
        remaining=list(args.remaining), decisions=list(args.decisions),
        key_pointers=list(args.key_pointers), verify_command=args.verify_command,
        verify_status=args.verify_status, verify_summary=args.verify_summary, base=args.base,
        seq=args.seq, push=not args.no_push, root=args.root)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    subparsers = parser.add_subparsers(dest="action", required=True)

    capture_parser = subparsers.add_parser("capture", help="deterministic checkpoint and envelope")
    capture_parser.add_argument("--json", action="store_true", help="machine-readable output")
    _add_capture_arguments(capture_parser)
    capture_parser.add_argument("--worktree", type=Path, default=Path("."),
                                help="worktree to capture (default: current directory)")
    capture_parser.add_argument("--post-pr", type=int,
                                help="post the rendered summary to this draft PR (gh)")

    validate_parser = subparsers.add_parser("validate", help="validate an envelope file")
    validate_parser.add_argument("file", type=Path)
    validate_parser.add_argument("--json", action="store_true", help="machine-readable output")

    render_parser = subparsers.add_parser("render", help="collapsible Markdown summary")
    render_parser.add_argument("file", type=Path)
    render_parser.add_argument("--post-pr", type=int, help="post the summary to this draft PR (gh)")
    render_parser.add_argument("--json", action="store_true", help="machine-readable output")

    export_parser = subparsers.add_parser(
        "export-t3", help="export a cancelled T3 candidate onto a PR branch",
        description="Export a cancelled T3 candidate checkout onto a PR branch. The candidate is "
                    "committed deterministically first, then exported as one patch relative to "
                    "--base and pushed. Re-exporting the same candidate onto a branch that already "
                    "holds it fails (git apply refuses the duplicate); rebase or reset the branch "
                    "first. Protected paths in the candidate history are refused.")
    export_parser.add_argument("--json", action="store_true", help="machine-readable output")
    export_parser.add_argument("--candidate", type=Path, required=True, help="T3 candidate checkout")
    export_parser.add_argument("--branch", required=True, help="PR branch that receives the export")
    export_parser.add_argument("--repo", type=Path, help="repository (default: current directory)")
    export_parser.add_argument("--child-cancelled", action="store_true",
                               help="confirms task_cancel terminated the outgoing child (required)")
    export_parser.add_argument("--thread-id", help="T3 thread id of the outgoing child")
    export_parser.add_argument("--child-id", help="T3 child session id of the outgoing child")
    _add_capture_arguments(export_parser, base_help="base revision of the candidate (default: its root "
                                                    "snapshot commit)")
    return parser


def _capture(worktree: Path, options: CaptureOptions, post_pr: int | None,
             runner: Runner, as_json: bool) -> int:
    result = capture(worktree, options)
    envelope = result["envelope"]
    body = render(envelope)
    if post_pr is not None:
        post_comment(runner, post_pr, body)
        result["posted_pr"] = post_pr
    wip = result["wip"]
    summary = {"handover_id": envelope["handover_id"], "path": result["path"],
               "seq": result["seq"], "wip_committed": wip.committed, "wip_sha": wip.sha,
               "patch": wip.patch, "pushed": wip.pushed, "protected": result["protected"],
               "posted_pr": post_pr}
    if as_json:
        print(json.dumps({**summary, "ok": True, "envelope": envelope}, sort_keys=True))
    else:
        print(f"{envelope['handover_id']} written to {result['path']}")
        print(f"WIP: {wip.detail}" + (f" ({wip.sha[:7]})" if wip.sha else ""))
        if result["protected"]:
            print(f"Excluded protected paths: {', '.join(result['protected'])}")
    return 0


def main(argv: list[str] | None = None, runner: Runner = gh) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.action == "capture":
            return _capture(args.worktree, _capture_options(args), args.post_pr, runner, args.json)
        if args.action == "validate":
            envelope, errors = validate_file(args.file)
            if args.json:
                print(json.dumps({"ok": not errors, "file": str(args.file), "errors": errors}))
            elif errors:
                print("\n".join(f"error: {error}" for error in errors), file=sys.stderr)
            else:
                print(f"{args.file} is a valid {MAX_ENVELOPE_BYTES // 1024} KiB handover envelope "
                      f"({envelope['handover_id']})")
            return 0 if not errors else 1
        if args.action == "render":
            envelope, errors = validate_file(args.file)
            if errors:
                raise HandoverError("; ".join(errors))
            body = render(envelope)
            if args.post_pr is not None:
                post_comment(runner, args.post_pr, body)
                print(json.dumps({"ok": True, "posted_pr": args.post_pr}) if args.json
                      else f"summary for {envelope['handover_id']} posted to PR #{args.post_pr}")
                return 0
            print(body)
            return 0
        options = ExportOptions(
            candidate=args.candidate, branch=args.branch, issue=args.issue, pr=args.pr,
            repo=args.repo, base=args.base, seq=args.seq, provider=args.from_provider,
            harness=args.from_harness, model=args.from_model, agent_name=args.from_agent,
            session_id=args.from_session, risk_tier=args.risk_tier, role=args.role,
            excluded_providers=list(args.excluded_providers), completed=list(args.completed),
            remaining=list(args.remaining), decisions=list(args.decisions),
            key_pointers=list(args.key_pointers), thread_id=args.thread_id, child_id=args.child_id,
            child_cancelled=args.child_cancelled, push=not args.no_push, root=args.root)
        result = export_t3(options)
        summary = {"ok": True, "handover_id": result["envelope"]["handover_id"],
                   "path": result["path"], "branch": result["branch"],
                   "head_sha": result["head_sha"], "pushed": result["pushed"],
                   "protected": result["protected"]}
        if args.json:
            print(json.dumps({**summary, "envelope": result["envelope"]}, sort_keys=True))
        else:
            print(f"{result['envelope']['handover_id']} exported to {result['branch']} "
                  f"at {result['head_sha'][:7]} ({'pushed' if result['pushed'] else 'local'})")
            print(f"Envelope: {result['path']}")
        return 0
    except (HandoverError, OSError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}) if args.json else f"error: {exc}",
              file=sys.stderr)
        return 1 if isinstance(exc, HandoverError) else 2


if __name__ == "__main__":
    sys.exit(main())
