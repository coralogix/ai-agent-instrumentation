# Codex CLI - Coralogix

Forward every Codex CLI session — API requests, tool calls, SSE events, and prompt activity — directly into Coralogix using Codex's built-in OpenTelemetry support.

No wrappers. No code changes. Codex emits OTLP natively; you just point it at your Coralogix ingress endpoint via `~/.codex/config.toml`.

---

## How it works


Codex CLI emits telemetry via OTel when the `[otel]` block is configured in `~/.codex/config.toml`. This folder provides:

- `config.toml.example` — the OTel block to merge into your Codex config
- `.env.example` — stores your Coralogix credentials (git-ignored)
- `coralogix-codex-dashboard.json` — pre-built dashboard ready to import into Coralogix

Codex supports two external OTel pipelines: `exporter` (logs) and `trace_exporter` (traces). The `metrics_exporter` key defaults to Codex's internal Statsig pipeline and does not support `otlp-http` — metric-like counters (`codex.api_request`, `codex.tool.call`, etc.) are available as structured fields on log events via the `exporter` pipeline.

---

## Signals sent to Coralogix

### Log events

| Event | Key attributes |
|---|---|
| `codex.conversation_starts` | `session.id`, `model`, `approval_policy`, `sandbox_mode` |
| `codex.api_request` | `session.id`, `model`, `status`, `success`, `duration_ms` |
| `codex.sse_event` | `session.id`, `event.kind`, `success`, `duration_ms` (token counts on `response.completed`) |
| `codex.websocket_request` | `session.id`, `success`, `duration_ms` |
| `codex.websocket_event` | `session.id`, `event.kind`, `success`, `duration_ms` |
| `codex.user_prompt` | `session.id`, `length` (content redacted unless `log_user_prompt = true`) |
| `codex.tool_decision` | `session.id`, `tool_name`, `decision`, `source` |
| `codex.tool_result` | `session.id`, `tool_name`, `arguments`, `output`, `success`, `duration_ms` |

### Traces

Codex emits a trace per session when `trace_exporter` is configured. Spans cover the full turn lifecycle including API calls and tool executions.

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
| `log_user_prompt` | `false` | Set to `true` to include prompt text in `codex.user_prompt` log events |
| `environment` | `"dev"` | Tag all events with an environment name |
| `exporter` | `"none"` | Set to `otlp-http` or `otlp-grpc` to enable log export |
| `trace_exporter` | *(unset)* | Same options as `exporter`, enables trace export |

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

All panels use DataPrime queries filtered by `originator = codex_cli_rs`, so they work regardless of which application/subsystem the logs are routed to.
