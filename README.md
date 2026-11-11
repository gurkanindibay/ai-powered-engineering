# AI-Powered Engineering

This repository's primary application is **SitePulse**, a spec-driven residential site management platform. Its development workflow uses a task DAG and a closed-loop verification harness.

## SitePulse

- Product specifications and architecture: `apps/development-time/SitePulse/.specify/`
- Flutter client: `apps/development-time/SitePulse/flutter/`
- Rust and PostgreSQL backend: `apps/development-time/SitePulse/backend/`
- Task scheduler and maker-checker harness: `apps/development-time/SitePulse/harness/`
- Verification scripts: `apps/development-time/SitePulse/scripts/`

See [the SitePulse guide](apps/development-time/SitePulse/README.md) for setup and architecture, and [development-time engineering guidance](apps/development-time/README.md) for the workflow.

## Verify the project

Run the harness unit tests:

```sh
python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests
```

Run the full SitePulse gates where the required toolchains and database are available:

```sh
python3 apps/development-time/SitePulse/scripts/run_tests.py
```

The root [AGENTS.md](AGENTS.md) contains workspace rules and verification requirements.
