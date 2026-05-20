# Claude Code Repo-Tracker Hook

Track which repositories each Claude Code session works on. Emits an OTLP metric with `session_id + repository_name` labels so the Coralogix AI Center dashboard can show per-session, per-repo cost attribution.

- **Zero dependencies** — Python 3 stdlib only, no pip installs
- **Multi-repo aware** — detects repos from actual file operations, not just the starting directory
- **Privacy-safe** — sends only repo names and session IDs, never code content

---

## How it works

The hook registers as a Claude Code `PostToolUse` hook. After every tool call (Read, Edit, Write, Bash, Glob, Grep, etc.) it:

1. Extracts file paths from the tool event (e.g. `tool_input.file_path` for Edit, `cwd` for Bash)
2. Runs `git rev-parse --show-toplevel` to find the repo root
3. Runs `git remote get-url origin` to get the remote URL, parses `owner/repo`
4. If this is a new repo for the session, emits an OTLP gauge metric via HTTP POST
5. Tracks emitted repos in `~/.claude-hook-state/<session_id>.repos` to avoid duplicates

Sessions that span multiple repos (via `add-dir`, cross-repo edits, etc.) emit one metric series per repo.

---

## Setup

### Option A — Org-wide via Managed Settings (recommended)

Push the hook to every developer in your org with zero per-developer setup. No developer action required — the hook script is downloaded automatically on first run.

Navigate to **Admin Settings > Claude Code > Managed Settings** and paste:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c '[ -f ~/.claude/hooks/repo_tracker.py ] || (mkdir -p ~/.claude/hooks && curl -sfL https://cdn.coralogix.com/integrations/claude-code/hooks/repo_tracker.py -o ~/.claude/hooks/repo_tracker.py); python3 ~/.claude/hooks/repo_tracker.py'"
          }
        ]
      }
    ]
  },
  "env": {
    "CX_HOOK_API_KEY": "<YOUR_CX_API_KEY>",
    "CX_HOOK_OTLP_ENDPOINT": "https://ingress.<REGION>.coralogix.com",
    "CX_HOOK_APPLICATION_NAME": "claude-code",
    "CX_HOOK_SUBSYSTEM_NAME": "ai-agent"
  }
}
```

This can be combined with your existing telemetry env vars (`CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_*`) in the same settings block.

### Option B — Per-developer install

```bash
# With API key in env
CX_HOOK_API_KEY=<key> CX_HOOK_OTLP_ENDPOINT=https://ingress.eu2.coralogix.com ./install.sh

# Or from an env file
cp .env.example ~/.claude/hooks/.env
# Edit ~/.claude/hooks/.env with your values
./install.sh --env-file ~/.claude/hooks/.env
```

The installer:
- Copies `repo_tracker.py` to `~/.claude/hooks/`
- Registers the hook in `~/.claude/settings.json` (idempotent)
- Creates `~/.claude-hook-state/` for session state
- Runs a dry-run to verify the script works

---

## Prerequisites

| Tool | Required | Notes |
|------|----------|-------|
| Python 3 | Yes | Ships with macOS and most Linux distros |
| git | Yes | Required for repo detection |

No pip packages needed.

---

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CX_HOOK_API_KEY` | Yes | — | Coralogix Send-Your-Data API key |
| `CX_HOOK_OTLP_ENDPOINT` | No | `https://ingress.eu2.coralogix.com` | OTLP ingress endpoint for your region |
| `CX_HOOK_APPLICATION_NAME` | No | `claude-code` | Coralogix application name |
| `CX_HOOK_SUBSYSTEM_NAME` | No | `ai-agent` | Coralogix subsystem name |
| `CX_HOOK_DEBUG` | No | — | Set to `1` to print debug info to stderr |

**OTLP endpoint by region:**

| Domain | Endpoint |
|--------|----------|
| `us1.coralogix.com` | `https://ingress.us1.coralogix.com` |
| `us2.coralogix.com` | `https://ingress.us2.coralogix.com` |
| `eu1.coralogix.com` | `https://ingress.eu1.coralogix.com` |
| `eu2.coralogix.com` | `https://ingress.eu2.coralogix.com` |
| `ap1.coralogix.com` | `https://ingress.ap1.coralogix.com` |
| `ap2.coralogix.com` | `https://ingress.ap2.coralogix.com` |
| `ap3.coralogix.com` | `https://ingress.ap3.coralogix.com` |

---

## Metric emitted

| Name | Type | Value | Labels |
|------|------|-------|--------|
| `claude_code_session_repo_info` | Gauge | `1` | `session_id`, `repository_name`, `user_email` |

This is an "info metric" — the value is always `1`, the labels carry the data. The FE reads label values via PromQL to build session-to-repo mappings.

---

## Verification

After running a Claude Code session, query in Coralogix Metrics Explorer:

```promql
claude_code_session_repo_info{session_id!=""}
```

You should see series with your `session_id` and `repository_name` labels.

To see all repos detected across sessions:

```promql
count by (repository_name) (claude_code_session_repo_info)
```

---

## Troubleshooting

**No metrics appearing**
- Verify `CX_HOOK_API_KEY` is set (run with `CX_HOOK_DEBUG=1` to check)
- Verify the OTLP endpoint matches your Coralogix region
- Wait up to 5 minutes for ingestion

**Repository name shows as directory basename instead of owner/repo**
- The repo has no `origin` remote configured
- Run `git remote get-url origin` in the repo to check

**Hook not firing**
- Check `~/.claude/settings.json` has the `PostToolUse` hook entry
- Verify `~/.claude/hooks/repo_tracker.py` exists and is readable
- Run manually: `echo '{"session_id":"test","cwd":".","tool_name":"Bash","tool_input":{}}' | CX_HOOK_DEBUG=1 CX_HOOK_API_KEY=test python3 ~/.claude/hooks/repo_tracker.py`

**State file cleanup**
- Session state files are auto-pruned (files older than 24h, ~1% chance per invocation)
- To manually clean: `rm ~/.claude-hook-state/*.repos`
