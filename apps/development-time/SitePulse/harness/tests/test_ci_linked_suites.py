"""CI skips e2e/tests/test_linked_backend_suites.py only while other CI gates run the same suites.

The linked wrappers re-run non-browser suites so a *recorded* run can attach their results to
Gherkin scenarios. CI records nothing, so its e2e shards ignore the file (PYTEST_ADDOPTS in
.github/workflows/sitepulse-ci.yml) instead of compiling and running those suites a second
time. This test keeps that safe: every suite a wrapper runs must also be run in full by a gate
that belongs to a CI group, and a wrapper whose command is not recognised fails the test.
"""
import ast
import importlib.util
import sys
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = PROJECT_ROOT.parents[2]
LINKED = PROJECT_ROOT / "e2e" / "tests" / "test_linked_backend_suites.py"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "sitepulse-ci.yml"
IGNORE = "--ignore=tests/test_linked_backend_suites.py"


def _load_run_tests():
    spec = importlib.util.spec_from_file_location("sitepulse_run_tests_linked", PROJECT_ROOT / "scripts" / "run_tests.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


run_tests = _load_run_tests()


def _linked_commands():
    """(test name, argv) for every run_suite([...], ...) call in the linked wrappers."""
    commands = []
    for node in ast.parse(LINKED.read_text(encoding="utf-8")).body:
        if not isinstance(node, ast.FunctionDef) or not node.name.startswith("test_"):
            continue
        for call in ast.walk(node):
            if isinstance(call, ast.Call) and getattr(call.func, "id", "") == "run_suite":
                argv = [elt.value if isinstance(elt, ast.Constant) else "<python>" for elt in call.args[0].elts]
                commands.append((node.name, argv))
    return commands


def _ci_gate_argv(gate):
    in_ci = any(gate in gates for gates in run_tests.GATE_GROUPS.values())
    return in_ci, [spec.argv for spec in run_tests.GATES[gate]]


class LinkedSuitesCoveredInCi(unittest.TestCase):
    def test_every_linked_suite_also_runs_in_a_ci_gate(self):
        commands = _linked_commands()
        self.assertTrue(commands, "no run_suite calls found in test_linked_backend_suites.py")
        for name, argv in commands:
            with self.subTest(test=name, command=" ".join(argv)):
                if argv[:2] == ["cargo", "test"]:
                    # rust-test runs `cargo test --locked` with no filter: every test target.
                    target = argv[argv.index("--test") + 1]
                    self.assertTrue((PROJECT_ROOT / "backend" / "tests" / f"{target}.rs").exists())
                    gate = "rust-test"
                    expected = ["cargo", "test", "--locked"]
                elif argv[:2] == ["flutter", "test"]:
                    # flutter-test runs `flutter test` with no path: every test file.
                    self.assertTrue((PROJECT_ROOT / "flutter" / argv[2]).exists())
                    gate = "flutter-test"
                    expected = ["flutter", "test"]
                elif (argv[1:2] == ["scripts/unittest_json_runner.py"] or
                      argv[1:4] == ["-m", "unittest", "discover"]) and "harness/tests" in argv:
                    gate = "harness-selftest"
                    expected = ["python3", "scripts/unittest_json_runner.py"]
                elif argv[1:2] == ["scripts/api_system_check.py"] and "--only" not in argv:
                    gate = "api-system"
                    expected = ["python3", "scripts/api_system_check.py", "--json"]
                else:
                    self.fail(f"unrecognised linked suite {argv}: add a CI gate for it or classify it here")
                in_ci, gate_argvs = _ci_gate_argv(gate)
                self.assertTrue(in_ci, f"gate {gate} is in no CI group")
                self.assertTrue(any(command[:len(expected)] == expected for command in gate_argvs),
                                f"gate {gate} no longer runs the full suite")
                if gate == "harness-selftest":
                    self.assertIn("-s", gate_argvs[0])
                    self.assertIn("harness/tests", gate_argvs[0])

    @unittest.skipUnless(WORKFLOW.exists(), "workflow file not in this checkout")
    def test_ci_ignores_only_the_linked_file(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(IGNORE, text)
        self.assertEqual(text.count("--ignore="), 1, "CI e2e shards must not ignore other test files")


if __name__ == "__main__":
    unittest.main()
