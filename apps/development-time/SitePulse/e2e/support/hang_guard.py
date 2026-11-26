"""Hard deadline behind pytest-timeout: a wedged run ends instead of reaching the CI job limit.

pytest-timeout's signal method raises inside the test body only, once, and with
`timeout_func_only` nothing limits the setup or the teardown. A browser that stops
answering then blocks the process until the job limit (#520: a WebKit journey hit its
900 s limit and the job idled for 70 more minutes; a later run hung in a phase no test
body covers and the job died at 90 minutes). So this guard is armed for the whole
runtest protocol — setup, call and teardown — with the flow allowance the first test of
a lane needs to build the whole stack, and again for the session-scoped finalizers that
run after the last test. At the deadline it dumps every thread's stack (the main
thread's too) and exits the process.
"""
from __future__ import annotations

import faulthandler
import json
import os
import sys
import threading
from pathlib import Path

import pytest

# Room for pytest-timeout to fail the test and for screenshots, traces and fixtures to close.
GRACE_S = 180.0
# A test's setup builds whatever its fixtures need; the first one of a lane builds the whole stack.
SETUP_S = 300.0
# Session-scoped fixtures tear down after the last test, where no test deadline is left.
TEARDOWN_S = 300.0

_stderr = pytest.StashKey()
_timer = pytest.StashKey()


def test_limit(item: pytest.Item) -> float:
    """The pytest-timeout limit of `item` in seconds; 0 when it has none."""
    marker = item.get_closest_marker("timeout")
    if marker is not None:
        value = marker.args[0] if marker.args else marker.kwargs.get("timeout")
    else:
        value = item.config.getoption("timeout", None)
        if value is None:
            value = item.config.getini("timeout")
    return float(value or 0)


test_limit.__test__ = False  # not a test, whatever its name suggests


def _record(marker: Path, fd: int, nodeid: str, deadline: float) -> None:
    """Name the hung test where it outlives the run, which never writes its junit.xml."""
    # A GitHub Actions workflow command: shown as an error annotation on the job.
    os.write(fd, f"\n::error title=Hung E2E test::{nodeid} exceeded {deadline:.0f} s\n".encode())
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(json.dumps({"test": nodeid, "deadline_s": deadline}) + "\n", encoding="utf-8")
    except OSError as exc:
        os.write(fd, f"hang guard: could not write {marker}: {exc}\n".encode())


def _abort(fd: int, marker: Path, nodeid: str, deadline: float) -> None:
    _record(marker, fd, nodeid, deadline)
    os.write(fd, (f"\nhang guard: {nodeid} was still running after {deadline:.0f} s; "
                  "dumping every thread and ending the run\n").encode())
    faulthandler.dump_traceback(file=fd, all_threads=True)
    os._exit(1)  # the main thread is stuck, so nothing gentler would run


def _disarm(config: pytest.Config) -> None:
    timer = config.stash.get(_timer, None)
    if timer is not None:
        timer.cancel()


def _arm(config: pytest.Config, nodeid: str, deadline: float) -> None:
    """Watch `nodeid` for `deadline` seconds, replacing whatever was watched before."""
    _disarm(config)
    marker = config.rootpath / ".artifacts" / "hang-guard.json"
    timer = threading.Timer(deadline, _abort, (config.stash[_stderr], marker, nodeid, deadline))
    timer.daemon = True
    config.stash[_timer] = timer
    timer.start()


def pytest_configure(config: pytest.Config) -> None:
    # Output capture replaces fd 2 while tests run; keep the real one for the dump.
    config.stash[_stderr] = os.dup(sys.__stderr__.fileno())


def pytest_unconfigure(config: pytest.Config) -> None:
    _disarm(config)
    fd = config.stash.get(_stderr, None)
    if fd is not None:
        os.close(fd)


@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_protocol(item: pytest.Item):
    # Not faulthandler.dump_traceback_later: pytest cancels that one as soon as a test
    # fails, which is just before the teardown of a wedged browser. Setup and teardown are
    # inside this window; pytest-timeout bounds only the body.
    limit = test_limit(item)
    if limit > 0:
        _arm(item.config, item.nodeid, SETUP_S + limit + GRACE_S)
    try:
        yield
    finally:
        # Session-scoped finalizers may hang after a report that already ended the tests.
        if limit > 0:
            _arm(item.config, item.nodeid, TEARDOWN_S)


def pytest_enter_pdb(config: pytest.Config) -> None:
    _disarm(config)
