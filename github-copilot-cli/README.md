# GitHub Copilot CLI → Coralogix (native OpenTelemetry)

Ship GitHub Copilot CLI activity to Coralogix using Copilot's **native
OpenTelemetry** — no lifecycle hooks, no OpenTelemetry Collector, no file
exporter, no uploader script. Just environment variables.

The Copilot CLI has built-in OTel (`copilot help monitoring`) following the
[OTel GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/),
and it exports **both traces (GenAI spans) and metrics** over OTLP. Pointed at
Coralogix's OTLP ingress with the right auth/routing headers, it talks to
Coralogix directly:

```
copilot --(native OTLP)--> https://ingress.<region>.coralogix.com
         traces + metrics, incl. prompt/response content
```

Everything is configured through a single sourceable env file
([`copilot-coralogix.env`](./copilot-coralogix.env)).

---

## What lands in Coralogix

Telemetry arrives under application `copilot-cli`, service `github-copilot`:

### Traces — GenAI spans
`invoke_agent` → `chat <model>` / `execute_tool <tool>`, with attributes like
`gen_ai.request.model`, `gen_ai.usage.input_tokens`,
`gen_ai.usage.output_tokens`, and `github.copilot.cost`. With content capture
on (the default), each `chat` span also carries the conversation:

- `gen_ai.input.messages` — the user prompt(s)
- `gen_ai.output.messages` — the assistant response (incl. reasoning)
- `gen_ai.system_instructions` — the system prompt
- `gen_ai.tool.definitions` — available tool schemas

### Metrics
Copilot's native GenAI metrics (token usage, request counts, cost) over the same
OTLP endpoint.

### AI-session dataset
Every span carries `cx.integration.source.type=copilot_cli_agent` (and
`cx.integration.source.version`). Per the `#tmp-ai-session-dataset` agreement
(Jira **CX-46024**), this lets ingestion detect the telemetry as an AI-session
source and route it to the dedicated `ai.sessions.*` dataset (entity type
`aiSessionsCopilot`) — the Copilot counterpart of Claude Code's
`claude_code_agent`. `user.email` is attached so usage attributes to a real
person rather than only Copilot's anonymized `enduser.pseudo.id`.

---

## Setup

1. **Install the env file** and fill in your Coralogix key:

   ```bash
   mkdir -p ~/.copilot
   cp copilot-coralogix.env ~/.copilot/coralogix.env
   chmod 600 ~/.copilot/coralogix.env          # it holds your API key
   # edit ~/.copilot/coralogix.env → replace <your-send-your-data-api-key>
   ```

2. **Pick your region's endpoint** in the file (`OTEL_EXPORTER_OTLP_ENDPOINT`),
   default is `eu2`:

   | Domain | `OTEL_EXPORTER_OTLP_ENDPOINT` |
   |---|---|
   | `us1.coralogix.com` | `https://ingress.us1.coralogix.com` |
   | `us2.coralogix.com` | `https://ingress.us2.coralogix.com` |
   | `eu1.coralogix.com` | `https://ingress.eu1.coralogix.com` |
   | `eu2.coralogix.com` | `https://ingress.eu2.coralogix.com` |
   | `ap1.coralogix.com` | `https://ingress.ap1.coralogix.com` |
   | `ap2.coralogix.com` | `https://ingress.ap2.coralogix.com` |
   | `ap3.coralogix.com` | `https://ingress.ap3.coralogix.com` |

3. **Source it, then run Copilot** — best is to source it automatically from
   your shell rc so every session is instrumented:

   ```bash
   echo '[ -f "$HOME/.copilot/coralogix.env" ] && . "$HOME/.copilot/coralogix.env"' >> ~/.zshrc
   # then, in a new shell:
   copilot -p "explain this repo" --allow-all-tools
   ```

   Or just `source ~/.copilot/coralogix.env` in the shell you run `copilot` from.

---

## Configuration

All settings live in `copilot-coralogix.env` and are **required** (the resource
attributes and the IPv6 fix included). Why each one is needed:

