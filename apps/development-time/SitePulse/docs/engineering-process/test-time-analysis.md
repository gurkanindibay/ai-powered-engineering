# Test Time Analysis: Where the Time Goes and How to Cut It

> **Superseded by the [SitePulse Test Strategy](../testing/TEST_STRATEGY.md) (2026-11-24).** Done steps A–E are recorded in the strategy; open steps F–N are in its Execution lanes and Roadmap.

Date: 2026-11-15. Scope: `scripts/run_tests.py` (local gate run), `.github/workflows/sitepulse-ci.yml`
(PR/master CI) and `scripts/gui_e2e.py` (browser suite).

## 1. Current state (measured)

### CI wall time

| Source | Value |
|---|---|
| Last 5 `SitePulse CI` runs (runs 113–117) | 26–33 min each, all on one job (`verify`) |
| Job setup (containers, toolchains, `flutter pub get`) | ~1.5 min |
| `All gates` step (`run_tests.py`, all 21 gates **in sequence**) | ~25.7 min (run 116) |
| `record-evidence` job (push to master only) | 44 DAG tasks run **one after another**, each re-running the global gates |

### Gate durations with warm caches (from `.specify/evidence/task-37/40/41.json`)

| Gate | Warm duration |
|---|---|
| rust-build / rust-clippy (incremental) | < 0.5 s each |
| rust-test | ~7 s |
| flutter-analyze | 5–8 s |
| flutter-test | 35–41 s |
| api-system | ~27 s |
| all Python lints (persistence, tenant, lock, testid, ui-style, reuse, logging, traceability) | < 1.5 s each, ~6 s together |

### Browser suite (`gui-e2e`) from recorded runs (`.specify/executions/runs/2026/*.jsonl`)

Full-suite runs, with tests counted once (one pytest test can record several scenarios):

| Run | Unique tests | Sum of test time |
|---|---|---|
| 20261114T232759Z-3a81a19 | 114 | 1 223 s (20.4 min) |
| 20261115T001330Z-d263d5c | 114 | 925 s (15.4 min) |

Distribution (run 3a81a19): min 1.4 s, median 6.8 s, p90 18.9 s, max 111 s. 67 of the 114 tests take under 8 s.
This is mostly fixed per-test overhead, not test logic.

Heaviest files: `test_linked_backend_suites.py` (6 tests, 44–105 s), journeys (auditor 111 s, home owner 85 s),
`test_epic07_bank.py` 105 s, `test_p2_edge.py` 102 s, `test_epic06_auth.py` 100 s, `test_epic08_occupancy.py` 97 s.

On top of that, `gui-e2e` compiles the backend in **release** profile (a second full compile next to the debug
build used by every other gate) and builds the Flutter web bundle.

### Conclusion

The **browser suite takes about 70–80 % of CI time**, and **every gate runs one after another on one runner**.
The other gates take about 2 minutes once caches are warm. The per-gate CI split is estimated:
the job log could not be downloaded from this environment.

## 2. Root causes

1. **One job, run in sequence.** 21 gates run back to back on a 4-core runner. Gates that do not depend on
   each other (Python lints, Flutter, Rust, DB checks) never overlap.
2. **The PR runs the full e2e suite.** `GATES["gui-e2e"]` calls `gui_e2e.py run --json` without `--affected`.
   The `smoke/core/edge` markers in `e2e/pytest.ini` exist ("edge: P2, nightly"), but CI does not use them.
3. **The Rust cache is not saved on failed runs.** In run 116 `Post Run Swatinem/rust-cache@v2` shows as
   *skipped*: the action saves only on success. The last 5 runs all failed, so the cache gets stale and later
   runs compile more from scratch.
4. **The backend is compiled twice.** Debug for build/clippy/test/api-system, release for e2e
   (`stack.py`, `profile="release"`).
5. **Each e2e test pays a fixed cost.** The autouse `fresh_data` fixture stops the backend, truncates every table,
   re-runs both seed SQL files, restarts the backend and polls `/health` every 0.3 s (about 1–1.5 s). Then the
   test opens a new browser context and logs in **through the UI** (`login_as` → `LoginPage.login`;
   246 `login` references in `e2e/tests`).
