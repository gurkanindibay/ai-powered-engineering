import unittest

from scripts.engineering_harness.contracts import validate_policy
from scripts.engineering_harness.routing import HarnessError, assess, money, plan, route, select_roles
from scripts.team_orchestrator import build_iteration_pipeline
from support import capabilities, policy


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

    def test_money_rejects_binary_nonfinite_and_negative(self):
        for value in [0.1, "NaN", "Infinity", "-1", True, None]:
            with self.assertRaises(HarnessError):
                money(value)
