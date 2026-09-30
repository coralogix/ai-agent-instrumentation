# Codex CLI - Coralogix

Forward every Codex CLI session — API requests, tool calls, SSE events, and prompt activity — directly into Coralogix using Codex's built-in OpenTelemetry support.

No wrappers. No code changes. Codex emits OTLP natively; you just point it at your Coralogix ingress endpoint via `~/.codex/config.toml`.

---

## How it works


Codex CLI emits telemetry via OTel when the `[otel]` block is configured in `~/.codex/config.toml`. This folder provides:

- `config.toml.example` — the OTel block to merge into your Codex config
- `.env.example` — stores your Coralogix credentials (git-ignored)
- `hooks/` — a PostToolUse hook that adds the one signal Codex's OTel omits: which repository each session worked in (see [Repo-tracker hook](#repo-tracker-hook-macos))
- `coralogix-codex-dashboard.json` — pre-built dashboard ready to import into Coralogix

Codex supports two external OTel pipelines: `exporter` (logs) and `trace_exporter` (traces). The `metrics_exporter` key defaults to Codex's internal Statsig pipeline and does not support `otlp-http` — metric-like counters (`codex.api_request`, `codex.tool_decision`, etc.) are available as structured fields on log events via the `exporter` pipeline.

When querying logs in Coralogix, filter on `$d.resource.attributes['service.name'] == 'codex_cli_rs'` — this is stable across all client versions. Standalone log records also carry `spanId` and `traceId` for correlation back to traces.

---

## Signals sent to Coralogix

### Log events

| Event | Key attributes |
|---|---|
| `codex.conversation_starts` | `conversation.id`, `model`, `approval_policy`, `sandbox_mode` |
| `codex.api_request` | `conversation.id`, `user.email`, `user.account_id`, `model`, `http.response.status_code`, `duration_ms`, `attempt`, `terminal.type` |
| `codex.sse_event` | `conversation.id`, `user.email`, `user.account_id`, `model`, `event.kind`, `event.timestamp` (token counts on `response.completed`: `input_token_count`, `output_token_count`, `cached_token_count`, `reasoning_token_count`, `tool_token_count`) |
| `codex.websocket_request` | `conversation.id`, `success`, `duration_ms` |
| `codex.websocket_event` | `conversation.id`, `event.kind`, `success`, `duration_ms` |
| `codex.user_prompt` | `conversation.id`, `user.email`, `model`, `prompt` (full text), `prompt_length` |
| `codex.tool_decision` | `conversation.id`, `user.email`, `model`, `tool_name`, `decision` (`approved`/`rejected`), `source` (`Config` for auto-approved rules, `User` for manual) |
| `codex.tool_result` | `conversation.id`, `user.email`, `model`, `tool_name`, `arguments`, `output`, `success`, `duration_ms`, `mcp_server`, `call_id` |

### Traces

Codex emits a trace per session when `trace_exporter` is configured. Spans cover the full turn lifecycle including API calls and tool executions.

| Span | Key attributes |
|---|---|
| `session_loop` (root) | `busy_ns`, `idle_ns`, `duration` — total session time split between agent processing and idle (developer) time |
| `stream_request` (child) | `busy_ns`, `idle_ns`, `duration` — per-API-call breakdown; contains embedded `codex.api_request` log with `user.email` and response headers including quota data (`x-codex-plan-type`, `x-codex-primary-used-percent`) |

---

## Setup

### 1. Configure your Coralogix credentials

```bash
cp .env.example .env
```

Open `.env` and fill in:

```
CX_API_KEY=<your-send-your-data-api-key>
CX_OTLP_ENDPOINT=https://ingress.eu1.coralogix.com
CX_APPLICATION_NAME=codex
CX_SUBSYSTEM_NAME=codex-sessions
```

Find your Send-Your-Data API key under **Settings → API Keys** in your Coralogix tenant.

**OTLP ingress by region:**

| Domain | OTLP endpoint |
|---|---|
| `us1.coralogix.com` | `https://ingress.us1.coralogix.com` |
| `us2.coralogix.com` | `https://ingress.us2.coralogix.com` |
| `eu1.coralogix.com` | `https://ingress.eu1.coralogix.com` |
| `eu2.coralogix.com` | `https://ingress.eu2.coralogix.com` |
| `ap1.coralogix.com` | `https://ingress.ap1.coralogix.com` |
| `ap2.coralogix.com` | `https://ingress.ap2.coralogix.com` |
| `ap3.coralogix.com` | `https://ingress.ap3.coralogix.com` |

### 2. Load your credentials into the shell

Add this to your `~/.zshrc` (or `~/.bashrc`) so credentials are always available when you run `codex`:

```bash
if [ -f "/path/to/codex/.env" ]; then
  set -a; source "/path/to/codex/.env"; set +a
fi
```

Then reload:

```bash
source ~/.zshrc
```

### 3. Add the OTel block to Codex

Source your credentials and use `envsubst` to expand them into `~/.codex/config.toml`:

```bash
set -a; source .env; set +a
envsubst < config.toml.example >> ~/.codex/config.toml
```