6. **Work runs twice.** `test_linked_backend_suites.py` runs `cargo test --test integration_tests`,
   `--test payments_phase3_tests`, the harness unittests and Flutter tests again. The `rust-test`,
   `harness-selftest` and `flutter-test` gates already ran them. Each of those tests also pays for a DB reset
   and a Chromium context (44–105 s per run).
7. **Failures show up late.** The Python lints take about 1 s, but they run after `rust-build`/`clippy`/`rust-test`/
   `flutter-*`. A lint violation is reported only after a full compile.
8. **`record-evidence` runs in sequence.** 44 tasks × `harness_cli.py verify --record`, and each one runs the
   global gates (`rust-build`, `rust-clippy`, `flutter-analyze`, `test-run-recorded`) again for the same commit.

## 3. Recommendations

Savings are estimates for PR wall time against today's ~27 min.

### P0 — CI only, low risk (target: ~27 min → ~10–12 min)

| # | Change | Est. saving |
|---|---|---|
| A | **Split `verify` into parallel jobs**: `lint` (Python lints + harness-selftest, no toolchains, about 1 min), `rust` (build, clippy, test, money-fixtures, rust-db-test, schema-integrity, api-system), `flutter` (analyze, test), `e2e` (sharded, see B). Add a final `gate` job that `needs:` all of them and runs `test-run-recorded` + `rtm_validator.py`, so branch protection checks a single required job. | Wall time becomes the longest job instead of the sum of all jobs |
| B | **Shard the e2e suite** across 3–4 runners with a matrix. Each runner has its own ports and DB, so the stack needs no changes. Balance the shards using the recorded `duration_s` values, either with `pytest-split` and a durations file generated from `.specify/executions/runs`, or with a small `--shard i/n` option in `gui_e2e.py` that does greedy bin-packing over those durations. Merge the per-shard JSONL afterwards. | ~15–20 min → ~5–6 min per shard |
| C | **`cache-on-failure: true`** on `Swatinem/rust-cache@v2`, and cache `~/.pub-cache` plus the e2e web bundle (key: hash of `flutter/lib`, `pubspec.lock`, dart-defines). | Several minutes of cold compile on red/retry runs |
| D | **Fail fast**: run the Python lints first (in their own job, or at the start of `ORDER`). | A lint failure reports in about 1 min instead of 20+ |

### P1 — small code changes (target: total e2e CPU −30–40 %)

| # | Change | Est. saving |
|---|---|---|
| E | **Drop the duplicated linked suites from the browser run.** Mark the scenarios as verified from the `rust-test` / `flutter-test` / `harness-selftest` gate results (or a non-browser pytest session without `fresh_data`), not by running them again under Playwright. | 45–105 s per run + 6 resets/contexts |
| F | **Run e2e against the debug binary** already built by `rust-build`, or add a `[profile.e2e]` that inherits `dev` with `opt-level = 1` for dependencies. `argon2` is already `opt-level = 3` in dev. | One full release compile (several minutes cold) |
| G | **Log in once per role per session.** Log in through the UI once in a session fixture, save Playwright `storage_state` per role, and reuse it in `login_as`. Keep explicit UI-login tests (EPIC-06 auth, journeys, password-change) on the real flow. Check first that the auth token survives the per-test backend restart; the JWT secret is fixed, so it should. | ~1–3 s × most of the 114 tests |
| H | **Faster reset.** Build a seeded template DB once, then per test `DROP DATABASE` + `CREATE DATABASE … TEMPLATE sitepulse_e2e_seed`. Or add an E2E-only "reload state from DB" endpoint so the backend process does not restart. Also lower the `/health` poll from 0.3 s to 0.05 s. | ~0.5–1 s × 114 tests ≈ 1–2 min |
| I | **Tiered selection in CI**: PRs run `--affected` (smoke + affected epics; this is already the rule-13 selection). `master` pushes run the full suite. A nightly `schedule` runs `edge` + journeys. | PR e2e cost scales with the change instead of the whole suite |

### P2 — larger changes

