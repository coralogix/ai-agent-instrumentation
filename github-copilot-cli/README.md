# GitHub Copilot CLI - Coralogix

Ship GitHub Copilot CLI activity to Coralogix using Copilot's built-in [hooks](https://docs.github.com/en/copilot/reference/hooks-configuration):

- **Repositories** worked on per session — `copilot_cli_session_repo_info` metric
- **User prompts** — `copilot_cli.user_prompt` log
- **Assistant responses** — `copilot_cli.assistant_message` log

Copilot CLI emits no telemetry of its own, so a single hook script (`hooks/copilot.py`) reconstructs this from Copilot's lifecycle events and exports it over OTLP. Python 3 stdlib only — no dependencies, fails silently, never blocks Copilot.

The prompt/response logs **mirror Claude Code's native telemetry structure**, so they sit alongside it in Coralogix:

| | Claude Code | Copilot CLI (this hook) |
|---|---|---|
| log body | `claude_code.user_prompt` | `copilot_cli.user_prompt` |
| attributes | `event.name`, `session.id`, `user.email`, … | same |
| resource | `service.name=claude-code` | `service.name=copilot-cli` |
| scope | `com.anthropic.claude_code.events` | `com.github.copilot_cli.events` |

---

## Signals

### Metric — repositories per session
| Metric | Type | Labels |
|---|---|---|
| `copilot_cli_session_repo_info` | gauge (`=1`) | `session_id`, `repository_name`, `user_email` |

Emitted on `postToolUse`. `repository_name` is the git `origin` remote (`org/repo`), falling back to the directory name, or `unknown` outside a repo.

### Logs — prompts & responses
| Event | OTLP log body | Key attributes |
|---|---|---|
| `userPromptSubmitted` | `copilot_cli.user_prompt` | `session.id`, `user.email`, `prompt_length`, **`prompt_text`** |
| `agentStop` / `sessionEnd` | `copilot_cli.assistant_message` | `session.id`, `model`, `output_tokens`, `turn_id`, `content_length`, **`content`** |

