#!/usr/bin/env python3
"""
Team Orchestration & Model Selection Matrix for T3 Multi-Agent Workflows.

Defines 4 specialized software engineering roles:
  1. Product Owner (PO)
  2. Architect
  3. Developer
  4. Tester

Dynamically selects the optimal provider, model, reasoning effort, and workspace isolation
based on the iteration's complexity level (low, medium, high, critical).
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional


@dataclass
class ModelTarget:
    providerInstanceId: str
    model: str
    options: Dict[str, Any]
    isolation: str  # 'shared' or 'worktree'
    role: str       # 'implementation', 'research', 'review', 'design', 'test', 'general'
    rationale: str


# Complexity Level Definitions & Thresholds
# low: Minor bugfix, typo, doc tweak, single-file trivial change.
# medium: Standard CRUD feature, new API endpoint, routine refactoring.
# high: Multi-module integration, database migration, concurrency, auth/security boundary.
# critical: Core architectural shift, financial calculation invariants, consensus/protocol.

ROLE_MODEL_MATRIX: Dict[str, Dict[str, ModelTarget]] = {
    "product_owner": {
        "low": ModelTarget(
            providerInstanceId="antigravity",
            model="gemini-3.8-flash",
            options={"thinking_level": "low"},
            isolation="shared",
            role="general",
            rationale="Fast, lightweight parsing of acceptance criteria for routine changes.",
        ),
        "medium": ModelTarget(
            providerInstanceId="antigravity",
            model="gemini-3.8-flash",
            options={"thinking_level": "high"},
            isolation="shared",
            role="general",
            rationale="Thorough story refinement, boundary checking, and acceptance criteria.",
        ),
        "high": ModelTarget(
            providerInstanceId="claudeAgent",
            model="claude-sonnet-5-5",
            options={"effort": "high"},
            isolation="shared",
            role="general",
            rationale="Deep domain reasoning, edge-case enumeration, and scope boundary enforcement.",
        ),
        "critical": ModelTarget(
            providerInstanceId="claudeAgent",
            model="claude-opus-5-5",
            options={"effort": "high"},
            isolation="shared",
            role="general",
            rationale="Exhaustive requirement verification, regulatory/financial risk analysis, and tradeoff evaluation.",
        ),
    },
    "architect": {
        "low": ModelTarget(
            providerInstanceId="antigravity",
            model="gemini-3.8-flash",
            options={"thinking_level": "medium"},
            isolation="shared",
            role="design",
            rationale="Quick interface sanity check and dependency validation.",
        ),
        "medium": ModelTarget(
            providerInstanceId="claudeAgent",
            model="claude-sonnet-5-5",
            options={"effort": "medium"},
            isolation="shared",
            role="design",
            rationale="Clean domain boundaries, API contracts, schema models, and component structure.",
        ),
        "high": ModelTarget(
            providerInstanceId="claudeAgent",
            model="claude-sonnet-5-5",
            options={"effort": "high", "ultracode": True},
            isolation="shared",
            role="design",
            rationale="Systemic architecture, distributed state, migration strategies, and failure modes.",
        ),
        "critical": ModelTarget(
            providerInstanceId="claudeAgent",
            model="claude-opus-5-5",
            options={"effort": "ultrathink", "ultracode": True},
            isolation="shared",
            role="design",
            rationale="Maximum reasoning depth for safety-critical protocols, concurrency models, and core invariants.",
        ),
    },
    "developer": {
        "low": ModelTarget(
            providerInstanceId="antigravity",
            model="gemini-3.8-flash",
            options={"thinking_level": "medium"},
            isolation="worktree",
            role="implementation",
            rationale="Rapid, low-latency implementation of targeted, low-risk changes.",
        ),
        "medium": ModelTarget(
            providerInstanceId="codex",
            model="gpt-6-luna",
            options={"reasoningEffort": "medium"},
            isolation="worktree",
            role="implementation",
            rationale="Standard feature implementation with robust code synthesis and typing.",
        ),
        "high": ModelTarget(
            providerInstanceId="codex",
            model="gpt-6-luna",
            options={"reasoningEffort": "high"},
            isolation="worktree",
            role="implementation",
            rationale="Advanced code generation for multi-file dependencies, async routines, and strict types.",
        ),
        "critical": ModelTarget(
            providerInstanceId="claudeAgent",
            model="claude-opus-5-5",
            options={"effort": "max", "ultracode": True},
            isolation="worktree",
            role="implementation",
            rationale="Highest precision code synthesis for mission-critical logic, zero-defect invariants, and delicate refactors.",
        ),
    },
    "tester": {
        "low": ModelTarget(
            providerInstanceId="antigravity",
            model="gemini-3.8-flash",
            options={"thinking_level": "low"},
            isolation="shared",
            role="test",
            rationale="Fast execution of existing test suites and lints.",
        ),
        "medium": ModelTarget(
            providerInstanceId="antigravity",
            model="gemini-3.8-flash",
            options={"thinking_level": "high"},
            isolation="shared",
            role="test",
            rationale="Automated test suite execution plus synthetic unit test generation for regression coverage.",
        ),
        "high": ModelTarget(
            providerInstanceId="claudeAgent",
            model="claude-sonnet-5-5",
            options={"effort": "high"},
            isolation="shared",
            role="test",
            rationale="Adversarial edge-case discovery, integration test harness generation, and boundary fuzzing.",
        ),
        "critical": ModelTarget(
            providerInstanceId="claudeAgent",
            model="claude-opus-5-5",
            options={"effort": "high"},
            isolation="shared",
            role="test",
            rationale="Exhaustive security inspection, mathematical invariant proofs, and comprehensive fault-injection testing.",
        ),
    },
}


def assess_complexity(
    task_description: str,
    files_count: Optional[int] = None,
    touches_financial: bool = False,
    touches_schema: bool = False,
    touches_auth: bool = False,
) -> str:
    """Calculates complexity based on task indicators and domain rules."""
    text_lower = task_description.lower()
    
    # Critical flags
    if touches_financial or any(kw in text_lower for kw in ["financial", "money", "payment", "iban", "decimal precision", "critical invariant"]):
        return "critical"
    if any(kw in text_lower for kw in ["concurrency", "distributed lock", "consensus", "race condition"]):
        return "critical"
        
    # High flags
    if touches_schema or touches_auth or any(kw in text_lower for kw in ["migration", "auth", "permission", "security vulnerability", "encryption", "jwt"]):
        return "high"
    if files_count is not None and files_count > 6:
        return "high"
    if any(kw in text_lower for kw in ["refactor", "multi-module", "pipeline", "architectural"]):
        return "high"
        
    # Medium flags
    if files_count is not None and files_count > 2:
        return "medium"
    if any(kw in text_lower for kw in ["endpoint", "feature", "crud", "integration", "ui component", "api"]):
        return "medium"
        
    return "low"


def build_iteration_pipeline(
    task: str,
    complexity: Optional[str] = None,
    files_count: Optional[int] = None,
    touches_financial: bool = False,
    touches_schema: bool = False,
    touches_auth: bool = False,
) -> Dict[str, Any]:
    """Generates the 4-stage pipeline with assigned models, options, and T3 delegate_task payloads."""
    resolved_complexity = complexity or assess_complexity(
        task_description=task,
        files_count=files_count,
        touches_financial=touches_financial,
        touches_schema=touches_schema,
        touches_auth=touches_auth,
    )
    
    stages = []
    role_order = [
        ("product_owner", "Product Owner", "Scope & Acceptance Criteria Definition"),
        ("architect", "Architect", "System Design & Technical Specification"),
        ("developer", "Developer", "Implementation & Code Synthesis"),
        ("tester", "Tester", "Verification, Test Execution & Review"),
    ]

    for role_key, role_title, default_stage_name in role_order:
        target = ROLE_MODEL_MATRIX[role_key][resolved_complexity]
        
        # Build delegate_task payload compliant with T3 orchestration
        delegate_payload = {
            "title": f"[{resolved_complexity.upper()}] {role_title}: {task[:60]}",
            "role": target.role,
            "isolation": target.isolation,
            "mode": "wait",
            "target": {
                "providerInstanceId": target.providerInstanceId,
                "model": target.model,
                "options": target.options,
            },
            "task": f"Act as {role_title} for the task: '{task}'. Deliverable: {default_stage_name} matching {resolved_complexity.upper()} complexity requirements.",
        }
        
        stages.append({
            "role": role_key,
            "title": role_title,
            "stage": default_stage_name,
            "model_selection": asdict(target),
            "delegate_task_payload": delegate_payload,
        })

    return {
        "task": task,
        "complexity": resolved_complexity,
        "stages": stages,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Select proper models and generate T3 multi-agent orchestration pipelines across PO, Architect, Developer, and Tester roles."
    )
    parser.add_argument("--task", type=str, required=True, help="Task description or feature user story")
    parser.add_argument("--complexity", choices=["low", "medium", "high", "critical"], help="Override complexity level")
    parser.add_argument("--files", type=int, default=None, help="Estimated number of files touched")
    parser.add_argument("--financial", action="store_true", help="Flag if task touches financial or ledger logic")
    parser.add_argument("--schema", action="store_true", help="Flag if task touches database schemas/migrations")
    parser.add_argument("--auth", action="store_true", help="Flag if task touches authentication/security boundaries")
    parser.add_argument("--json", action="store_true", help="Output raw JSON structure")

    args = parser.parse_args()

    pipeline = build_iteration_pipeline(
        task=args.task,
        complexity=args.complexity,
        files_count=args.files,
        touches_financial=args.financial,
        touches_schema=args.schema,
        touches_auth=args.auth,
    )

    if args.json:
        print(json.dumps(pipeline, indent=2))
        return

    print("=" * 72)
    print(f"Task: {pipeline['task']}")
    print(f"Resolved Complexity: {pipeline['complexity'].upper()}")
    print("=" * 72)

    for i, stage in enumerate(pipeline["stages"], 1):
        m = stage["model_selection"]
        opts = ", ".join(f"{k}={v}" for k, v in m["options"].items()) if m["options"] else "default"
        print(f"\n[Stage {i}] {stage['title']} ({stage['stage']})")
        print(f"  • Provider / Model: {m['providerInstanceId']} / {m['model']}")
        print(f"  • Options:          {opts}")
        print(f"  • Isolation:        {m['isolation']}")
        print(f"  • Rationale:        {m['rationale']}")
        print(f"  • T3 Role Target:   {m['role']}")

    print("\n" + "=" * 72)
    print("Pipeline ready for execution via T3 `delegate_task`.")


if __name__ == "__main__":
    main()
