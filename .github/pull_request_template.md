## What

<!-- What changed and why. -->

## Verification

<!-- Gates you ran (`run_tests.py --summary`) and their result. Name anything skipped. -->

## Test report

<!--
Required for every PR that changes SitePulse behaviour (AGENTS.md rule 13). Replace this comment with the output of:

    python3 apps/development-time/SitePulse/scripts/gui_e2e.py run --affected --record --task "<task>"
    python3 apps/development-time/SitePulse/scripts/feature_traceability.py task-report

and commit the new files under apps/development-time/SitePulse/.specify/executions/.
If the suite could not run in your environment, say so here with the reason. Never paste a report you did not produce.
Docs-only PR: write "Not required: no behaviour change".
-->
