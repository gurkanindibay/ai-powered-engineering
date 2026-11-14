#!/usr/bin/env python3
"""SitePulse GUI end-to-end suite runner (Playwright, real browser).

Runs e2e/tests against an isolated stack that never touches the developer
stack: a throwaway PostgreSQL database (sitepulse_e2e_<pid>), the real backend
on :8180 and the Flutter web E2E bundle on :9190 (see e2e/support/stack.py).

Commands:
  run    (default) build what is missing, start the stack, run pytest, stop
  serve  start the stack and keep it up until Ctrl+C (for writing tests)
  build  (re)build the E2E web bundle only

Needs DB_PASS (and optionally DB_USER/DB_HOST/DB_PORT) for PostgreSQL, from the
environment or --env-file (default: backend/.env when present).

Examples:
  python3 scripts/gui_e2e.py --env-file backend/.env
  python3 scripts/gui_e2e.py run -m smoke --headed
  python3 scripts/gui_e2e.py run -k login --json
  python3 scripts/gui_e2e.py run --affected --record --task issue-123   # the run every task records before its PR
  python3 scripts/gui_e2e.py serve

Exit codes: 0 all selected tests passed, 1 test failures, 2 setup error.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
E2E = ROOT / "e2e"
VENV_PY = E2E / ".venv" / "bin" / "python"
ARTIFACTS = E2E / ".artifacts"


def load_env_file(path: Path) -> None:
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def ensure_venv() -> None:
    if VENV_PY.exists():
        return
    subprocess.run([sys.executable, "-m", "venv", str(E2E / ".venv")], check=True)
    subprocess.run([str(VENV_PY), "-m", "pip", "install", "-q", "-r", str(E2E / "requirements.txt")], check=True)


def summarize_junit(path: Path) -> dict:
    if not path.exists():
        return {"tests": 0, "failures": 0, "errors": 0, "skipped": 0, "cases": []}
    root = ET.parse(path).getroot()
    suite = root if root.tag == "testsuite" else root.find("testsuite")
    cases = []
    for case in suite.iter("testcase"):
        status = "passed"
        for tag in ("failure", "error", "skipped"):
            node = case.find(tag)
            if node is not None:
                status = {"failure": "failed", "error": "error", "skipped": "skipped"}[tag]
                if tag == "skipped" and "xfail" in (node.get("type", "") + node.get("message", "")):
                    status = "xfailed"
                break
        cases.append({"name": f"{case.get('classname')}::{case.get('name')}", "status": status,
                      "seconds": float(case.get("time", 0))})
    return {k: int(suite.get(k, 0)) for k in ("tests", "failures", "errors", "skipped")} | {"cases": cases}


def record_history(task: str | None) -> dict:
    """Append this run's scenario executions to the test history and refresh the HTML dashboard."""
    tool = [sys.executable, str(ROOT / "scripts" / "feature_traceability.py"), "--json"]
    proc = subprocess.run([*tool, "record", *(["--task", task] if task else [])], capture_output=True, text=True)
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"error": (proc.stderr or proc.stdout).strip()[-500:]}
    page = subprocess.run([*tool, "html"], capture_output=True, text=True)
    if page.returncode == 0:
        result.update(json.loads(page.stdout))
    return result


def affected_selection() -> dict:
    """What the changes on this branch call for (scripts/feature_traceability.py affected)."""
    proc = subprocess.run([sys.executable, str(ROOT / "scripts" / "feature_traceability.py"), "--json", "affected"],
                          capture_output=True, text=True)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"error": (proc.stderr or proc.stdout).strip()[-500:]}


