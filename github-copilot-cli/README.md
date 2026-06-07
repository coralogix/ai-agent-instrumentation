# GitHub Copilot CLI - Coralogix

Track which git repositories your GitHub Copilot CLI sessions work on and ship them to Coralogix as an OTLP metric, using Copilot's built-in [hooks](https://docs.github.com/en/copilot/reference/hooks-configuration).

This is the Copilot counterpart of the Claude Code and Codex repo-tracker hooks. Copilot pipes a JSON event to the hook's stdin on every tool call; the hook resolves the repo from the session `cwd` (plus any file path in the tool arguments) via `git rev-parse` + `git remote get-url origin` and emits a metric. Python 3 stdlib only — no dependencies, fails silently, never blocks Copilot.

---

## Metric

| Metric | Type | Labels |
|---|---|---|
| `copilot_cli_session_repo_info` | gauge (`=1`) | `session_id`, `repository_name`, `user_email` |

`repository_name` is the git `origin` remote (`org/repo`), falling back to the directory name, or `unknown` outside a git repo. Aggregation into per-session cumulative counts is performed downstream.

---

## How it works

Copilot's command hooks receive the event JSON on **stdin**. The hook is registered on the `postToolUse` event with no matcher, so it fires after every tool call. The payload provides `sessionId`, `cwd`, `toolName`, and `toolArgs` (the hook also reads the PascalCase `session_id`/`tool_input` variant, so either event-name casing works).

This folder provides:

- `hooks/copilot.py` — the hook script (stdlib only)
- `repo-tracker.json` — the hook config to drop into `~/.copilot/hooks/`
- `.env.example` — Coralogix credentials template (git-ignored)

---

## Setup

### 1. Configure your Coralogix credentials

```bash
cp .env.example .env
```

Fill in `.env`:

```
CX_API_KEY=<your-send-your-data-api-key>
CX_OTLP_ENDPOINT=https://ingress.eu1.coralogix.com
CX_APPLICATION_NAME=copilot
CX_SUBSYSTEM_NAME=copilot-sessions
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

Add this to your `~/.zshrc` (or `~/.bashrc`) so the credentials are present whenever Copilot runs the hook (replace the path — run `pwd` inside this directory to get it):

```bash
if [ -f "/absolute/path/to/github-copilot-cli/.env" ]; then
  set -a; source "/absolute/path/to/github-copilot-cli/.env"; set +a
fi
```

Then reload:

```bash
source ~/.zshrc
```

> The hook reads the Coralogix endpoint and key from these env vars and exits silently if either is unset, so it's safe to install before credentials are configured.

### 3. Register the hook

Edit `repo-tracker.json` and replace the placeholder paths with the absolute path to `hooks/copilot.py`, then copy it into your user hooks directory:

```bash
mkdir -p ~/.copilot/hooks
cp repo-tracker.json ~/.copilot/hooks/repo-tracker.json
```

The config registers a `postToolUse` command hook:

```json
{
  "version": 1,
  "hooks": {
    "postToolUse": [
      {
        "type": "command",
        "bash": "python3 /absolute/path/to/github-copilot-cli/hooks/copilot.py",
        "timeoutSec": 10
      }
    ]
  }
}
```

> Hooks are also discovered from `.github/hooks/*.json` (repo-level) and the `hooks` field of `~/.copilot/settings.json`. See the [Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-configuration) for all sources.

### 4. Run Copilot

Run a Copilot CLI session in a git repo, then verify in Coralogix:

```promql
count by (repository_name) (copilot_cli_session_repo_info)
```

You can test the hook locally without launching Copilot by piping a sample event to it:

```bash
echo '{"sessionId":"test","cwd":"'"$PWD"'","toolName":"shell","toolArgs":{}}' | python3 hooks/copilot.py
```

---

## Configuration

| Env var | Required | Purpose |
|---|---|---|
| `CX_API_KEY` | yes | Coralogix Send-Your-Data API key (bearer token) |
| `CX_OTLP_ENDPOINT` | yes | Coralogix OTLP ingress base URL; the hook POSTs to `…/v1/metrics` |
| `CX_APPLICATION_NAME` | no | Stamped as the `CX-Application-Name` header + `cx.application.name` resource attribute |
| `CX_SUBSYSTEM_NAME` | no | Stamped as the `CX-Subsystem-Name` header + `cx.subsystem.name` resource attribute |
| `CX_HOOK_USER_EMAIL` | no | Overrides the `user_email` label; defaults to `git config user.email` |
