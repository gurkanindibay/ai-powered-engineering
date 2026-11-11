# GitHub Copilot Instructions

This repository centers on SitePulse, a spec-driven residential site management platform under `apps/development-time/SitePulse/`.

## Engineering standards

- Read the applicable `.specify/` constitution, feature specification, and task DAG before implementing a feature.
- Follow task dependencies in `.specify/tasks/task-dag.json`; use `python3 apps/development-time/SitePulse/harness/harness_cli.py next` to identify eligible work.
- Keep domain logic, UI, and persistence boundaries clear. Follow the repository's Rust and Flutter rules for backend and client changes.
- Use exact decimal types for monetary values: `rust_decimal::Decimal`, Dart `Decimal`, and SQL `NUMERIC`; do not use floating-point arithmetic for money.
- Keep source code, identifiers, schemas, tests, and comments in English.
- Run the relevant harness, backend, and Flutter checks for changes. The harness tests can be run with `python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests`.
- When probabilistic agent output is involved, validate it through deterministic verification gates before accepting it.
