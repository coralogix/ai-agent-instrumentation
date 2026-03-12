# Gemini CLI - Coralogix

Ship every Gemini CLI session — token usage, tool calls, API requests, model routing decisions, agent runs, and prompt logs — directly into Coralogix using Gemini CLI's built-in OpenTelemetry support.

No wrappers. No code changes to your projects. Gemini CLI emits OTLP natively; you just point it at your Coralogix ingress endpoint.

---

## How it works

```
Gemini CLI  →  OTLP/gRPC  →  Coralogix ingress  →  Metrics Explorer + Logs + Traces
```

Gemini CLI ships the full OpenTelemetry SDK and emits logs, metrics, and traces when `GEMINI_TELEMETRY_ENABLED=true` is set. This folder provides:

- `activate.sh` — exports all required env vars into your shell in one step
- `.env` — stores your Coralogix API key and endpoint (git-ignored)
- `settings.json.example` — optional `.gemini/settings.json` alternative to env vars

### How auth and routing headers reach Coralogix

Gemini CLI's `settings.json` has no `headers` field. Instead, Gemini CLI constructs its OTLP exporters without hardcoded headers, so the standard `OTEL_EXPORTER_OTLP_HEADERS` env var is read as gRPC metadata by the underlying `@opentelemetry/exporter-*-otlp-grpc` packages. `activate.sh` sets this variable automatically with three values:

- `authorization=Bearer <key>` — authenticates the request
- `cx-application-name=<name>` — routes data to the correct Coralogix application
- `cx-subsystem-name=<name>` — routes data to the correct Coralogix subsystem

---

## Signals sent to Coralogix

