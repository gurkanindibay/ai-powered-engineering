"""Explainable risk floors and capability-validated, provider-neutral routing."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
import re
from typing import Any

TIERS = ("low", "medium", "high", "critical")
ROLES = ("coordinator", "product_owner", "business_analyst", "architect", "backend_developer",
         "frontend_developer", "developer", "tester")
PROMPTS = {
    "coordinator": "Act as the engineering manager for this run. Turn the accepted objective and criteria into an ordered work plan for the specialist agents in this harness; identify dependencies, handoff needs, integration checkpoints and escalation risks. Keep work within the existing stage plan and accepted scope. Do not implement code, change criteria, or claim to dispatch agents or change the controller DAG. The harness owns dispatch, status tracking, integration and verification.",
    "product_owner": "Define scope, exclusions and measurable acceptance criteria. Report unresolved business decisions.",
    "business_analyst": "Define domain rules, edge cases, versioned API/schema contracts and error semantics. Respect accepted scope.",
    "architect": "Review architecture, security, persistence and concurrency risks. Specify compatibility and migration strategy.",
    "backend_developer": "Implement the accepted contract with focused regression tests, decimal money arithmetic and persistence safety.",
    "frontend_developer": "Implement UI state, loading/error/empty behavior, accessibility and responsive layouts. Reuse the design system.",
    "developer": "Implement the bounded task with focused regression tests and existing shared components.",
    "tester": "Independently verify every acceptance criterion on this candidate. Report defects and residual risk. Do not weaken checks. Where the policy lets you write, express each criterion as a Gherkin scenario with a stable id and bind its steps; never mark an automated scenario pending and never write a test run record yourself.",
}


class HarnessError(ValueError):
    """An actionable configuration, policy or lifecycle error."""


class QuotaParkedError(HarnessError):
    """All qualified healthy providers are exhausted; run must park awaiting quota reset."""
    def __init__(self, message: str, resume_after: str | None = None, exhausted_providers: list[str] | None = None):
        super().__init__(message)
        self.status = "PARKED_AWAITING_QUOTA"
        self.resume_after = resume_after
        self.exhausted_providers = exhausted_providers or []


class BusyError(HarnessError):
    """A different controller owns this runnable unit of work."""


CANONICAL_PROVIDER_MAP = {
    "claudeagent": "claude",
    "claude": "claude",
    "codex": "codex",
    "gemini": "gemini",
    "copilot": "copilot",
}


def canonical_provider(target: dict) -> str:
    """Resolve T3/CLI target provider to canonical Track B provider key."""
    explicit = target.get("canonical_provider")
    if isinstance(explicit, str) and explicit.strip():
        return explicit.strip().lower()
    raw = str(target.get("provider", "")).strip().lower()
    if raw in CANONICAL_PROVIDER_MAP:
        return CANONICAL_PROVIDER_MAP[raw]
    if raw.startswith("claude"):
        return "claude"
    return raw


def get_provider_health_status(target: dict, health: dict | None) -> tuple[str, str | None]:
    """Return (status, reset_at) for target from Track B provider_health payload."""
    if not health or not isinstance(health, dict):
        return ("HEALTHY", None)
    providers = health.get("providers")
    if not isinstance(providers, dict):
        return ("HEALTHY", None)
    canon = canonical_provider(target)
    info = providers.get(canon)
    if not isinstance(info, dict):
        return ("HEALTHY", None)
    return (str(info.get("status", "HEALTHY")).upper(), info.get("reset_at"))


def earliest_iso_timestamp(timestamps: list[str]) -> str | None:
    """Return the earliest ISO-8601 timestamp string, parsing offsets properly."""
    if not timestamps:
        return None
    def _parse(ts: str) -> tuple[int, datetime | str]:
        try:
            dt = datetime.fromisoformat(ts.strip().replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            else:
                dt = dt.astimezone(timezone.utc)
            return (0, dt)
        except Exception:
            return (1, ts)
    return min(timestamps, key=_parse)


def money(value: Any) -> Decimal:
    """Parse nonnegative finite decimal values without binary floating point."""
    if isinstance(value, (bool, float)):
        raise HarnessError("Monetary values must be decimal strings or integers")
    try:
        result = Decimal(value)
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise HarnessError("Invalid decimal amount") from exc
    if not result.is_finite() or result < 0 or result > Decimal("1000000000000"):
        raise HarnessError("Amount must be finite, nonnegative and at most one trillion")
    return result


def positive_int(value: Any, name: str) -> int:
    if type(value) is not int or value <= 0:
        raise HarnessError(f"{name} must be a positive integer")
    return value


@dataclass(frozen=True)
class Assessment:
    tier: str
    reasons: list[str]
    policy_version: str = "risk-v1"


def assess(task: str, files_count: int | None = None, *, financial: bool = False,
           schema: bool = False, auth: bool = False, requested: str | None = None) -> Assessment:
    if not isinstance(task, str) or not task.strip():
        raise HarnessError("Task must not be empty")
    if files_count is not None and (type(files_count) is not int or files_count < 0):
        raise HarnessError("File count must be a nonnegative integer")
    if requested is not None and requested not in TIERS:
        raise HarnessError("Unknown complexity tier")
    text = task.lower()
    signals: list[tuple[str, str]] = [("low", "Bounded task; no higher-risk signal detected")]
    rules = (
        ("critical", financial, r"\b(financial|money|payment|ledger|iban|concurrency|consensus)\b|decimal precision|race condition|distributed lock|destructive (migration|persistence)|drop table", "Financial, destructive persistence or concurrency invariant"),
        ("high", schema or auth, r"\b(auth\w*|permissions?|security|encryption|jwt|migration|sensitive|cross-service)\b", "Security, persistence or cross-service boundary"),
        ("high", (files_count or 0) > 6, r"\b(refactor|multi-module|pipeline|architectur\w*)\b", "Broad change or architectural coupling"),
        ("medium", (files_count or 0) > 2, r"\b(endpoint|feature|crud|integration|api)\b|ui component", "Behavioral API/UI change or three to six files"),
    )
    for tier, explicit, pattern, reason in rules:
        if explicit or re.search(pattern, text):
            signals.append((tier, reason))
    if requested:
        signals.append((requested, f"Requested tier: {requested}; risk floors remain enforced"))
    tier = max((x[0] for x in signals), key=TIERS.index)
    return Assessment(tier, [reason for level, reason in signals if level != "low" or tier == "low"])


def select_roles(tier: str, roles: list[str] | None = None, scope: str = "fullstack") -> list[str]:
    if roles is not None:
        if not roles or len(set(roles)) != len(roles) or any(r not in ROLES for r in roles):
            raise HarnessError("Roles must be a nonempty list of unique known roles")
        return list(roles)
    if scope not in ("fullstack", "backend", "frontend", "mechanical"):
        raise HarnessError("Unknown task scope")
    if scope == "mechanical" and tier == "low":
        return ["developer", "tester"]
    developers = {"fullstack": ["backend_developer", "frontend_developer"],
                  "backend": ["backend_developer"], "frontend": ["frontend_developer"],
                  "mechanical": ["developer"]}[scope]
    return ["product_owner", "business_analyst"] + (["architect"] if tier in ("high", "critical") else []) + developers + ["tester"]


def validate_capabilities(data: dict) -> list[dict]:
    if not isinstance(data, dict) or data.get("schema_version") != 1 or not isinstance(data.get("targets"), list):
        raise HarnessError("Capabilities require schema_version=1 and targets")
    seen = set()
    for target in data["targets"]:
        if not isinstance(target, dict):
            raise HarnessError("Capability target must be an object")
        for key in ("provider", "model", "benchmark_id", "price_date"):
            if not isinstance(target.get(key), str) or not target[key].strip():
                raise HarnessError(f"Capability target requires {key}")
        try:
            date.fromisoformat(target["price_date"])
        except ValueError as exc:
            raise HarnessError("price_date must be an ISO calendar date") from exc
        identity = (target["provider"], target["model"])
        if identity in seen:
            raise HarnessError("Duplicate capability target")
        seen.add(identity)
        if not isinstance(target.get("tiers"), list) or not target["tiers"] or any(t not in TIERS for t in target["tiers"]):
            raise HarnessError("Invalid capability tiers")
        if not isinstance(target.get("roles"), list) or not target["roles"] or any(r not in ROLES for r in target["roles"]):
            raise HarnessError("Invalid capability roles")
        if not isinstance(target.get("options", {}), dict) or any(not isinstance(v, list) or not v for v in target.get("options", {}).values()):
            raise HarnessError("Supported options must map names to nonempty allowed-value lists")
        positive_int(target.get("max_tokens"), "max_tokens")
        if "priority" in target:
            positive_int(target["priority"], "priority")
        money(target.get("input_per_million"))
        money(target.get("output_per_million"))
    return data["targets"]


def route(capabilities: dict, role: str, tier: str, preference: dict | None = None, *, health: dict | None = None) -> dict:
    """Select the lowest-cost qualified target matching role, tier, and Track B provider health.

    Priority-1 subscription pools (even if THROTTLED) are always exhausted before
    spilling over to Priority-2 paid/overflow pools (even if HEALTHY). Within the
    active priority tier, HEALTHY targets strictly beat THROTTLED ones.
    """
    if role not in ROLES or tier not in TIERS:
        raise HarnessError("Unknown routing role or tier")
    preference = preference or {}
    if set(preference) - {"provider", "model", "options"}:
        raise HarnessError("Unknown target preference fields")
    candidates = [t for t in validate_capabilities(capabilities)
                  if role in t["roles"] and tier in t["tiers"]
                  and all(t.get(k) == preference[k] for k in ("provider", "model") if k in preference)]
    options = preference.get("options", {})
    if not isinstance(options, dict):
        raise HarnessError("Target options must be an object")
    candidates = [t for t in candidates if all(k in t.get("options", {}) and v in t["options"][k] for k, v in options.items())]
    if not candidates:
        raise HarnessError(f"No eligible available target for {role}/{tier}; requested target/options will not be substituted")

    healthy_or_throttled: list[tuple[dict, str]] = []
    exhausted_resets: list[str] = []
    exhausted_providers: list[str] = []
    for t in candidates:
        p_status, reset_at = get_provider_health_status(t, health)
        if p_status == "EXHAUSTED":
            exhausted_providers.append(canonical_provider(t))
            if reset_at:
                exhausted_resets.append(reset_at)
        else:
            healthy_or_throttled.append((t, p_status))

    if not healthy_or_throttled:
        resume_after = earliest_iso_timestamp(exhausted_resets)
        raise QuotaParkedError(
            f"PARKED_AWAITING_QUOTA: All qualified targets for {role}/{tier} are exhausted ({sorted(set(exhausted_providers))})",
            resume_after=resume_after,
            exhausted_providers=sorted(set(exhausted_providers)),
        )

    # Priority 1: weekly-limited subscription pools first; Priority 2: budget-capped DeepSeek overflow only when P1 exhausted
    p1 = [pair for pair in healthy_or_throttled if int(pair[0].get("priority", 1)) == 1]
    p2 = [pair for pair in healthy_or_throttled if int(pair[0].get("priority", 1)) > 1]
    pool = p1 if p1 else p2

    selected, _ = min(
        pool,
        key=lambda pair: (
            0 if pair[1] == "HEALTHY" else 1,
            int(pair[0].get("priority", 1)),
            money(pair[0]["input_per_million"]) + money(pair[0]["output_per_million"]),
            pair[0]["provider"],
            pair[0]["model"],
        ),
    )
    return {**selected, "selected_options": options}


def plan(task: str, *, capabilities: dict | None = None, roles: list[str] | None = None,
         scope: str = "fullstack", preferences: dict | None = None, health: dict | None = None, **risk: Any) -> dict:
    assessment = assess(task, **risk)
    stages = []
    previous = []
    try:
        for index, role in enumerate(select_roles(assessment.tier, roles, scope), 1):
            task_id = f"stage-{index:02d}"
            target = route(capabilities, role, assessment.tier, (preferences or {}).get(role), health=health) if capabilities is not None else None
            stages.append({"id": task_id, "role": role, "depends_on": previous,
                           "instruction": PROMPTS[role], "target": target})
            previous = [task_id]
    except QuotaParkedError as exc:
        return {
            "schema_version": 1,
            "task": task.strip(),
            "complexity": assessment.tier,
            "assessment": asdict(assessment),
            "stages": stages,
            "execution_ready": False,
            "status": "PARKED_AWAITING_QUOTA",
            "resume_after": exc.resume_after,
            "exhausted_providers": exc.exhausted_providers,
        }
    return {"schema_version": 1, "task": task.strip(), "complexity": assessment.tier,
            "assessment": asdict(assessment), "stages": stages,
            "execution_ready": capabilities is not None}
