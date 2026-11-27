import json
from pathlib import Path
import unittest

from scripts.engineering_harness.contracts import validate_policy
from scripts.engineering_harness.routing import HarnessError, QuotaParkedError, assess, money, plan, route, select_roles
from scripts.team_orchestrator import build_iteration_pipeline
from support import capabilities, policy

ROOT = Path(__file__).resolve().parents[2]


class RoutingTests(unittest.TestCase):
    def test_risk_floor_cannot_be_overridden(self):
        self.assertEqual(build_iteration_pipeline("Ledger", complexity="low", touches_financial=True)["complexity"], "critical")
        self.assertEqual(assess("Authentication policy", requested="low").tier, "high")

    def test_file_boundaries(self):
        for count, tier in [(0, "low"), (2, "low"), (3, "medium"), (6, "medium"), (7, "high"), (20, "high")]:
            self.assertEqual(assess("Change", count).tier, tier)
        for invalid in [-1, True, 1.5]:
            with self.assertRaises(HarnessError):
                assess("Change", invalid)

    def test_empty_unknown_duplicate_inputs_rejected(self):
        with self.assertRaises(HarnessError):
            assess("  ")
        for roles in [[], ["unknown"], ["tester", "tester"]]:
            with self.assertRaises(HarnessError):
                plan("Change", roles=roles)

    def test_selective_roles_and_unresolved_targets(self):
        self.assertEqual(select_roles("low", scope="mechanical"), ["developer", "tester"])
        self.assertEqual(plan("Change", roles=["coordinator", "developer", "tester"])["stages"][0]["role"], "coordinator")
        output = plan("New API feature", scope="backend")
        self.assertFalse(output["execution_ready"])
        self.assertNotIn("frontend_developer", [s["role"] for s in output["stages"]])

    def test_unavailable_requested_target_never_substituted(self):
        for preference in [{"provider": "missing"}, {"model": "missing"}, {"options": {"effort": "invalid"}}]:
            with self.assertRaises(HarnessError):
                route(capabilities(), "developer", "low", preference)

    def test_eligible_lowest_decimal_cost(self):
        caps = capabilities()
        other = dict(caps["targets"][0], model="cheaper", input_per_million="0.1", output_per_million="0.2")
        caps["targets"].append(other)
        self.assertEqual(route(caps, "developer", "critical")["model"], "cheaper")
        caps["targets"][1]["tiers"] = ["low"]
        self.assertEqual(route(caps, "developer", "critical")["model"], "deterministic")

    def test_policy_rejects_escapes_unpinned_images_and_vacuous_tests(self):
        for mutate in [lambda p: p.update(image="python:latest"),
                       lambda p: p["role_paths"].update(developer=["../escape"]),
                       lambda p: p["role_paths"].update(developer=[".git"]),
                       lambda p: p["gates"][0].update(test_pattern=None),
                       lambda p: p["acceptance"].update(criterion=["missing"])]:
            p = policy()
            mutate(p)
            with self.assertRaises(HarnessError):
                validate_policy(p)

    def test_policy_defaults_missing_coordinator_path_for_older_policies(self):
        value = policy()
        del value["role_paths"]["coordinator"]
        validated = validate_policy(value)
        self.assertEqual(validated["role_paths"]["coordinator"], [])

    def test_money_rejects_binary_nonfinite_and_negative(self):
        for value in [0.1, "NaN", "Infinity", "-1", True, None]:
            with self.assertRaises(HarnessError):
                money(value)

    def test_health_intersection_prefers_healthy_over_throttled(self):
        registry = json.loads((ROOT / "config" / "engineering-harness" / "t3-registry.json").read_text())
        health = {
            "status": "THROTTLED",
            "providers": {
                "claude": {"status": "THROTTLED"},
                "codex": {"status": "HEALTHY"},
                "gemini": {"status": "HEALTHY"},
                "copilot": {"status": "HEALTHY"},
            },
        }
        # Claude is cheaper, but THROTTLED; healthy Priority-1 Gemini/Codex wins
        chosen = route(registry, "developer", "low", health=health)
        self.assertNotEqual(chosen["provider"], "claudeAgent")
        self.assertEqual(chosen["provider"], "gemini")

    def test_priority_1_exhausted_spills_to_deepseek_overflow(self):
        registry = json.loads((ROOT / "config" / "engineering-harness" / "t3-registry.json").read_text())
        # Even though deepseek-chat is cheapest (0.14+0.28), healthy P1 wins when P1 is available
        healthy_all = {
            "status": "HEALTHY",
            "providers": {
                "claude": {"status": "HEALTHY"},
                "codex": {"status": "HEALTHY"},
                "gemini": {"status": "HEALTHY"},
                "copilot": {"status": "HEALTHY"},
            },
        }
        chosen_p1 = route(registry, "developer", "medium", health=healthy_all)
        self.assertEqual(chosen_p1["priority"], 1)
        self.assertNotEqual(chosen_p1["provider"], "copilot")

        # When all Priority-1 subscription pools are EXHAUSTED, Priority-2 DeepSeek-on-Copilot CLI is used
        p1_exhausted = {
            "status": "EXHAUSTED",
            "providers": {
                "claude": {"status": "EXHAUSTED", "reset_at": "2026-11-28T00:00:00+00:00"},
                "codex": {"status": "EXHAUSTED", "reset_at": "2026-11-28T01:00:00+00:00"},
                "gemini": {"status": "EXHAUSTED", "reset_at": "2026-11-28T02:00:00+00:00"},
                "copilot": {"status": "HEALTHY"},
            },
        }
        overflow = route(registry, "developer", "medium", health=p1_exhausted)
        self.assertEqual(overflow["provider"], "copilot")
        self.assertEqual(overflow["model"], "deepseek-chat")
        self.assertEqual(overflow["priority"], 2)

    def test_strict_risk_floor_never_downgrades_on_exhaustion(self):
        registry = json.loads((ROOT / "config" / "engineering-harness" / "t3-registry.json").read_text())
        # P1 exhausted, Copilot DeepSeek healthy (qualified only for low/medium)
        p1_exhausted = {
            "status": "EXHAUSTED",
            "providers": {
                "claude": {"status": "EXHAUSTED", "reset_at": "2026-11-28T04:00:00+00:00"},
                "codex": {"status": "EXHAUSTED", "reset_at": "2026-11-28T02:00:00+00:00"},
                "gemini": {"status": "EXHAUSTED", "reset_at": "2026-11-28T05:00:00+00:00"},
                "copilot": {"status": "HEALTHY"},
            },
        }
        # High/critical tasks must NEVER downgrade to DeepSeek or low-tier models; must park with earliest reset_at
        with self.assertRaises(QuotaParkedError) as ctx:
            route(registry, "architect", "critical", health=p1_exhausted)
        self.assertEqual(ctx.exception.status, "PARKED_AWAITING_QUOTA")
        self.assertEqual(ctx.exception.resume_after, "2026-11-28T02:00:00+00:00")

        # plan() must return PARKED_AWAITING_QUOTA without downgrading tier
        parked_plan = plan("Ledger payment reconciliation", capabilities=registry, health=p1_exhausted, financial=True)
        self.assertEqual(parked_plan["complexity"], "critical")
        self.assertFalse(parked_plan["execution_ready"])
        self.assertEqual(parked_plan["status"], "PARKED_AWAITING_QUOTA")
        self.assertEqual(parked_plan["resume_after"], "2026-11-28T02:00:00+00:00")
