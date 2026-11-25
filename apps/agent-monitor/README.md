# Agent Monitor (Android)

A phone app that shows your coding agents (Claude Code, Codex, Antigravity, GitHub Copilot, DeepSeek):

- **Work**: which agent is working on which issue. It reads the `in progress` + `claim:<harness>/<session>`
  labels (`scripts/issue_claim.py`), the PR carrying the same claim and its CI checks, and open PRs by the
  Copilot coding agent. Each item is marked **active**, **idle** or **stuck**: stuck means failing checks or
  no activity for the "stuck after" hours (default 6).
- **Usage**: tokens used recently and how much quota is left per provider, plus recent sessions.
- **Start new session**: on an idle or stuck item, start a fresh agent. Claude, Codex and DeepSeek run in
  GitHub Actions (`.github/workflows/agent-relaunch.yml`). Copilot gets the issue assigned to its coding
  agent. The new run takes over the claim.

## Where the numbers come from

| Provider | Source | What you get |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` (collector) | tokens per 5h / 24h / 7d window and per session. Pass `--claude-5h-limit` / `--claude-7d-limit` to get "% left" (plan limits are not in the transcripts) |
| Codex | `~/.codex/sessions/**/*.jsonl` (collector) | the plan's real 5h and weekly `used_percent`, reset times, tokens per session |
| Copilot | GitHub billing API (collector, via `gh`) | premium requests this month against `--copilot-allowance` (default 300) |
| DeepSeek | `api.deepseek.com/user/balance` (phone or collector) | balance left (granted + topped up) |
| Antigravity | `~/.config/agent-monitor/antigravity.json` | only what you put there: Antigravity has no public quota API |

Claude and Codex usage lives on the computer the agents run on, so a small collector runs there and
publishes a JSON snapshot to a **secret gist** that the app reads.

## Setup

1. **Install the app.** Download the `agent-monitor-apk` artifact from the latest *Agent Monitor*
   workflow run (Actions tab), unzip it, and open `app-release.apk` on your phone
   (allow "install unknown apps" when asked).
2. **Run the collector on your computer** (Python 3.10+, `gh` logged in with the `gist` scope):

   ```bash
   python3 scripts/agent_usage_collector.py --create-gist          # prints the gist id once
   python3 scripts/agent_usage_collector.py --publish-gist <id> --watch 300 \
       --claude-5h-limit 2000000                                   # optional, see table
   ```

   Keep it running (or put it in cron / a login item). Optional: `export DEEPSEEK_API_KEY=...` first.
   Only project folder names leave your machine, never full paths or transcript content.
3. **Create a GitHub token** (fine-grained, for the repositories you watch): Issues read/write,
   Pull requests read, Checks read, Actions read/write, Metadata read; account permission Gists read.
4. **In the app's Settings**, enter the token, the repositories, the gist id, and optionally the DeepSeek key.
   Keys stay in Android's encrypted storage.
5. **To restart stuck work from the phone**, add the repository secrets the relaunch workflow uses:
   `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`), `OPENAI_API_KEY` (Codex), `DEEPSEEK_API_KEY`.
   The workflow has to be on the default branch before GitHub lets the app start it. Copilot needs the
   Copilot coding agent turned on for the repository.

Antigravity runs only in its desktop app, so it can't be restarted from the phone. Pick a cloud harness
to continue its issue instead.

## Development

```bash
cd apps/agent-monitor
flutter pub get && flutter analyze && flutter test
flutter build apk --release
python3 -m unittest discover -s tests/agent_usage_collector     # from the repository root
```

CI: `.github/workflows/agent-monitor-ci.yml` runs the collector tests, format, analyze and widget/logic
tests, and builds the APK artifact. Money values (the DeepSeek balance, Copilot requests) are `Decimal`
end to end.
