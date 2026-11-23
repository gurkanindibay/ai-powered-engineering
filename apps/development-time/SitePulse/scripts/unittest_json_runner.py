#!/usr/bin/env python3
"""Run the standard unittest discovery process and optionally write structured test results."""
from __future__ import annotations

import argparse
import json
import os
import sys
import unittest
from pathlib import Path
from typing import Any


class JsonResult(unittest.TextTestResult):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.cases: list[dict[str, Any]] = []
        self.active_test: unittest.case.TestCase | None = None
        self.active_status = "passed"

    def startTest(self, test: unittest.case.TestCase) -> None:
        self.active_test = test
        self.active_status = "passed"
        super().startTest(test)

    def stopTest(self, test: unittest.case.TestCase) -> None:
        if not any(row["native_id"] == test.id() and not row["is_subtest"] for row in self.cases):
            self._record(test, self.active_status)
        super().stopTest(test)
        self.active_test = None

    def _record(self, test: unittest.case.TestCase, status: str, detail: str = "",
                parameter_id: str | None = None) -> None:
        self.cases.append({"runner": "unittest", "suite": "harness-selftest", "native_id": test.id(),
                           "parameter_id": parameter_id, "status": status, "duration_s": None,
                           "detail": detail or None, "is_subtest": parameter_id is not None})

    def addSuccess(self, test: unittest.case.TestCase) -> None:
        super().addSuccess(test)
        self._record(test, "passed")

    def addFailure(self, test: unittest.case.TestCase, err: Any) -> None:
        super().addFailure(test, err)
        self.active_status = "failed"
        self._record(test, "failed", self._exc_info_to_string(err, test))

    def addError(self, test: unittest.case.TestCase, err: Any) -> None:
        super().addError(test, err)
        self.active_status = "error"
        self._record(test, "error", self._exc_info_to_string(err, test))

    def addSkip(self, test: unittest.case.TestCase, reason: str) -> None:
        super().addSkip(test, reason)
        self.active_status = "skipped"
        self._record(test, "skipped", reason)

    def addExpectedFailure(self, test: unittest.case.TestCase, err: Any) -> None:
        super().addExpectedFailure(test, err)
        self.active_status = "passed"
        self._record(test, "passed", "expected failure")

    def addUnexpectedSuccess(self, test: unittest.case.TestCase) -> None:
        super().addUnexpectedSuccess(test)
        self.active_status = "failed"
        self._record(test, "failed", "unexpected success")

    def addSubTest(self, test: unittest.case.TestCase, subtest: unittest.case.TestCase, err: Any) -> None:
        super().addSubTest(test, subtest, err)
        params = getattr(subtest, "params", None)
        if params is None:
            return
        parameter_id = ", ".join(f"{key}={value!r}" for key, value in params.items())
        if err is not None:
            self.active_status = "failed" if issubclass(err[0], AssertionError) else "error"
        self._record(test, "passed" if err is None else "failed",
                     "" if err is None else self._exc_info_to_string(err, test), parameter_id)


class JsonRunner(unittest.TextTestRunner):
    resultclass = JsonResult


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-s", "--start-directory", default=".", help="directory to start discovery (default: .)")
    parser.add_argument("-p", "--pattern", default="test*.py", help="test filename pattern")
    parser.add_argument("-t", "--top-level-directory", help="top level directory for imports")
    parser.add_argument("--json-output", type=Path, help="optional result JSON path (defaults to the CI artifact directory)")
    args = parser.parse_args(argv)

    start = Path(args.start_directory).resolve()
    top = Path(args.top_level_directory).resolve() if args.top_level_directory else None
    suite = unittest.defaultTestLoader.discover(str(start), pattern=args.pattern, top_level_dir=str(top) if top else None)
    result = JsonRunner(verbosity=2).run(suite)
    output = args.json_output
    artifact_dir = os.environ.get("SITEPULSE_GATE_ARTIFACT_DIR")
    if output is None and artifact_dir:
        output = Path(artifact_dir) / "unittest-case-results.json"
    if output:
        try:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps({"tests_run": result.testsRun, "passed": result.wasSuccessful(),
                                          "adapter_test_count": sum(not case["is_subtest"] for case in result.cases),
                                          "cases": result.cases}, indent=2) + "\n", encoding="utf-8")
        except OSError as exc:
            print(f"evidence collection warning: could not write unittest results: {exc}", file=sys.stderr)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
