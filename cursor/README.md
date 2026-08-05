# Cursor - Coralogix

Ship every Cursor agent session — prompts, tool calls, shell executions, file edits, and MCP calls — directly into Coralogix as OTLP traces.

No wrappers. No code changes. Uses Cursor's native agent hooks system; a Python script converts each event to an OTLP protobuf span and POSTs it to your Coralogix ingress endpoint.

---

## How it works

Cursor exposes a `~/.cursor/hooks.json` file that registers shell commands to be called at every agent lifecycle event. Each hook receives a JSON payload on stdin describing the event.

```
Cursor agent event
      │
      ▼
~/.cursor/hooks/coralogix_hook.sh   (wrapper, loads credentials)
      │
      ▼
extension/resources/hook.py         (Python: stdin → OTLP protobuf span → POST /v1/traces)
      │
      ▼
Coralogix OTLP endpoint
```

On Windows the wrapper is `coralogix_hook.cmd` → `coralogix_hook.ps1` (the `.cmd` shim is what Cursor can reliably execute); it loads the same credentials and runs the same `hook.py`.

All spans within a session share the same `traceId`, with `cursor.sessionStart` as the root span. A full agent run appears as a single trace in Coralogix Visual Explorer.

---

## Deployment options

| | Audience | How |
|---|---|---|
| **Install script** (`install.sh` on macOS/Linux, `install.ps1` on Windows) | Individual install or org-wide using MDM | CLI flags, env vars, or a `.env` file |
| **Extension** (`.vsix`) | Individual / GUI | Install in Cursor, enter credentials in Settings UI |

---

## Option 1 — Install script

Works for both local setup and org-wide MDM deployment (Jamf, Intune, Ansible, etc.). Use `install.sh` on macOS and Linux, `install.ps1` on Windows — both take the same options and write the same configuration.

### Local setup with a .env file

Create a `.env` file with your credentials:

```
CX_API_KEY=<your-send-your-data-api-key>
CX_OTLP_ENDPOINT=https://ingress.<your-region>.coralogix.com  # see region table below
CX_APPLICATION_NAME=cursor
CX_SUBSYSTEM_NAME=cursor-sessions

# Optional
# Masked by default. Set to false to send full prompt and response text to Coralogix.
CURSOR_MASK_PROMPTS=true
CURSOR_OMIT_PRE_TOOL_USE_SPANS=false
CX_OTLP_DEBUG=false
```

Then run:

```bash
./install.sh --env-file .env
```

### Local setup with flags

```bash
./install.sh --api-key <key> --endpoint https://ingress.eu2.coralogix.com
```

### MDM / automated deployment

Inject credentials via environment variables from your secrets manager:

```bash
CX_API_KEY=xxx CX_OTLP_ENDPOINT=xxx CX_APPLICATION_NAME=cursor CX_SUBSYSTEM_NAME=cursor-sessions ./install.sh
```

The hook is installed per-user (`~/.cursor` / `%USERPROFILE%\.cursor`), so the MDM must run the installer in the target user's context (e.g. an Intune user-context assignment, a Jamf login policy) — not as SYSTEM/root against the machine.

**MDM deployment notes** (how you deploy is up to you; these save the common pitfalls):

