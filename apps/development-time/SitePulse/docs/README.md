# SitePulse documentation

All workspace and SitePulse documentation lives in this folder. Documents are grouped by subject so that
standards, designs, test plans and reports are easy to find.

| Folder | Contents |
|---|---|
| [architecture/](architecture/) | Backend and domain architecture: role-based auth and audit, owners and residents design, unit state transitions, compact unit directory, backend flaws. |
| [database/](database/) | Schema evaluations, design reviews and the database fix plan. |
| [payments/](payments/) | Payments management structure, product owner evaluation and regulatory and market evaluation. |
| [quality/](quality/) | Code and database flaw reports, product throughput and cost, product action observability. |
| [reusability/](reusability/) | Flutter and Rust reuse reports that feed the reuse gates. |
| [standards/](standards/) | Normative standards: [RUST_STANDARDS.md](standards/RUST_STANDARDS.md) and [LOGGING_STANDARDS.md](standards/LOGGING_STANDARDS.md). |
| [testing/](testing/) | GUI test plan and scenario catalogue, GUI automation plan, coverage gaps, test plans and the execution matrix, test coverage assessment, the [Cucumber and Serenity BDD migration analysis](testing/cucumber-serenity-migration-analysis.md). |
| [engineering-process/](engineering-process/) | Engineering harness guide, CMMI pipeline (agent roles, pipeline specification, traceability matrix) and the harness plan and report. |
| [ux/](ux/) | UX and UI evaluation, Papara design guidelines, page layout standard, UX reference pages and images. |
| [api/](api/) | Generated OpenAPI specification ([openapi.json](api/openapi.json)); regenerate with `generate_openapi`. |

## Conventions

- Document names are kept as they were when the folders were introduced, so existing links and
  citations by name (for example `GUI_TEST_PLAN.md §3`) still resolve.
- Link to a document by its path in this folder. Do not add a second copy at another location.
- Keep generated files (`api/openapi.json`) out of hand edits.

## Known stale references

The SQL migrations `V16`, `V17`, `V18` and `V20` under `backend/migrations/` cite documents by their old
`docs/` path in their header comments. They are not updated on purpose: the backend stores a SHA-256
checksum of every applied migration and refuses to start when one changes. Read the cited names in the
folder above.