Or if you don't have a config yet:

```bash
set -a; source .env; set +a
envsubst < config.toml.example > ~/.codex/config.toml
```

`envsubst` substitutes all `${VAR}` placeholders from `.env` before writing, so your credentials stay out of the config file.

> **Note:** Replace `/absolute/path/to/codex/.env` in the `~/.zshrc` snippet with the real path. Run `pwd` inside the `codex/` directory to get it.

### 4. Start Codex

```bash
codex
```

Run a session, then type `/exit` to flush telemetry. Logs appear in Coralogix under:

- **Application:** value of `CX_APPLICATION_NAME` (e.g. `codex`)
- **Subsystem:** value of `CX_SUBSYSTEM_NAME` (e.g. `codex-sessions`)

---

## Advanced configuration

| Option | Default | Purpose |
|---|---|---|
| `log_user_prompt` | `false` | Controls prompt text inclusion in standalone log records (`source logs`). Prompt text is always present in trace-embedded events (`source spans`) regardless of this setting — consider the privacy implications before enabling `trace_exporter` in sensitive environments. |
| `environment` | `"dev"` | Tag all events with an environment name |
| `exporter` | `"none"` | Set to `otlp-http` or `otlp-grpc` to enable log export |
| `trace_exporter` | `"none"` | Same options as `exporter`, enables trace export via OTLP |

