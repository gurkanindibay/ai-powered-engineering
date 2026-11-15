## What

<!-- What changed and why. -->

## Verification

<!-- Gates you ran (`run_tests.py --summary`) and their result. Name anything skipped. -->

## Test report

<!--
CI runs the affected tests on every PR and publishes the report: the stats are on the
`test-report` job's summary page and the full report and HTML dashboard are artifact `e2e-test-report`
(AGENTS.md rule 13). After a push to `master`, the latest report and archived master runs are also on
the GitHub Pages site. Link the CI run here, or write "See CI". Docs-only PR: "Not required: no behaviour change".

Only when recorded runs are switched back on (`require_recorded_run` in
apps/development-time/SitePulse/.specify/executions/settings.json, or SITEPULSE_REQUIRE_RECORDED_RUN=1):
paste the output of `feature_traceability.py task-report` after `gui_e2e.py run --affected --record --task "<task>"`
and commit the new files under .specify/executions/.
-->
