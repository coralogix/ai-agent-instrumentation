# Codex CLI - Coralogix

Forward every Codex CLI session — API requests, tool calls, SSE events, and prompt activity — directly into Coralogix using Codex's built-in OpenTelemetry support.

No wrappers. No code changes. Codex emits OTLP natively; you just point it at your Coralogix ingress endpoint via `~/.codex/config.toml`.

---

## How it works


Codex CLI emits telemetry via OTel when the `[otel]` block is configured in `~/.codex/config.toml`. This folder provides:

- `config.toml.example` — the OTel block to merge into your Codex config
- `.env.example` — stores your Coralogix credentials (git-ignored)
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