- **User context is the #1 pitfall.** An MDM agent's default identity is root/SYSTEM; run that way, the installer writes into a profile Cursor never reads — the policy reports success and no data arrives. Jamf: execute the installer as the console user (e.g. `launchctl asuser <uid> sudo -u <user> -H`); Intune: package as a Win32 app with install behavior *User*, assigned to a user group. Detection rule: `%USERPROFILE%\.cursor\hooks\coralogix_hook.cmd` exists.
- **Machine-wide alternative:** Cursor also reads a system-level `hooks.json` (`/Library/Application Support/Cursor/hooks.json`, `C:\ProgramData\Cursor\hooks.json`, `/etc/cursor/hooks.json`), which suits MDMs' native root/SYSTEM mode — one install covers every user of the machine. If you go that route: place `hook.py`, the wrapper, and the env file at a machine path readable by all users, and install the two Python packages machine-wide (e.g. a dedicated venv) — a `pip install --user` under root/SYSTEM is invisible to real users. Verify your Cursor plan loads system-level hooks on one machine before fleet rollout.
- **Credentials:** inject `CX_API_KEY` (and the other three values) from your MDM's secrets/variable mechanism rather than hardcoding them in a saved policy, where anyone with policy read access can see them.
- **Python 3.8+** must exist on the endpoints (`python3` on macOS via Xcode CLT; `python`/`py -3` on Windows) — distribute it via MDM if your fleet lacks it. Without it the hook is silently inert.
- The installers are **idempotent** (safe to re-run on every check-in cycle) and reversible (`--uninstall` / `-Uninstall` for offboarding).
- **Avoid double-deployment:** a machine with both a per-user install and any other delivery of the same hook (machine-wide or Cursor Enterprise team hooks) sends duplicate spans — pick one mechanism per fleet.

### All options

```bash
./install.sh \
  --api-key       <key>      # required (or CX_API_KEY env var)
  --endpoint      <url>      # required — your region's OTLP ingress (see table below)
  --application   <name>     # required (conventional: cursor)
  --subsystem     <name>     # required (conventional: cursor-sessions)
  --mask-prompts             # optional, replace prompts with [MASKED] (default)
  --no-mask-prompts          # optional, send full prompt/response text
  --omit-pre-tool-use        # optional, skip preToolUse spans
  --debug                    # optional, print span IDs to stderr
  --env-file      <path>     # optional, load credentials from a .env file
```

### Uninstall

```bash
./install.sh --uninstall
```

The script is idempotent — safe to re-run on every provisioning cycle.

### Windows

Requires Python 3.8+ reachable as `python`, `py -3`, or `python3`. Windows PowerShell 5.1 (preinstalled on Windows 10/11) is enough — no `pwsh` needed.

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -EnvFile .env
```

With flags instead of a `.env` file:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -ApiKey <key> -Endpoint https://ingress.eu2.coralogix.com
```

All options:

| Flag | Notes |
|---|---|
| `-ApiKey <key>` | required (or `CX_API_KEY` env var) |
| `-Endpoint <url>` | required — your region's OTLP ingress (see table below) |
| `-Application <name>` | required (conventional: `cursor`) |
| `-Subsystem <name>` | required (conventional: `cursor-sessions`) |
| `-MaskPrompts` | replace prompts with `[MASKED]` (default) |
| `-NoMaskPrompts` | send full prompt/response text |
| `-OmitPreToolUse` | skip `preToolUse` spans |
| `-OtlpDebug` | print span IDs to stderr |
| `-EnvFile <path>` | load credentials from a `.env` file |
| `-HookSource <path>` | path to `hook.py` |

For MDM deployment (Intune, SCCM, PDQ), inject credentials as environment variables:

```powershell
$env:CX_API_KEY = 'xxx'; $env:CX_OTLP_ENDPOINT = 'xxx'; $env:CX_APPLICATION_NAME = 'cursor'; $env:CX_SUBSYSTEM_NAME = 'cursor-sessions'
powershell -ExecutionPolicy Bypass -File install.ps1
```

The hook installs into the signed-in user's profile (`%USERPROFILE%\.cursor`), so the deployment must run in the **user's context** — e.g. an Intune Win32 app with install behavior set to *User*, assigned to a user group. A SYSTEM-context run reports success but installs into a profile Cursor never reads.