| # | Change | Notes |
|---|---|---|
| J | **Parallel `run_tests.py`** (local and CI): a `--parallel` mode with three lanes that run together. Lane 1: cargo gates in sequence (they share the target-dir lock). Lane 2: Flutter gates. Lane 3: Python lints. DB gates already use their own throwaway DB names. Keep the JSON report in `ORDER`. | Local full run: about the longest lane instead of the sum |
| K | **pytest-xdist inside one e2e run.** Each worker needs its own backend port, DB and web server. `SITEPULSE_API_BASE_URL` is baked into the web bundle with `--dart-define`, so this needs either one bundle per worker port or a runtime config (for example, the web server proxies `/api` to the worker's backend). Sharding (B) gets most of the gain without this. | Helps local runs on machines with many cores |
| L | **`cargo nextest`** for `rust-test` (runs each test in its own process, in parallel), plus `mold` as linker and optionally `sccache`. | Smaller gain, because warm `rust-test` is already ~7 s |
| M | **`record-evidence`**: run the global gates once per commit and reuse the results for all 44 tasks; split tasks into a job matrix by DAG layer. | Shorter master post-merge time |
| N | **Split the long journeys** (111 s / 85 s) into checkpoints, or run them nightly only (I). | Removes the longest item, which sets the floor for any shard |

## 4. Suggested rollout

Status: step 1 (A, C, D) is implemented. `run_tests.py --group <lint|rust|flutter|e2e|final>` runs one
job's gates. `sitepulse-ci.yml` runs `lint`, `rust`, `flutter` and `e2e` in parallel. The `verify` job
(the required check name) needs all four, fails unless every one succeeded, and then runs `final` and
`rtm_validator.py`. All Rust caches use `cache-on-failure: true`, the Flutter SDK is cached, and a newer
push to a PR cancels the older check run.

Step 2, sharding (B), is implemented. `scripts/e2e_shard.py` splits the suite on recorded durations, and
`gui_e2e.py run --shard I/N` (or `$SITEPULSE_E2E_SHARD`) runs one shard. The `e2e` job is a 4-shard matrix.
With the current history the plan is 29/28/29/29 tests at ~236 s each, down from ~945 s in one run.
Each shard still builds the release backend and the web bundle itself. Building them once and sharing them
as an artifact is a follow-up. Selection by `--affected` on PRs (I) is not done yet.

Measured after the merge (run 129): lint 14 s, rust 3.4 min, flutter 2.8 min, e2e shards 6.3 / 8.1 / 7.9 /
10.2 min in the browser step, 11.5 min for the whole run. Shard 4 was slowest because it held both
Rust-linked wrappers (`test_epic07_rust_linked_scenarios`, `test_epic11_rust_linked_scenarios`). Each one
runs `cargo test` inside the browser job, usually on a cold debug build: the four shards share one Rust cache
key, and the shard that saves first does not compile tests.

Step 3:
- **E for CI:** the e2e job sets `PYTEST_ADDOPTS=--ignore=tests/test_linked_backend_suites.py`. Every suite
  those wrappers run is already a CI gate (harness-selftest, rust-test, flutter-test, api-system), and CI
  records nothing. Recorded local runs still execute the wrappers for scenario traceability.
  `harness/tests/test_ci_linked_suites.py` fails if a wrapped suite stops being gated in CI.
- **8 shards** instead of 4: ~160 s of tests per shard, down from ~319 s. The longest single test is the
  111 s auditor journey.
- **Web bundle cache:** `flutter/build/web-e2e` is cached by the hash of the Flutter sources. `stack.py`
  rebuilds it anyway when its fingerprint differs.

1. **A + C + D** (only `sitepulse-ci.yml`): parallel jobs, cache on failure, lints first. Measure.
2. **B + I**: shard e2e, `--affected` on PRs, full suite on master and nightly. Needs a shard option in
   `gui_e2e.py` and a step that merges the run records, so `test-run-recorded` still sees one run per task.
3. **E + F + G + H**: cut per-test cost. Measure again with the durations already recorded in `.specify/executions/runs`.
4. **J/K/L/M/N** if needed.

Expected result: PR feedback about **8–12 min** (from ~27 min), first lint signal in about 1 min, and roughly
the same coverage. The full suite still runs on every `master` push.

## 5. Constraints to keep

- Rule 13: every executed test still writes one record. Shards must merge into one run id, or the
  traceability check must accept several run ids per commit.
- Skipped gates are reported, never counted as passed. A sharded or affected run must report which tests it
  did not select.
- Do not weaken any gate. Every proposal above changes *where/when/how often* a test runs, never *whether*
  it can fail.
- To measure the next step, add the per-gate `duration_s` from `run_tests.py --json` as a CI artifact. This
  analysis had to estimate the CI split because the job log could not be downloaded.