def cmd_run(args: argparse.Namespace, passthrough: list[str]) -> int:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    junit = ARTIFACTS / "junit.xml"
    argv = [str(VENV_PY), "-m", "pytest", str(E2E / "tests"), "-p", "no:cacheprovider",
            f"--junitxml={junit}", "--browser-channel", args.browser_channel] if args.browser_channel else \
           [str(VENV_PY), "-m", "pytest", str(E2E / "tests"), "-p", "no:cacheprovider", f"--junitxml={junit}"]
    argv += ["--browser", args.browser, "--output", str(ARTIFACTS / "playwright"),
             "--tracing", "retain-on-failure", "--screenshot", "only-on-failure"]
    if args.headed:
        argv.append("--headed")
    if args.affected:
        selection = affected_selection()
        if "error" in selection:
            print(f"setup error: could not work out the affected tests: {selection['error']}")
            return 2
        if selection["mode"] == "none":
            print("--affected: no backend, flutter, e2e or feature file changed on this branch; nothing to run")
            return 0
        if not args.json:
            print(f"--affected: {selection['mode']} run"
                  + (f", selecting: {selection['marker']}" if selection["marker"] else " (full suite)"))
            print("\n".join(f"  {reason}" for reason in selection["reasons"][:20]))
        if selection["marker"]:
            args.marker = f"({selection['marker']}) and ({args.marker})" if args.marker else selection["marker"]
    if args.marker:
        argv += ["-m", args.marker]
    if args.keyword:
        argv += ["-k", args.keyword]
    if args.json:
        argv.append("-q")
    argv += passthrough
    env = {**os.environ, "GUI_E2E_REBUILD": "1" if args.rebuild or os.environ.get("GUI_E2E_REBUILD") == "1" else "0"}
    if len(env.get("TMPDIR", "")) > 30:
        env["TMPDIR"] = "/tmp"
    started = time.time()
    proc = subprocess.run(argv, cwd=E2E, env=env,
                          stdout=subprocess.PIPE if args.json else None, stderr=subprocess.STDOUT if args.json else None,
                          text=True)
    # A run made for a named task ($SITEPULSE_TASK, e.g. inside run_tests.py) is always recorded.
    history = record_history(args.task) if args.record or os.environ.get("SITEPULSE_TASK") else None
    if history and not args.json:
        print(f"test history: {history.get('records', 0)} test executions recorded"
              f"{' as ' + history['run_id'] if history.get('records') else ''}; "
              f"dashboard: {history.get('report', 'not generated')}" if 'error' not in history
              else f"test history not recorded: {history['error']}")
    if args.json:
        summary = summarize_junit(junit)
        summary.update({"exit_code": proc.returncode, "seconds": round(time.time() - started, 1),
                        "artifacts": str(ARTIFACTS), "history": history})
        if proc.returncode not in (0, 1):
            summary["output_tail"] = (proc.stdout or "")[-3000:]
        print(json.dumps(summary, indent=2))
    if proc.returncode in (0, 1):
        return proc.returncode
    return 2 if proc.returncode in (3, 4) else 1


def cmd_serve(_: argparse.Namespace) -> int:
    sys.path.insert(0, str(E2E))
    from support import stack as st  # noqa: E402
    st.build_web()
    s = st.E2EStack(ARTIFACTS / "logs")
    s.start()
    print(f"E2E stack up: web {st.web_base()}  api {st.api_base()}  db {s.db_name}  (Ctrl+C to stop)", flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        s.stop()
    return 0


def cmd_build(_: argparse.Namespace) -> int:
    sys.path.insert(0, str(E2E))
    from support import stack as st  # noqa: E402
    st.build_web(force=True)
    print(f"built {st.WEB_BUILD}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="run", choices=["run", "serve", "build"])
    ap.add_argument("--env-file", type=Path, default=ROOT / "backend" / ".env",
                    help="file with DB_PASS etc. (default backend/.env if it exists)")
    ap.add_argument("--browser", default="chromium", choices=["chromium", "firefox", "webkit"])
    ap.add_argument("--browser-channel", default="chrome",
                    help="chromium channel: 'chrome' (installed Chrome) or '' for bundled Chromium")
    ap.add_argument("--headed", action="store_true", help="show the browser window")
    ap.add_argument("-m", "--marker", help="pytest marker expression, e.g. smoke or 'core and role_manager'")
    ap.add_argument("-k", "--keyword", help="pytest -k expression")
    ap.add_argument("--rebuild", action="store_true", help="rebuild the E2E web bundle first")
    ap.add_argument("--json", action="store_true", help="print a JSON summary instead of pytest output")
    ap.add_argument("--task", help="label of the work this run verifies, shown on the dashboard "
                                   "(default: $SITEPULSE_TASK, else the branch)")
    ap.add_argument("--affected", action="store_true",
                    help="run only what the changes on this branch affect: the smoke set plus the affected epics, "
                         "or the full suite when shared code changed (.specify/features/impact-map.json)")
    ap.add_argument("--record", action="store_true",
                    help="append this run to the test history under .specify/executions (commit it with the task) "
                         "and refresh the dashboard")
    args, passthrough = ap.parse_known_args()
    if args.browser != "chromium":
        args.browser_channel = ""
    if args.env_file and args.env_file.exists():
        load_env_file(args.env_file)
    if not os.environ.get("DB_PASS"):
        msg = "DB_PASS is not set (pass --env-file or export DB_PASS)"
        print(json.dumps({"exit_code": 2, "error": msg}) if args.json else f"setup error: {msg}", file=sys.stdout)
        return 2
    try:
        ensure_venv()
    except subprocess.CalledProcessError as exc:
        print(f"setup error: could not create e2e/.venv: {exc}")
        return 2
    if args.command == "serve":
        return cmd_serve(args)
    if args.command == "build":
        return cmd_build(args)
    return cmd_run(args, passthrough)


if __name__ == "__main__":
    sys.exit(main())
