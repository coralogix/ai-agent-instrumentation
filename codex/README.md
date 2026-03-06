# Codex CLI → Coralogix

Forward every Codex CLI session — API requests, tool calls, SSE events, and prompt activity — directly into Coralogix using Codex's built-in OpenTelemetry support.

No wrappers. No code changes. Codex emits OTLP natively; you just point it at your Coralogix ingress endpoint via `~/.codex/config.toml`.

---

## How it works

```
Codex CLI  →  OTLP/HTTP  →  Coralogix ingress  →  Logs + Traces
```

Codex CLI emits telemetry via OTel when the `[otel]` block is configured in `~/.codex/config.toml`. This folder provides:

- `config.toml.example` — the OTel block to merge into your Codex config
- `.env.example` — stores your Coralogix credentials (git-ignored)

> **Metrics export** is not yet supported by Codex CLI — see [openai/codex#10277](https://github.com/openai/codex/issues/10277).

---

## Signals sent to Coralogix

### Log events

| Event | Key attributes |
|---|---|
| `codex.conversation_starts` | `session.id`, `model`, `approval_policy`, `sandbox_mode` |
| `codex.api_request` | `session.id`, `model`, `status`, `success`, `duration_ms` |
| `codex.sse_event` | `session.id`, `kind`, `success`, `duration_ms` |
| `codex.user_prompt` | `session.id`, `length` (content redacted unless `log_user_prompt = true`) |
| `codex.tool_decision` | `session.id`, `tool`, `approved`, `source` |
| `codex.tool_result` | `session.id`, `tool`, `success`, `duration_ms` |

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
