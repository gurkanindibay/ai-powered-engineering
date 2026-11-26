"""Hard deadline behind pytest-timeout: a wedged test ends the run instead of the CI job.

pytest-timeout's signal method raises inside the test body only, once, and with
`timeout_func_only` nothing limits the teardown. A browser that stops answering then
blocks the process until the job limit (#520: a WebKit journey hit its 900 s limit and
the job idled for 70 more minutes). GRACE_S after a test's own limit, this dumps every
thread's stack (the main thread's too) and exits the process. It is armed from the test
body through teardown; setup is excluded because the first one builds the whole stack.
"""
from __future__ import annotations

import faulthandler
import os
import sys
import threading

import pytest

# Room for pytest-timeout to fail the test and for screenshots, traces and fixtures to close.
GRACE_S = 180.0

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


def _abort(fd: int, nodeid: str, deadline: float) -> None:
    os.write(fd, (f"\nhang guard: {nodeid} was still running after {deadline:.0f} s; "
                  "dumping every thread and ending the run\n").encode())
    faulthandler.dump_traceback(file=fd, all_threads=True)
    os._exit(1)  # the main thread is stuck, so nothing gentler would run


def _disarm(config: pytest.Config) -> None:
    timer = config.stash.get(_timer, None)
    if timer is not None:
        timer.cancel()


def pytest_configure(config: pytest.Config) -> None:
    # Output capture replaces fd 2 while tests run; keep the real one for the dump.
    config.stash[_stderr] = os.dup(sys.__stderr__.fileno())


def pytest_unconfigure(config: pytest.Config) -> None:
    _disarm(config)
    fd = config.stash.get(_stderr, None)
    if fd is not None:
        os.close(fd)


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_call(item: pytest.Item) -> None:
    # Not faulthandler.dump_traceback_later: pytest cancels that one as soon as a test
    # fails, which is just before the teardown of a wedged browser.
    limit = test_limit(item)
    if limit <= 0:
        return
    deadline = limit + GRACE_S
    timer = threading.Timer(deadline, _abort, (item.config.stash[_stderr], item.nodeid, deadline))
    timer.daemon = True
    item.config.stash[_timer] = timer
    timer.start()


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_protocol(item: pytest.Item):
    yield
    _disarm(item.config)


def pytest_enter_pdb(config: pytest.Config) -> None:
    _disarm(config)
