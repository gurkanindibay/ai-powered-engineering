#!/usr/bin/env python3
"""Soak-load the SitePulse web bundle in Playwright WebKit and count browser crashes.

WebKit faults such as the CanvasKit "Out of bounds memory access" crash (issue #527) hit
only about one load in 70, so a single green E2E run proves little. This tool loads the app
many times, in parallel, and counts CanvasKit errors, dead renderers and failed loads. No
backend or database is needed: the sign-in page is enough.

Build the bundle first, then run in the Playwright container (works on any Linux host):

    flutter build web --dart-define=E2E=true --output /tmp/sitepulse-web
    python3 scripts/webkit_load_soak.py --web /tmp/sitepulse-web --docker

Compare launch settings with --env (it overrides the defaults used by e2e/conftest.py):

    python3 scripts/webkit_load_soak.py --web DIR --docker --env JSC_useConcurrentJIT=1

Exit status: 0 when every load is clean, 1 otherwise, 2 when the soak could not run.
"""
from __future__ import annotations

import argparse
import collections
import functools
import http.server
import json
import multiprocessing
import os
import subprocess
import sys
import threading
from pathlib import Path

PLAYWRIGHT_VERSION = "1.55.0"  # keep in step with e2e/requirements.txt
IMAGE = f"mcr.microsoft.com/playwright/python:v{PLAYWRIGHT_VERSION}-noble"
# Mirrors WEBKIT_LAUNCH_ENV in e2e/conftest.py.
DEFAULT_ENV = {"WEBKIT_SKIA_ENABLE_CPU_RENDERING": "1", "JSC_useConcurrentJIT": "0"}
SETTLE_MS = 1200


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args) -> None:
        pass


def _worker(url: str, loads: int, env: dict[str, str]) -> dict[str, int]:
    from playwright.sync_api import Error, sync_playwright

    count: collections.Counter[str] = collections.Counter()
    with sync_playwright() as playwright:
        launch_env = {**os.environ, **env}
        browser = playwright.webkit.launch(env=launch_env)
        for _ in range(loads):
            context = browser.new_context(viewport={"width": 1280, "height": 900}, locale="tr-TR")
            page = context.new_page()
            messages: list[str] = []
            crashed: list[bool] = []
            page.on("console", lambda message: messages.append(message.text))
            page.on("pageerror", lambda error: messages.append(str(error)))
            page.on("crash", lambda _page: crashed.append(True))
            failed = False
            try:
                page.goto(url, timeout=30000)
                page.wait_for_selector("flt-semantics-host, flt-semantics", state="attached", timeout=30000)
                page.wait_for_timeout(SETTLE_MS)
            except Error:
                failed = True
            canvaskit = any("Out of bounds memory access" in text for text in messages)
            count["loads"] += 1
            count["canvaskit_errors"] += canvaskit
            count["renderer_deaths"] += bool(crashed)
            count["failed_loads"] += bool(failed or canvaskit or crashed)
            try:
                context.close()
            except Error:
                browser.close()
                browser = playwright.webkit.launch(env=launch_env)
        browser.close()
    return dict(count)


def soak(web: Path, loads: int, parallel: int, env: dict[str, str]) -> dict:
    handler = functools.partial(_QuietHandler, directory=str(web))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    url = f"http://127.0.0.1:{server.server_port}"
    shares = [loads // parallel + (index < loads % parallel) for index in range(parallel)]
    total = collections.Counter(loads=0, canvaskit_errors=0, renderer_deaths=0, failed_loads=0)
    # Start the workers before the server thread exists, so no thread is forked.
    with multiprocessing.Pool(parallel) as pool:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        for result in pool.starmap(_worker, [(url, share, env) for share in shares if share]):
            total.update(result)
    server.shutdown()
    return {**total, "requested_loads": loads, "env": env}


def run_in_docker(args: argparse.Namespace) -> int:
    inner = ["--web=/web", f"--loads={args.loads}", f"--parallel={args.parallel}"]
    inner += [f"--env={item}" for item in args.env] + (["--json"] if args.json else [])
    script = f"pip install -q playwright=={PLAYWRIGHT_VERSION} >/dev/null 2>&1; exec python /soak.py \"$@\""
    return subprocess.run(
        ["docker", "run", "--rm", "--ipc=host",
         "-v", f"{args.web.resolve()}:/web:ro", "-v", f"{Path(__file__).resolve()}:/soak.py:ro",
         IMAGE, "bash", "-c", script, "soak", *inner]).returncode


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--web", type=Path, required=True, help="built web bundle (flutter build web --output)")
    parser.add_argument("--loads", type=int, default=800, help="total page loads (default: %(default)s)")
    parser.add_argument("--parallel", type=int, default=8, help="parallel browsers (default: %(default)s)")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE",
                        help="extra or overriding WebKit launch variable (repeatable)")
    parser.add_argument("--docker", action="store_true", help=f"run inside {IMAGE}")
    parser.add_argument("--json", action="store_true", help="print the result as JSON")
    args = parser.parse_args(argv)
    if args.loads < 1 or args.parallel < 1:
        parser.error("--loads and --parallel must be positive")
    if any("=" not in item for item in args.env):
        parser.error("--env takes KEY=VALUE")
    if not (args.web / "index.html").is_file():
        parser.error(f"no web bundle in {args.web}")
    if args.docker:
        return run_in_docker(args)
    env = {**DEFAULT_ENV, **dict(item.split("=", 1) for item in args.env)}
    try:
        result = soak(args.web, args.loads, args.parallel, env)
    except Exception as exc:  # report any setup failure with its own exit status
        print(f"soak could not run: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result))
    else:
        print(f"{result['loads']} loads: {result['failed_loads']} failed "
              f"({result['canvaskit_errors']} CanvasKit errors, {result['renderer_deaths']} renderer deaths) env={env}")
    return 1 if result["failed_loads"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
