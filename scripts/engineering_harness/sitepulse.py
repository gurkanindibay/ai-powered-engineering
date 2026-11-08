"""Read-only integration with the existing SitePulse gate catalogue and CLI."""
from .contracts import validate_policy
from .routing import ROLES


def policy_for_sitepulse(image: str) -> dict:
    root = "apps/development-time/SitePulse"
    paths = {role: [] for role in ROLES}
    paths.update(backend_developer=[f"{root}/backend/src", f"{root}/backend/tests"],
                 frontend_developer=[f"{root}/flutter/lib", f"{root}/flutter/test"],
                 developer=[f"{root}/backend/src", f"{root}/flutter/lib"])
    return validate_policy({
        "schema_version": 1, "image": image, "bridge": ["engineering-agent-bridge"], "network": "none",
        "limits": {"tokens": 200000, "attempt_tokens": 20000, "cost": "20.00", "seconds": 14400,
                   "attempt_seconds": 900, "max_repairs": 3, "memory_mb": 4096, "cpus": 2,
                   "pids": 256, "output_bytes": 1048576},
        "role_paths": paths,
        "protected_paths": [".github", ".agents", "scripts", "config", f"{root}/harness", f"{root}/scripts", f"{root}/.specify"],
        "preferences": {},
        "gates": [{"id": "sitepulse-selftests", "argv": ["python3", "-m", "unittest", "discover", "-s", "harness/tests"],
                   "cwd": root, "timeout": 300, "test_pattern": r"Ran (?P<count>\d+) tests?"},
                  {"id": "sitepulse-full", "argv": ["python3", "scripts/run_tests.py"],
                   "cwd": root, "timeout": 10800, "test_pattern": None}],
        "acceptance": {"Existing SitePulse regression and invariant gates pass": ["sitepulse-selftests", "sitepulse-full"]},
    })
