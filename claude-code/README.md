# Claude Code → Coralogix

Ship every Claude Code session — token usage, costs, code changes, tool decisions, and prompt logs — directly into Coralogix using Claude Code's built-in OpenTelemetry support.

No agents. No wrappers. No code changes to your projects. Claude Code emits OTLP natively; you just point it at your Coralogix ingress endpoint.

---

## How it works

```
Claude Code  →  OTLP/HTTP  →  Coralogix ingress  →  Metrics Explorer + Logs + Dashboards
```

Claude Code exposes telemetry via the OpenTelemetry SDK when `CLAUDE_CODE_ENABLE_TELEMETRY=1` is set. This repo provides:

- `activate.sh` — exports all required env vars into your shell in one step
- `.env` — stores your Coralogix API key and endpoint (git-ignored)
- `coralogix-dashboard.json` — a pre-built dashboard ready to import
- `ping.py` — sends a test payload to confirm the pipeline is working end-to-end

---

## Signals sent to Coralogix

### Metrics

All metrics use **delta temporality** — the format Coralogix expects for counters. They show up under **Metrics Explorer** when you search `claude_code`.

| Metric | Labels | What it tracks |
|---|---|---|
| `claude_code_session_count_1_total` | `session.id`, `user.id` | Sessions started |
| `claude_code_session_count_total` | — | Session count (no extra labels) |
| `claude_code_token_usage_1_total` | `model`, `type` | Tokens by model and type (input / output / cache) |
| `claude_code_token_usage_tokens_total` | — | Raw token count from API calls |
| `claude_code_cost_usage_USD_total` | `model` | Estimated USD cost per model |
| `claude_code_lines_of_code_count_1_total` | `change_type` | Lines added and removed |
| `claude_code_lines_of_code_count_total` | — | Total lines changed |
| `claude_code_commit_count_total` | — | Git commits made |
| `claude_code_code_edit_tool_decision_total` | `decision` | Accept / reject on code edits |
| `claude_code_active_time_total_s_total` | — | Seconds Claude was actively processing |

### Log events

Log events are routed to the subsystem you configure in `.env`. Query them in **Coralogix Logs** using DataPrime or Lucene.

| Event type | Key attributes |
|---|---|
| `claude_code.user_prompt` | `session.id`, `user.id`, `prompt` (opt-in), `model` |
| `claude_code.api_request` | `model`, token counts, cost, latency |
| `claude_code.api_error` | `status`, error message |
| `claude_code.tool_result` | tool name, duration, outcome |

Every signal carries `session.id`, `user.id`, `user.email`, `organization.id`, `app.version`, and `terminal.type`.

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
CX_APPLICATION_NAME=claude-code
CX_SUBSYSTEM_NAME=claude-code-sessions
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

### 2. Activate telemetry and start Claude

```bash
source activate.sh
claude
```

`activate.sh` exports all OTEL variables into your current shell. It must be sourced (not executed) so the variables persist. Re-run it in each new terminal, or see the persistent setup below.

### 3. Make it permanent (recommended)

Add the following to `~/.zshrc` (or `~/.bashrc`) so every terminal automatically has telemetry enabled:

```bash
if [ -f "$HOME/path/to/claude-code-coralogix/.env" ]; then
  set -a; source "$HOME/path/to/claude-code-coralogix/.env"; set +a
fi
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT="${CX_OTLP_ENDPOINT}"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${CX_API_KEY}"
export OTEL_RESOURCE_ATTRIBUTES="cx.application.name=${CX_APPLICATION_NAME},cx.subsystem.name=${CX_SUBSYSTEM_NAME}"
export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta
```

Or use Claude Code's own settings file at `~/.config/claude-code/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://ingress.eu1.coralogix.com",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer <YOUR_CX_API_KEY>",
    "OTEL_RESOURCE_ATTRIBUTES": "cx.application.name=<APP>,cx.subsystem.name=<SUBSYSTEM>",
    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "delta"
  }
}
```

---

## Test the pipeline

Before a real session, send a synthetic payload to confirm Coralogix is receiving data:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python3 ping.py
```

Then in Coralogix:
- **Metrics Explorer** → search `claude_code` — test counters should appear within seconds
- **Logs** → filter `subsystemName = claude-code-sessions` — test log events appear there

---

## Pre-built dashboard

Import `coralogix-dashboard.json` for an instant view of all signals.

**Sections:**

| Section | What you see |
|---|---|
| **KPI Bar** | Sessions · Cost · Tokens · Active Time · Lines Changed · Commits — all as number cards |
| **Session Activity** | Sessions over time · Avg duration · Tokens per session |
| **Cost & Token Breakdown** | Cost/session · Cost by model · Tokens by model · Tokens by type · API token volume · Cost per token |
| **Code Impact** | Lines added/removed by type · Commits over time · Aggregate line changes |
| **Code Edit Behaviour** | Acceptance rate arc gauge · Decisions by type · Decision volume over time |
| **Prompt Log** | Live DataPrime table — timestamp · user · session · model · prompt text |

**To import:**
1. In your Coralogix tenant go to **Dashboards → New Dashboard**
2. Click the menu icon → **Import from JSON**
3. Paste the contents of `coralogix-dashboard.json` and save

---

## Advanced configuration

| Variable | Default | Purpose |
|---|---|---|
| `OTEL_METRIC_EXPORT_INTERVAL` | `60000` ms | How often metrics are flushed — lower to `10000` when testing |
| `OTEL_LOGS_EXPORT_INTERVAL` | `5000` ms | Log flush interval |
| `OTEL_LOG_USER_PROMPTS` | off | Set to `1` to include prompt text in `claude_code.user_prompt` log events |
| `OTEL_LOG_TOOL_DETAILS` | off | Set to `1` to add MCP server and tool names to tool events |
| `OTEL_RESOURCE_ATTRIBUTES` | — | Add custom dimensions, e.g. `team=platform,env=prod` |
| `OTEL_METRICS_INCLUDE_SESSION_ID` | `true` | Attaches `session.id` to metric labels — disable to reduce cardinality |
| `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` | `true` | Attaches `user.account_uuid` to metric labels |