| Variable | Set to | Why it's needed |
|---|---|---|
| `COPILOT_OTEL_ENABLED` | `true` | Master switch for Copilot's built-in OpenTelemetry. Without it Copilot emits no telemetry at all, so nothing else here has any effect. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `https://ingress.<region>.coralogix.com` | Where the OTLP exporter ships traces + metrics. Points Copilot at **your** Coralogix region's ingress — a wrong/missing region means the data never arrives. |
| `OTEL_EXPORTER_OTLP_HEADERS` | `Authorization=Bearer <cxtp_ key>,CX-Application-Name=copilot-cli,CX-Subsystem-Name=copilot-sessions` | Authenticates and routes the export. The Bearer key is the credential (Coralogix rejects with 401 without it); the `CX-Application-Name` / `CX-Subsystem-Name` headers decide which application/subsystem the telemetry files under. |
| `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` | `true` | Captures the actual prompt / response / system-prompt / tool-schema **text** into the GenAI spans. `false` keeps only metadata (token counts, model, cost). Required if you want to see the conversation, not just stats. |
| `OTEL_SERVICE_NAME` | `github-copilot` | Sets the resource `service.name` — the identity the telemetry appears under in Coralogix (service grouping, APM/trace views). Without it spans land under a generic/unknown service. |
| `OTEL_RESOURCE_ATTRIBUTES` | `user.email=$(git config user.email …),cx.integration.source.type=copilot_cli_agent,cx.integration.source.version=1.0.0` | `user.email` attributes usage to a real person instead of only Copilot's anonymized `enduser.pseudo.id`. `cx.integration.source.*` tags the stream as an AI-session source so ingestion routes it to the dedicated `ai.sessions.*` dataset (CX-46024) instead of regular logs. |
| `NODE_OPTIONS` | `--dns-result-order=ipv4first` | Copilot's OTLP client tries IPv6 first and does **not** fall back to IPv4; on a host with no IPv6 route every export fails with `HTTP export failed: network error`. This makes Node resolve IPv4 first. Harmless where IPv6 works. |

> **Privacy:** with `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`
> (the default), full prompt, response, system-prompt and tool-schema **text** —
> including code and file contents — is sent to Coralogix. Set it to `false` to
> ship metadata only (token counts, model, cost). Copilot's own default is
> `false`; this integration defaults to `true`. Only enable content capture in
> trusted environments.

> **IPv6:** Coralogix's ingress has an AAAA record and Copilot's OTLP client
> tries IPv6 first **without** falling back to IPv4 — on a host with no IPv6
> route, every export fails with `HTTP export failed: network error`.
> `NODE_OPTIONS=--dns-result-order=ipv4first` makes Node resolve IPv4 first (no
> sudo, no host pin). If that isn't enough, pin the A record once:
> `echo "$(dig +short A ingress.eu2.coralogix.com | head -1) ingress.eu2.coralogix.com" | sudo tee -a /etc/hosts`.

---

## Fleet deployment (Jamf)

`jamf-deploy.sh` installs `~/.copilot/coralogix.env` for the **logged-in console
user** and wires it into their shell rc, fleet-wide via a Jamf Pro policy. Jamf
runs scripts as root, so the script detects the console user and writes to
*their* home.

Add it as a Jamf script and set the parameters:

| Param | Meaning | Example |
|---|---|---|
| `$4` | Coralogix Send-Your-Data API key | `cxtp_…` |
| `$5` | OTLP endpoint (or bare region domain) | `https://ingress.eu2.coralogix.com` |
| `$6` | Application name | `copilot-cli` |
| `$7` | Subsystem name | `copilot-sessions` |
| `$8` | Mode | `full` (capture content, default) · `metadata` (no text) |
| `$9` | `uninstall` to remove | |

The script writes the env file (chmod 600 — it holds the API key) and adds a
guarded `source` line to the user's `~/.zshrc` and `~/.bash_profile`. The same
parameters also work as environment variables for other MDMs (Intune, Ansible).

---

## Verify

Run a Copilot session, then query the spans (use a `cxup_` query key; a `cxtp_`
ingest key has no query scope):

```bash
# Recent spans for this app
cx spans "limit 20" --start now-30m

# Confirm captured content is present
cx spans "limit 50" --start now-30m -o json | grep -o 'gen_ai.input.messages'
```

---

## Requirements

- The GitHub Copilot CLI (`copilot help monitoring` shows the OTel support).
- `git` on the `PATH` (used to resolve `user.email` for the resource attribute).
- A Coralogix Send-Your-Data API key (**Settings → API Keys**).
