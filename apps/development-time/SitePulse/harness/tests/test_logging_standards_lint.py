"""Self-tests for scripts/logging_standards_lint.py."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "logging_standards_lint.py"
spec = importlib.util.spec_from_file_location("logging_standards_lint", SCRIPT)
logging_standards_lint = importlib.util.module_from_spec(spec)
sys.modules["logging_standards_lint"] = logging_standards_lint
spec.loader.exec_module(logging_standards_lint)


def _lint(backend_files: dict[str, str] | None = None, flutter_files: dict[str, str] | None = None, baseline: dict | None = None) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        backend = Path(tmp) / "backend"
        flutter = Path(tmp) / "flutter"
        if backend_files:
            for rel, source in backend_files.items():
                p = backend / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(source, encoding="utf-8")
        if flutter_files:
            for rel, source in flutter_files.items():
                p = flutter / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(source, encoding="utf-8")
        base = None
        if baseline is not None:
            base = Path(tmp) / "baseline.json"
            base.write_text(json.dumps(baseline), encoding="utf-8")
        return logging_standards_lint.lint(backend, flutter, base)


def _rules(report: dict) -> list[str]:
    return sorted(f["rule"] for f in report["findings"])


class LoggingStandardsLintTests(unittest.TestCase):
    def test_println_and_dbg_are_reported_in_backend(self):
        report = _lint(backend_files={
            "src/service.rs": "fn run() { println!(\"debug\"); eprintln!(\"err\"); dbg!(42); }\n",
        })
        self.assertEqual(_rules(report), ["no-println", "no-println", "no-println"])

    def test_println_is_allowed_in_bin_and_cfg_test(self):
        report = _lint(backend_files={
            "src/bin/tool.rs": "fn main() { println!(\"CLI output\"); }\n",
            "src/lib.rs": "#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() { println!(\"test log\"); }\n}\n",
        })
        self.assertEqual(_rules(report), [])

    def test_raw_print_is_reported_in_flutter(self):
        report = _lint(flutter_files={
            "lib/ui/widget.dart": "void render() { print('hello'); }\n",
        })
        self.assertEqual(_rules(report), ["no-raw-print"])

    def test_sensitive_logging_is_reported(self):
        report = _lint(
            backend_files={
                "src/auth.rs": "fn log_in() { tracing::error!(password = %pwd, \"Login failed\"); }\n",
            },
            flutter_files={
                "lib/service.dart": "void auth() { AppLogger.error('Failed with $password'); }\n",
            },
        )
        self.assertEqual(_rules(report), ["no-sensitive-log", "no-sensitive-log"])

    def test_debug_print_ratchet_tracks_counts(self):
        report = _lint(
            flutter_files={
                "lib/a.dart": "void f() { debugPrint('err'); debugPrint('err2'); }\n",
            },
            baseline={"raw-debug-print": 1},
        )
        self.assertEqual(report["counts"]["raw-debug-print"], 2)
        self.assertEqual(len(report["ratchet_exceeded"]), 1)
        self.assertEqual(report["ratchet_exceeded"][0]["rule"], "raw-debug-print")

    def test_real_workspace_passes(self):
        backend = Path(__file__).resolve().parents[2] / "backend"
        flutter = Path(__file__).resolve().parents[2] / "flutter"
        baseline = Path(__file__).resolve().parents[2] / "scripts" / "logging_standards_baseline.json"
        report = logging_standards_lint.lint(backend, flutter, baseline)
        self.assertEqual(report["findings"], [], json.dumps(report["findings"], indent=2))
        self.assertEqual(report["ratchet_exceeded"], [], json.dumps(report["ratchet_exceeded"], indent=2))
        self.assertTrue(report["passed"])


if __name__ == "__main__":
    unittest.main()
