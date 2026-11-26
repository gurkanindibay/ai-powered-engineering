"""CI shards consume a matching web bundle without invoking Flutter."""

import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

STACK = Path(__file__).resolve().parents[2] / "e2e" / "support" / "stack.py"
spec = importlib.util.spec_from_file_location("sitepulse_e2e_stack", STACK)
stack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stack)


class PrebuiltWebBundleTests(unittest.TestCase):
    def test_reuses_matching_bundle_and_refuses_rebuilds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "web-e2e"
            bundle.mkdir()
            (bundle / "index.html").touch()
            (bundle / "main.dart.js").touch()
            # No Flutter inputs in this temporary checkout.
            digest = hashlib.sha256(stack.api_base().encode())
            digest.update(stack.fake_google_page().encode())
            fingerprint = digest.hexdigest()
            (bundle / ".source-fingerprint").write_text(fingerprint, encoding="utf-8")
            with (
                patch.multiple(stack, SITEPULSE=root, PREBUILT_DIR=root, WEB_BUILD=bundle),
                patch.object(stack, "os", SimpleNamespace(environ={})),
                patch.object(stack.subprocess, "run") as run,
            ):
                stack.build_web()
                with self.assertRaisesRegex(stack.SetupError, "Cannot rebuild"):
                    stack.build_web(force=True)
                (bundle / ".source-fingerprint").write_text("stale", encoding="utf-8")
                with self.assertRaisesRegex(stack.SetupError, "missing or stale"):
                    stack.build_web()
                (bundle / ".source-fingerprint").write_text(fingerprint, encoding="utf-8")
                (bundle / "index.html").unlink()
                with self.assertRaisesRegex(stack.SetupError, "missing or stale"):
                    stack.build_web()
                run.assert_not_called()