See the [Codex CLI OTel docs](https://developers.openai.com/codex/config-advanced/#observability-and-telemetry) for the full reference.

---

## Repo-tracker hook (macOS)

Codex's native OTel events never say **which repository** a session worked in. The [`hooks/codex.sh`](hooks/codex.sh) PostToolUse hook fills that gap: on each tool use it emits an OTLP/JSON gauge metric

```
codex_session_repo_info{session_id, repository_name}
```

where `repository_name` is the checkout's `origin` URL (any `user:token@` userinfo stripped; a checkout with no remote reports its directory name, no git at all reports `unknown`). `session_id` equals the `conversation.id` on Codex's own log events (`codex.api_request`, `codex.sse_event`, …), so per-user or per-model repo breakdowns are a join on that id — the metric itself carries no user identity.

Since 1.1 the hook also counts, per (session × repo), cumulatively:

```
codex_session_commits{session_id, repository_name}
codex_session_prs_opened{session_id, repository_name}
```

**Commits are verified against git, never parsed out of command text**: the hook keeps the last `HEAD` it saw for the session in a private temp state file, and when `HEAD` has advanced linearly since (`merge-base --is-ancestor`), it adds the new commits authored by the machine's own `git config user.email`, matched against the raw author, never through `.mailmap`. **No commit is counted twice** (since 1.2; a 1.1 hook could recount): the state file keeps the SHA of every commit counted, so switching back to a branch or resetting away and back adds nothing. A non-linear move (a switch to a diverged branch, a rebase, an amend) re-baselines without counting; a pull adds none of other people's commits; a commit made as the session's very last action has no later tool call to be seen from and is missed — the count understates, never invents. **PRs count only on proof**: the tool command contains `gh pr create` and the tool response carries the `/pull/<n>` URL gh prints on success — an attempt that failed counts nothing, and a PR opened outside `gh` is invisible. Both totals are emitted on every tool call, zeros included: the series' presence is what lets a reader tell "measured, none" apart from "session ran an older hook". Counts only — no message, branch, or file ever rides their labels.

Since 1.2 the hook also measures, per (session × repo), cumulatively:

```
codex_session_lines_added{session_id, repository_name}
codex_session_lines_removed{session_id, repository_name}
```

**Lines are summed over exactly the commits `codex_session_commits` counts**: one `git log --numstat` call yields both the commits and their line counts, so the author filter, the no-recount rule, and the 5s bound are shared — every counting rule above applies unchanged, and binary files and merge commits contribute 0. **They measure the session's own commits, not what the agent typed**: a manual edit that lands in one of those commits is included, while uncommitted work and a commit made as the session's very last action are not — the totals understate, never invent. Both are emitted on every tool call, zeros included; a session that ran a hook older than 1.2 has no series at all, which is how "measured, none" stays distinguishable from "not measured". Sums only — no file name, path, or content ever rides a label.

Since 1.3 the hook also reports the branch each (session × repo) was on:

```
codex_session_branch_info{session_id, repository_name, branch_name}
```

**`branch_name` is the checked-out branch, `HEAD` when detached, and `unknown` when the lookup fails or times out, or next to the `unknown` repo when there is no git** — the same label name as the Claude Code repo-tracker; `symbolic-ref` resolves it, so a fresh repo with no commits still reports its branch, and a tag of the same name never turns it into `heads/<branch>`. **A session that switches branches keeps one series per branch it was seen on**, each at value 1, so `max by (session_id, repository_name, branch_name) (max_over_time(codex_session_branch_info[…]))` lists every branch the session was on when a tool call finished — a branch checked out and left within one tool call is never seen; linked worktrees of one repo on different branches each report theirs. **It is a gauge of its own, not a label on the others**: the branch never rides `codex_session_repo_info` or the counters, so no existing query changes and a branch switch never splits a running total. **Branch names are unbounded free text that often carries ticket ids, customer or feature names** — bucket them before charting, never chart raw names.

Since 1.4 a sub-agent's tool calls also name the sub-agent:

```
codex_session_repo_info{session_id, repository_name, agent_id}
```

**`agent_id` is set only inside a thread-spawned sub-agent**: it is the sub-agent's own thread id — the `conversation.id` its Codex log events, and so its tokens, carry — while `session_id` stays the root session's; a root-thread call has no `agent_id` label. **Without it a sub-agent's tokens have no repo to join to**, because no `session_id` equals their `conversation.id`; `max by (agent_id, repository_name) (last_over_time(codex_session_repo_info{agent_id!=""}[…]))` maps each sub-agent thread to the repos it touched. **Only `codex_session_repo_info` carries it**: commits, PRs, lines and branches stay per root session, and `max by (session_id, repository_name)` over the repo gauge reads exactly as before. A sub-agent call from a hook older than 1.4 has no `agent_id`, so its tokens stay unattributed — understated, never misassigned.

**Zero runtime assumptions**, same design as the [Claude Code repo-tracker](../claude-code/README.md#repo-tracker-hook-macos--windows): only tools that ship with macOS (`/bin/sh`, `plutil`, `awk`, `curl`), `git` optional, every git call bounded to 5s, all errors swallowed — the hook can never disturb or stall a session.

**No extra secrets:** the hook reads the same `~/.codex/config.toml` `[otel.exporter.otlp-http]` block installed in Setup above — `endpoint` (its `/v1/logs` suffix is swapped for `/v1/metrics`) and the `Authorization` / `CX-Application-Name` / `CX-Subsystem-Name` headers. `CX_*` environment variables (the names in `.env.example`) are read as fallbacks, and `--otlp-endpoint` / `--otlp-auth` / `--application-name` / `--subsystem-name` / `--config-file` flags exist for manual testing.

### Install

```bash
sudo cp hooks/codex.sh /usr/local/bin/codex-repo-tracker.sh
sudo chmod 755 /usr/local/bin/codex-repo-tracker.sh
```

Then register it — merge [`hooks/hooks.example.json`](hooks/hooks.example.json) into `~/.codex/hooks.json` (create the file if it doesn't exist):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "[ -x /usr/local/bin/codex-repo-tracker.sh ] && exec /bin/sh /usr/local/bin/codex-repo-tracker.sh; exit 0",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

Schema gotchas (all four break silently or with a cryptic error): event names are **PascalCase** (`PostToolUse`), `matcher` must be a valid **regex** (`".*"`, not `"*"`), the timeout key is **`timeout`** (seconds), and the file is `~/.codex/hooks.json` — not a key inside `config.toml`.

### Approve the hook (Codex's trust model)

Unlike Claude Code — where an MDM-managed settings file activates hooks fleet-wide — Codex requires **each user to approve hooks interactively**. On the next `codex` run after editing `hooks.json` you'll see `PostToolUse hooks · N hooks need review`; review and approve.

Approval state lives in `~/.codex/config.toml` under `[hooks.state]`, keyed by hook source, with **two separate flags**:

```toml
[hooks.state."/Users/you/.codex/hooks.json:post_tool_use:0:0"]
trusted_hash = "sha256:…"
enabled = true
```

A hook can be *trusted yet disabled* (`enabled = false`) — a silent no-op that looks exactly like a broken hook. If the metric never arrives, check this flag first. Any edit to `hooks.json` changes the hash and re-triggers the review prompt.

Verified on Codex CLI 0.149.1 and the ChatGPT desktop app 0.149.0-alpha.4.1 — both deliver the full PostToolUse event (`session_id`, `cwd`, `tool_input`, …) to the hook.

### Test locally

[`hooks/test-hook-local.sh`](hooks/test-hook-local.sh) spawns the hook exactly the way Codex does (`sh -c` + the event JSON on stdin, field shape captured from a live 0.149 session) and prints a unique `session_id` marker to look up in Coralogix:

```bash
./hooks/test-hook-local.sh
```

The hook swallows all errors and exits 0 by design, so exit 0 does **not** prove delivery — confirm with the printed `codex_session_repo_info{session_id="localtest-…"}` query.

---

## Dashboard

A pre-built dashboard is included at `coralogix-codex-dashboard.json`.

**To import:**
1. In your Coralogix tenant go to **Dashboards → New Dashboard**
2. Click the menu icon → **Import from JSON**
3. Paste the contents of `coralogix-codex-dashboard.json` and save

**Dashboard sections:**

| Section | What you see |
|---|---|
| **Sessions & User Activity** | Sessions per user · API requests per session · active users over time |
| **Tokens** | Total tokens per session · token breakdown by model · daily token usage |
| **Traces** | Slowest spans · span count by operation · avg + max duration per operation |

Log panels filter by `$d.resource.attributes['service.name'] == 'codex_cli_rs'`, which is stable across all client versions and works regardless of which application/subsystem the logs are routed to. Trace panels filter by `$d.serviceName == 'codex_cli_rs'`.
