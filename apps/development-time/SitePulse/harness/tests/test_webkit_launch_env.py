"""The WebKit soak tool must load the app with the same launch environment as the E2E suite.

``scripts/webkit_load_soak.py`` re-checks the WebKit launch workarounds by default, so its
``DEFAULT_ENV`` has to match ``WEBKIT_LAUNCH_ENV`` in ``e2e/conftest.py``. They are separate
literals (the soak tool also runs standalone inside the Playwright container), so nothing but
this test stops one from being changed without the other (issue #527).
"""
from __future__ import annotations

import ast
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
CONFTEST = PROJECT_ROOT / "e2e" / "conftest.py"
SOAK = PROJECT_ROOT / "scripts" / "webkit_load_soak.py"


def _module_dict(path: Path, name: str) -> dict[str, str]:
    """Read a module-level dict literal without importing the module (conftest is a fixture file)."""
    tree = ast.parse(path.read_text())
    for node in tree.body:
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Dict):
            continue
        if any(getattr(target, "id", None) == name for target in node.targets):
            value = ast.literal_eval(node.value)
            if not all(isinstance(item, str) for item in value.values()):
                raise AssertionError(f"{path.name}: {name} must map names to string values")
            return value
    raise AssertionError(f"{path.name}: no module-level {name} dict")


class WebkitLaunchEnvTest(unittest.TestCase):
    def setUp(self) -> None:
        self.conftest = _module_dict(CONFTEST, "WEBKIT_LAUNCH_ENV")
        self.soak = _module_dict(SOAK, "DEFAULT_ENV")

    def test_soak_default_matches_the_suite(self) -> None:
        self.assertEqual(
            self.soak, self.conftest,
            "webkit_load_soak.DEFAULT_ENV must mirror e2e/conftest.WEBKIT_LAUNCH_ENV",
        )

    def test_concurrent_jit_stays_off(self) -> None:
        # #527: with concurrent JIT on, about one load in 70 broke CanvasKit or the renderer.
        self.assertEqual(self.conftest.get("JSC_useConcurrentJIT"), "0")

    def test_cpu_rasterisation_stays_on(self) -> None:
        # #422: the GPU path crashes the page on GPU-less runners.
        self.assertEqual(self.conftest.get("WEBKIT_SKIA_ENABLE_CPU_RENDERING"), "1")

    def test_only_webkit_browsers_get_the_launch_env(self) -> None:
        # The environment exists for WebKit; Firefox and Chromium keep their own launch arguments.
        self.assertIn('if browser_name != "webkit":', CONFTEST.read_text())


if __name__ == "__main__":
    unittest.main()