Gemini CLI emits logs, metrics, and traces via OTLP. For the full signal reference — event names, metric names, attributes, and trace span structure — see the [Gemini CLI telemetry documentation](https://geminicli.com/docs/cli/telemetry/).

Once data is flowing, metrics appear in **Metrics Explorer** (search `gemini_cli`), logs in **Logs**, and traces in **Tracing** filtered by service name `gemini-cli`.

---

## Setup

### 1. Install Gemini CLI

```bash
npm install -g @google/gemini-cli
```

### 2. Authenticate

Run `gemini` and choose **Sign in with Google** when prompted, or set a Gemini API key:

```bash
# Option A: Google account (free tier — 60 req/min, 1000 req/day)
gemini   # follow browser OAuth flow

# Option B: API key
export GEMINI_API_KEY="your-key-from-aistudio.google.com"
gemini
```

### 3. Configure your Coralogix credentials

```bash
cp .env.example .env
```

Open `.env` and fill in:

```
CX_API_KEY=<your-send-your-data-api-key>
CX_OTLP_ENDPOINT=https://ingress.eu1.coralogix.com
CX_APPLICATION_NAME=gemini-cli
CX_SUBSYSTEM_NAME=gemini-cli-sessions
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

### 4. Activate telemetry and start Gemini CLI

```bash
source activate.sh
gemini
```

`activate.sh` exports all OTEL variables into your current shell. It must be sourced (not executed) so the variables persist. Re-run it in each new terminal, or see the persistent setup below.

### 5. Make it permanent (recommended)

Add the following to `~/.zshrc` (or `~/.bashrc`) so every terminal automatically has telemetry enabled:

```bash
if [ -f "$HOME/path/to/gemini-cli/.env" ]; then
  set -a; source "$HOME/path/to/gemini-cli/.env"; set +a
fi
export GEMINI_TELEMETRY_ENABLED=true
export GEMINI_TELEMETRY_TARGET=local
export GEMINI_TELEMETRY_OTLP_PROTOCOL=grpc
export GEMINI_TELEMETRY_OTLP_ENDPOINT="${CX_OTLP_ENDPOINT}"
export OTEL_EXPORTER_OTLP_HEADERS="authorization=Bearer ${CX_API_KEY},cx-application-name=${CX_APPLICATION_NAME},cx-subsystem-name=${CX_SUBSYSTEM_NAME}"
export OTEL_RESOURCE_ATTRIBUTES="cx.application.name=${CX_APPLICATION_NAME},cx.subsystem.name=${CX_SUBSYSTEM_NAME}"
```

Then reload:

```bash
source ~/.zshrc
```

### Alternative: settings.json

Instead of env vars, you can configure the endpoint in `~/.gemini/settings.json`. Copy `settings.json.example` and update the endpoint to match your region:

```bash
cp settings.json.example ~/.gemini/settings.json
```

> **Note:** `settings.json` has no `headers` field, so `OTEL_EXPORTER_OTLP_HEADERS` must still be set as an env var for authentication to work — even when using this file.

---

## Verify data is flowing

After running a session, check that telemetry arrived in Coralogix:

1. **Logs** — Go to **Logs** and filter by application name `gemini-cli` and subsystem name `gemini-cli-sessions`. Search for `logRecord.body:"CLI configuration loaded."` to find the startup config event emitted at the beginning of every session.
2. **Metrics** — Go to **Metrics Explorer** and search for `gemini-cli`. Token usage and API request metrics appear within one export interval (~10 seconds).
3. **Traces** — Go to **Tracing** and filter by service name `gemini-cli`.

> **Note on prompt privacy:** `activate.sh` sets `GEMINI_TELEMETRY_LOG_PROMPTS=false` to suppress prompt logging. However, when using the `-p` flag (e.g. `gemini -p "your prompt"`), the prompt appears in `process.command_args` resource attributes regardless of this setting — the OTel Node.js SDK captures all process arguments automatically. Use interactive mode (`gemini`, then type your prompt) to keep prompt content out of telemetry.

---

## Pre-built dashboard

`coralogix-gemini-cli-dashboard.json` is a ready-to-import Coralogix dashboard covering all Gemini CLI telemetry signals.

### Import

1. In Coralogix, go to **Dashboards** and click **New Dashboard → Import**.
2. Upload `coralogix-gemini-cli-dashboard.json`.
3. The dashboard loads immediately — no further configuration needed.

### Sections and panels

| Section | Panels |
|---|---|
| **Overview** | Sessions (24h), Total Tokens (24h), Input Tokens (24h), Output Tokens (24h), API Errors (24h), Tool Success Rate (24h) |
| **Session activity** | Sessions over time, Model distribution |
| **Token usage & efficiency** | Token volume by type, Token volume by model, Cache token ratio %, Thought tokens over time, Avg tokens per session |
| **API performance** | API requests per minute, API latency p50/p90/p99, Error rate over time, Errors by type, Status code distribution |
| **Tool usage** | Tool calls over time, Top tools by call count, Tool success rate by function, Tool latency by function, Decision breakdown (accept/reject/auto_accept/modify), MCP vs native split |
| **File operations** | File operations over time by type, Lines changed over time |

The **Agent runs** and **Resilience & errors** section stubs are included and ready to extend once you have agent or retry data flowing.

### Confirmed metric names

Coralogix inserts the OTel unit into the Prometheus metric name on ingestion. The actual names differ from the OTel spec names:

| OTel metric | Prometheus name in Coralogix |
|---|---|
| `gemini_cli.session.count` | `gemini_cli_session_count_total` |
| `gemini_cli.token.usage` | `gemini_cli_token_usage_total` |
| `gemini_cli.api.request.count` | `gemini_cli_api_request_count_total` |
| `gemini_cli.api.request.latency` | `gemini_cli_api_request_latency_ms_{bucket,sum,count,max,min}` |
| `gemini_cli.tool.call.count` | `gemini_cli_tool_call_count_total` |
| `gemini_cli.tool.call.latency` | `gemini_cli_tool_call_latency_ms_{bucket,sum,count,max,min}` |
| `gemini_cli.model_routing.latency` | `gemini_cli_model_routing_latency_ms_{bucket,sum,count,max,min}` |
| `gemini_cli.file.operation.count` | `gemini_cli_file_operation_count_total` |
| `gemini_cli.lines.changed` | `gemini_cli_lines_changed_total` |

### Log field paths

Log events use `$d.logRecord.attributes['event.name']` for the event name (not the body). Common DataPrime filter pattern:

```
source logs | filter $d.logRecord.attributes['event.name'] == 'gemini_cli.api_error'
```

---

For the full list of Gemini CLI telemetry configuration variables, see the [Gemini CLI configuration reference](https://geminicli.com/docs/reference/configuration).
