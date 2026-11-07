#!/usr/bin/env python3
"""Phase 1 exit check: prove the E2E web build exposes automation ids.

Opens the app in a real browser, checks the login ids exist, logs in as the
seed manager and homeowner through the UI, and checks a dashboard id appears.

Usage:
  e2e/.venv/bin/python e2e/probe_semantics.py --base-url http://localhost:9190 [--headed] [--json]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from support.flutter import by_id, fill, visible_ids, wait_for_app  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"


def load_actors() -> dict:
    real = FIXTURES / "actors.json"
    return json.loads((real if real.exists() else FIXTURES / "actors.example.json").read_text())


def login(page, tab: str, prefix: str, actor: dict) -> None:
    by_id(page, f"login_tab_{tab}").click()
    by_id(page, f"login_{prefix}_email").wait_for(timeout=10_000)
    fill(page, f"login_{prefix}_email", actor["email"])
    fill(page, f"login_{prefix}_password", actor["password"])
    by_id(page, f"login_{prefix}_submit").click()


def run(base_url: str, headed: bool, channel: str | None) -> list[dict]:
    actors = load_actors()
    results: list[dict] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append({"check": name, "passed": ok, "detail": detail})

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not headed, channel=channel)
        for role, tab, prefix, landmark in [
            ("manager", "siteManager", "manager", "btn_open_unified_dues_center"),
            ("homeowner", "homeOwner", "homeowner", "hero_balance_amount"),
        ]:
            page = browser.new_context(viewport={"width": 1280, "height": 900}).new_page()
            errors: list[str] = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(base_url)
            wait_for_app(page)
            ids = visible_ids(page)
            needed = [f"login_tab_{tab}"]
            check(f"{role}: login ids rendered", all(i in ids for i in needed), f"{len(ids)} ids on login screen")
            try:
                login(page, tab, prefix, actors[role])
                by_id(page, landmark).wait_for(timeout=20_000)
                check(f"{role}: dashboard landmark '{landmark}' after UI login", True)
            except Exception as exc:  # report, don't crash the probe
                check(f"{role}: dashboard landmark '{landmark}' after UI login", False,
                      f"{type(exc).__name__}; ids now: {visible_ids(page)[:25]}")
            check(f"{role}: no uncaught page errors", not errors, "; ".join(errors)[:300])
            page.context.close()
        browser.close()
    return results


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default="http://localhost:9190")
    ap.add_argument("--headed", action="store_true")
    ap.add_argument("--channel", default="chrome", help="'chrome' (installed) or '' for bundled Chromium")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    results = run(a.base_url, a.headed, a.channel or None)
    if a.json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
    else:
        for r in results:
            print(f"{'PASS' if r['passed'] else 'FAIL'}  {r['check']}  {r['detail']}")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
