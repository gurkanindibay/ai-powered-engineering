"""Read-only integration with the existing SitePulse gate catalogue and CLI."""
from .contracts import validate_policy
from .routing import ROLES

TASK_LABEL = "engineering-harness"


def policy_for_sitepulse(image: str) -> dict:
    root = "apps/development-time/SitePulse"
    paths = {role: [] for role in ROLES}
    paths.update(backend_developer=[f"{root}/backend/src", f"{root}/backend/tests"],
                 frontend_developer=[f"{root}/flutter/lib", f"{root}/flutter/test"],
                 developer=[f"{root}/backend/src", f"{root}/flutter/lib"],
                 # The tester specifies acceptance criteria as Gherkin scenarios and binds them to steps.
                 tester=[f"{root}/.specify/features", f"{root}/e2e/steps", f"{root}/e2e/tests"])
    specify = f"{root}/.specify"
    return validate_policy({
        "schema_version": 1, "image": image, "bridge": ["engineering-agent-bridge"], "network": "none",
        "limits": {"tokens": 200000, "attempt_tokens": 20000, "cost": "20.00", "seconds": 14400,
                   "attempt_seconds": 900, "max_repairs": 3, "memory_mb": 4096, "cpus": 2,
                   "pids": 256, "output_bytes": 1048576},
        "role_paths": paths,
        # Everything under .specify except features/ stays protected. In particular no worker may
        # write executions/: run records come only from gate runs, through the capture below.
        "protected_paths": [".github", ".agents", "scripts", "config", f"{root}/harness", f"{root}/scripts",
                            *(f"{specify}/{name}" for name in ("requirements", "specs", "tasks", "agents", "reports",
                                                               "constitution.md", "evidence", "executions")),
                            f"{root}/e2e/support", f"{root}/e2e/pages", f"{root}/e2e/conftest.py", f"{root}/e2e/pytest.ini"],
        "preferences": {},
        "gates": [{"id": "sitepulse-selftests", "argv": ["python3", "-m", "unittest", "discover", "-s", "harness/tests"],
                   "cwd": root, "timeout": 300, "test_pattern": r"Ran (?P<count>\d+) tests?"},
                  # Naming the task makes the browser suite record its run (.specify/executions); the
                  # controller keeps those records in evidence, and `captures` exports them.
                  {"id": "sitepulse-full", "argv": ["env", f"SITEPULSE_TASK={TASK_LABEL}", "python3", "scripts/run_tests.py"],
                   "cwd": root, "timeout": 10800, "test_pattern": None, "captures": [f"{specify}/executions"]}],
        "acceptance": {"Existing SitePulse regression and invariant gates pass": ["sitepulse-selftests", "sitepulse-full"],
                       "Acceptance scenarios are consistent and their execution is recorded": ["sitepulse-full"]},
    })
