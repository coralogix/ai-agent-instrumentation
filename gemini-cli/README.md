# Gemini CLI - Coralogix

Ship every Gemini CLI session — token usage, tool calls, API requests, model routing decisions, agent runs, and prompt logs — directly into Coralogix using Gemini CLI's built-in OpenTelemetry support.

No wrappers. No code changes to your projects. Gemini CLI emits OTLP natively; you just point it at your Coralogix ingress endpoint.

---

## How it works

```
Gemini CLI  →  OTLP/HTTP  →  Coralogix ingress  →  Metrics Explorer + Logs + Traces
```

Gemini CLI ships the full OpenTelemetry SDK and emits logs, metrics, and traces when `GEMINI_TELEMETRY_ENABLED=true` is set. This folder provides:

- `activate.sh` — exports all required env vars into your shell in one step
- `.env` — stores your Coralogix API key and endpoint (git-ignored)
- `settings.json.example` — optional `.gemini/settings.json` alternative to env vars

### Why gRPC, not HTTP

Gemini CLI's HTTP OTLP exporters (`@opentelemetry/exporter-*-otlp-http`) have `Content-Type: application/json` and `JsonTraceSerializer` hardcoded in source — there is no configuration or env var to switch them to protobuf. Coralogix accepts JSON OTLP requests (returns HTTP 200) but silently drops them without indexing.

The gRPC exporters use protobuf, which Coralogix ingests correctly. `@opentelemetry/exporter-*-otlp-proto` (HTTP protobuf) is bundled in Gemini CLI but never invoked by its telemetry code path.

### How auth and routing headers reach Coralogix

Gemini CLI's `settings.json` has no `headers` field. Instead, Gemini CLI constructs its OTLP exporters without hardcoded headers, so the standard `OTEL_EXPORTER_OTLP_HEADERS` env var is read as gRPC metadata by the underlying `@opentelemetry/exporter-*-otlp-grpc` packages. `activate.sh` sets this variable automatically with three values:

- `Authorization=Bearer <key>` — authenticates the request
- `CX-Application-Name=<name>` — routes data to the correct Coralogix application
- `CX-Subsystem-Name=<name>` — routes data to the correct Coralogix subsystem

---

## Signals sent to Coralogix

### Metrics

All metrics are emitted via OTLP and appear under **Metrics Explorer**. Search for `gemini_cli`.

| Metric | Attributes | What it tracks |
|---|---|---|
| `gemini_cli.session.count` | — | CLI startups |
| `gemini_cli.token.usage` | `model`, `type` (input / output / thought / cache / tool) | Token consumption |
| `gemini_cli.api.request.count` | `model`, `status_code` | API calls made |
| `gemini_cli.api.request.latency` | `model` | API round-trip time (ms) |
| `gemini_cli.tool.call.count` | `function_name`, `success`, `decision`, `tool_type` | Tool executions |
| `gemini_cli.tool.call.latency` | `function_name` | Tool execution time (ms) |
| `gemini_cli.file.operation.count` | `operation` (create / read / update) | File operations |
| `gemini_cli.lines.changed` | `type` (added / removed) | Lines of code changed |
| `gemini_cli.agent.run.count` | `agent_name`, `terminate_reason` | Agent runs |
| `gemini_cli.agent.duration` | `agent_name` | Agent run duration (ms) |
| `gemini_cli.agent.turns` | `agent_name` | Turns per agent run |

### Log events

Log events are routed to the subsystem you configure in `.env`. Query them in **Coralogix Logs** using DataPrime or Lucene.

| Event | Key attributes |
|---|---|
| `gemini_cli.user_prompt` | `session.id`, `prompt_length`, `prompt` (opt-in), `auth_type` |
| `gemini_cli.api_request` | `model`, `prompt_id`, `role` |
| `gemini_cli.api_response` | `model`, `status_code`, `duration_ms`, token counts, `finish_reasons` |
| `gemini_cli.api_error` | `error.message`, `model_name`, `status_code`, `error_type` |
| `gemini_cli.tool_call` | `function_name`, `duration_ms`, `success`, `decision`, `tool_type` |
| `gemini_cli.file_operation` | `tool_name`, `operation`, `lines`, `extension` |
| `gemini_cli.model_routing` | `decision_model`, `decision_source`, `routing_latency_ms` |
| `gemini_cli.agent.start` / `.finish` | `agent_id`, `agent_name`, `duration_ms`, `turn_count`, `terminate_reason` |
| `gemini_cli.config` | full session configuration at startup |
| `gemini_cli.conversation_finished` | `turnCount`, `approvalMode` |

Every signal carries `session.id`, `installation.id`, `active_approval_mode`, and `user.email` (when authenticated) as common attributes.

### Traces

Gemini CLI emits a trace per session covering the full turn lifecycle — LLM calls, tool executions, and agent runs — as nested spans. Find them in **Coralogix Tracing**.

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
export GEMINI_TELEMETRY_OTLP_PROTOCOL=http
export GEMINI_TELEMETRY_OTLP_ENDPOINT="${CX_OTLP_ENDPOINT}"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${CX_API_KEY},CX-Application-Name=${CX_APPLICATION_NAME},CX-Subsystem-Name=${CX_SUBSYSTEM_NAME}"
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

1. **Logs** — Go to **Logs** and filter by your subsystem name (e.g. `gemini-cli-sessions`). Look for a `gemini_cli.config` event emitted at startup.
2. **Metrics** — Go to **Metrics Explorer** and search for `gemini_cli`. Token usage and API request metrics appear within one export interval (~10 seconds).
3. **Traces** — Go to **Tracing** and filter by service name `gemini-cli`.

---

## Advanced configuration

| Variable | Default | Purpose |
|---|---|---|
| `GEMINI_TELEMETRY_LOG_PROMPTS` | `false` | Set to `true` to include prompt text in `gemini_cli.user_prompt` log events |
| `GEMINI_TELEMETRY_ENABLED` | `false` | Master toggle for all telemetry |
| `GEMINI_TELEMETRY_TARGET` | `local` | `local` = custom OTLP endpoint; `gcp` = Google Cloud |
| `GEMINI_TELEMETRY_OTLP_ENDPOINT` | `http://localhost:4317` | OTLP collector or ingress URL |
| `GEMINI_TELEMETRY_OTLP_PROTOCOL` | `grpc` | `grpc` for Coralogix (recommended); `http` sends JSON which Coralogix drops |
| `OTEL_EXPORTER_OTLP_HEADERS` | — | Auth and routing headers sent on every OTLP request |
| `OTEL_RESOURCE_ATTRIBUTES` | — | Extra resource dimensions, e.g. `team=platform,env=prod` |