Uninstall:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Files land in `%USERPROFILE%\.cursor\hooks\` and the hook is registered in `%USERPROFILE%\.cursor\hooks.json`.

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

---

## Option 2 — VS Code / Cursor Extension

Install `cursor-coralogix-1.0.0.vsix` from the `extension/` folder via `Cmd+Shift+P → Extensions: Install from VSIX`.

Then:
1. Open Settings and search for `cursorCoralogix`, fill in your API key and select your region endpoint
2. Run `Cmd+Shift+P → Coralogix: Setup hooks`
3. Restart Cursor

The extension provides a status bar indicator and commands to set up, remove, and check hook status without editing any files manually.

To build the `.vsix` from source:

```bash
cd extension
npm install
npx vsce package
```

---

## Signals sent to Coralogix

Each Cursor hook event becomes one OTLP trace span.

| Event | Span name | Key attributes |
|---|---|---|
| `sessionStart` / `sessionEnd` | `cursor.sessionStart/End` | `gen_ai.request.model`, `cursor.user_email`, `cursor.cursor_version` |
| `beforeSubmitPrompt` | `cursor.beforeSubmitPrompt` | `cursor.prompt` (masked by default; opt in to full text with `CURSOR_MASK_PROMPTS=false`), `gen_ai.request.model` |
| `preToolUse` / `postToolUse` | `cursor.preToolUse/postToolUse` | `gen_ai.tool.name`, `cursor.tool_input`, `cursor.tool_output` |
| `postToolUseFailure` | `cursor.postToolUseFailure` | `gen_ai.tool.name`, `cursor.error` |
| `beforeShellExecution` / `afterShellExecution` | `cursor.before/afterShellExecution` | `cursor.shell_command`, `cursor.cwd`, `cursor.exit_code` |
| `beforeMCPExecution` / `afterMCPExecution` | `cursor.before/afterMCPExecution` | `cursor.mcp_server`, `cursor.mcp_tool` |
| `beforeReadFile` / `afterFileEdit` | `cursor.beforeReadFile/afterFileEdit` | `cursor.file_path`, `cursor.edits` |
| `preCompact` | `cursor.preCompact` | `cursor.context_tokens`, `cursor.context_window_size`, `cursor.context_usage_pct` |
| `stop` | `cursor.stop` | `cursor.status`, `cursor.loop_count` |
| `subagentStart` / `subagentStop` | `cursor.subagentStart/Stop` | session and generation IDs |
| `afterAgentResponse` / `afterAgentThought` | `cursor.afterAgentResponse/Thought` | `cursor.text` |

All spans carry: `cursor.conversation_id`, `cursor.generation_id`, `gen_ai.request.model`, `gen_ai.system`, `cursor.user_email`, plus Coralogix tags: `cx.application.name`, `cx.subsystem.name`.

---

## Screenshots

**Trace list** — every span in a session grouped by `conversation_id`:

![Trace list showing all spans for a Cursor session](images/trace-list.png)

**Waterfall** — full session hierarchy with timing, span attributes, and metadata:

![Waterfall view showing the complete span hierarchy for a session](images/trace-waterfall.png)

---

## Privacy

Prompts and responses are masked by default — all prompt/response content is replaced with `[MASKED]` before export. Set `CURSOR_MASK_PROMPTS=false` to send full prompt and response text to Coralogix instead. All other attributes (tool names, file paths, shell commands) are unaffected. Spans still carry `gen_ai.request.model`, prompt length, response lines, and latency when masked.

Set `CURSOR_OMIT_PRE_TOOL_USE_SPANS=true` to skip exporting `cursor.preToolUse` spans. `postToolUse` and `postToolUseFailure` spans are still exported and include `cursor.duration_ms`.

---

## Debugging

Set `CX_OTLP_DEBUG=true` to print trace/span IDs and export errors to stderr. Cursor captures hook stderr in its Output panel — open via **View → Output** and select the **Hooks** channel.

---

## Requirements

- Python 3.8+
- `opentelemetry-sdk` and `opentelemetry-exporter-otlp-proto-http` pip packages (installed automatically)
- Cursor with agent hooks support (**Cursor Settings → Features → Agent**)
- A Coralogix tenant with a Send-Your-Data API key