`session_id` is identical across all three signals (and matches the id in Copilot's session-state), so prompts, responses, and repos correlate per session.

> **Note on `prompt_text`:** the prompt text is sent as `prompt_text`, not `prompt`. Claude Code emits a nested `prompt.id`, so in a shared Coralogix log index the `prompt` field is typed as an object and a flat string there is rejected on ingest. `prompt_text` avoids that collision.

---

## How responses are collected

No Copilot hook payload contains the assistant's reply text (verified by capturing every hook event) — the only source is the session transcript (`events.jsonl`), referenced by `transcriptPath` on `agentStop`. Copilot flushes that file **asynchronously**, so the latest turn's `assistant.message` may not be on disk the moment the hook fires. The hook therefore re-reads the transcript with **backed-off retries** (0.3 → 0.6 → 1.2 → 2.0s) — the hook is awaited by Copilot, whose event loop keeps flushing while we sleep — and **deduplicates by `messageId`** across `agentStop` and `sessionEnd` so each response is shipped exactly once.

---

## Configuration

Credentials live in the hook's **`env` block** inside `~/.copilot/hooks/coralogix.json` — Copilot injects them into the hook process, so this is configured entirely through Copilot's own settings (no shell exports, no separate `.env`).

| Variable | Required | Purpose |
|---|---|---|
| `CX_API_KEY` | yes | Coralogix Send-Your-Data API key |
| `CX_OTLP_ENDPOINT` | yes | Coralogix OTLP ingress base URL (the hook POSTs to `…/v1/metrics` and `…/v1/logs`) |
| `CX_APPLICATION_NAME` | no | `CX-Application-Name` header + `cx.application.name` resource attribute |
| `CX_SUBSYSTEM_NAME` | no | `CX-Subsystem-Name` header + `cx.subsystem.name` resource attribute |
| `CX_HOOK_USER_EMAIL` | no | Overrides `user_email`; defaults to `git config user.email` |
| `CX_HOOK_LOG_PROMPTS` | no | `false` redacts prompt/response **text** (keeps lengths/metadata). Default `true`. Mirrors Claude Code's `OTEL_LOG_USER_PROMPTS`. |

> **Privacy:** with the prompt/response events enabled and `CX_HOOK_LOG_PROMPTS=true` (default), full prompt and response **text** is sent to Coralogix. Set `CX_HOOK_LOG_PROMPTS=false`, or omit the `userPromptSubmitted`/`agentStop`/`sessionEnd` entries, to disable content capture.

---

## Setup

Configure everything through Copilot's own hook settings — no shell exports, wrappers, or separate credential files.

1. **Place the config.** Copy [`coralogix.json`](./coralogix.json) into your Copilot hooks dir:

   ```bash
   mkdir -p ~/.copilot/hooks
   cp coralogix.json ~/.copilot/hooks/coralogix.json
   ```

2. **Point it at the hook.** Replace every `python3 /absolute/path/to/github-copilot-cli/hooks/copilot.py` with the real absolute path to `hooks/copilot.py` (run `pwd` inside `github-copilot-cli/`).

3. **Fill in the `env` block** in each hook entry — Copilot injects it into the hook process:

   ```json
   "env": {
     "CX_API_KEY": "<your-send-your-data-api-key>",
     "CX_OTLP_ENDPOINT": "https://ingress.eu2.coralogix.com",
     "CX_APPLICATION_NAME": "copilot",
     "CX_SUBSYSTEM_NAME": "copilot-sessions",
     "CX_HOOK_LOG_PROMPTS": "true"
   }
   ```

4. **Lock it down** (it holds your API key): `chmod 600 ~/.copilot/hooks/coralogix.json`.

5. Start Copilot — the hooks fire automatically.

**Scope it to taste:**
- **Repo tracking only** (no prompt/response capture): keep just the `postToolUse` entry; delete `userPromptSubmitted`, `agentStop`, and `sessionEnd`.
- **Capture metadata but not text:** set `CX_HOOK_LOG_PROMPTS` to `"false"`.

**OTLP ingress by region:**

| Domain | `CX_OTLP_ENDPOINT` |
|---|---|
| `us1.coralogix.com` | `https://ingress.us1.coralogix.com` |
| `us2.coralogix.com` | `https://ingress.us2.coralogix.com` |
| `eu1.coralogix.com` | `https://ingress.eu1.coralogix.com` |
| `eu2.coralogix.com` | `https://ingress.eu2.coralogix.com` |
| `ap1.coralogix.com` | `https://ingress.ap1.coralogix.com` |
| `ap2.coralogix.com` | `https://ingress.ap2.coralogix.com` |
| `ap3.coralogix.com` | `https://ingress.ap3.coralogix.com` |

---

## Verify

Run a Copilot session in a git repo, then (one-shot gauge/log points → use a **range** query):

```bash
# Repositories:
cx metrics query-range 'count by (repository_name) (copilot_cli_session_repo_info)' --start now-1h --region <region>

# Prompts:
cx logs "filter \$d.logRecord.body == 'copilot_cli.user_prompt'" --start now-1h --region <region>

# Responses:
cx logs "filter \$d.logRecord.body == 'copilot_cli.assistant_message'" --start now-1h --region <region>
```

You can also drive the hook by hand:

```bash
echo '{"sessionId":"test","cwd":"'"$PWD"'","toolName":"shell","toolArgs":{}}' \
  | CX_API_KEY=… CX_OTLP_ENDPOINT=https://ingress.<region>.coralogix.com python3 hooks/copilot.py
```

---

## Requirements

- `python3` and `git` on the `PATH` Copilot launches with (stdlib only — no `pip` install).
- A Coralogix Send-Your-Data API key (**Settings → API Keys**).
