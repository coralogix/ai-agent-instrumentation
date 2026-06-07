# Jamf deployment — AI agent repo-tracker hooks

`jamf-repo-tracker.sh` installs the Coralogix **repo-tracker** PostToolUse hook for every supported AI coding agent on a managed Mac, fleet-wide via Jamf Pro. Each hook emits the OTLP gauge metric `<agent>_session_repo_info{session_id, repository_name, user_email}` on every tool call, so you can see **which git repositories** your developers' agent sessions touch.

Covers:

| Agent | Metric | Registered in |
|---|---|---|
| Claude Code | `claude_code_session_repo_info` | `~/.claude/settings.json` (`PostToolUse`) |
| Codex CLI | `codex_cli_session_repo_info` | `~/.codex/config.toml` (`[[hooks.PostToolUse]]`) |
| GitHub Copilot CLI | `copilot_cli_session_repo_info` | `~/.copilot/hooks/coralogix_repo_tracker.json` (`postToolUse`) |
| Gemini CLI | `gemini_cli_session_repo_info` | `~/.gemini/settings.json` (`AfterTool`) |

> **Not handled here:**
> - **Cursor** has its own MDM installer at [`cursor/install.sh`](../cursor/install.sh) (it ships a richer trace-emitting hook).
> - **Grok** (xAI API tracing SDK) and **OpenClaw** (gateway service with a native OTLP plugin) have no per-tool-call stdin hook, so repo-tracking via a hook does not apply to them.

The hooks are Python 3 **stdlib only** — no `pip` dependencies. They resolve the repo from the session `cwd` (and any file path in the tool input) via `git rev-parse` + `git remote get-url origin`, fail silently, and never block the agent.

---

## How it works

Jamf runs policy scripts as **root**, but these hooks live in each user's home directory. The script therefore:

1. Detects the logged-in **console user** and resolves their home/UID.
2. For each agent present on the machine (CLI on `PATH` **or** `~/.<agent>` exists), installs **as that user**:
   - `~/.<agent>/hooks/coralogix_repo_tracker.py` — the hook (copied from this repo).
   - `coralogix_repo_tracker.env` — Coralogix credentials, `chmod 600`.
   - `coralogix_repo_tracker.sh` — a wrapper that sources the env file then execs the hook, so credentials are present **regardless of how the agent was launched** (no reliance on the user's shell rc).
3. Registers the wrapper in each agent's config (idempotently — safe to re-run).

The hook files are **copied from the repo, not embedded**, so there's a single source of truth. The script needs the repo present on disk (see *Deploying the hook source* below).

---

## Jamf Pro setup

### 1. Make the hook source available on the Mac

The script reads the canonical hook files from a source directory (auto-detected as the repo root relative to the script, or set explicitly). Pick one:

- **Recommended — bundle a package:** build a `.pkg` that lays the repo down at, e.g., `/Library/Application Support/coralogix-ai-instrumentation/`, deploy it in the same policy (ordered *before* the script), and pass that path as parameter **`$8`**.
- **Or** `git clone` the repo to a known path in an earlier policy step and pass it as `$8`.

### 2. Add the script to Jamf

Upload `jamf-repo-tracker.sh` under **Settings → Computer Management → Scripts**. Label the parameters (**Options → Parameter Labels**):

| Param | Label | Example |
|---|---|---|
| `$4` | Coralogix API key | `cxtp_…` (Send-Your-Data key) |
| `$5` | OTLP endpoint | `https://ingress.eu2.coralogix.com` |
| `$6` | Application name override | *(blank → per-agent default)* |
| `$7` | Subsystem name override | *(blank → per-agent default)* |
| `$8` | Hook source directory | `/Library/Application Support/coralogix-ai-instrumentation` |
| `$9` | Action | `uninstall` to remove |

> Store the API key as a script parameter (Jamf encrypts script parameters at rest) or inject it from a Jamf custom secret — don't hard-code it in the repo.

When `$6`/`$7` are blank, each agent self-labels: `claude-code` / `claude-code-sessions`, `codex` / `codex-sessions`, `copilot` / `copilot-sessions`. Set them to force every agent onto one application/subsystem instead.

### 3. Create the policy

- **Trigger:** recurring check-in (or enrolment).
- **Frequency:** *Once per computer* for first rollout; *Ongoing* if you want it re-applied after agent upgrades. The script is idempotent, so *Ongoing* is safe.
- **Scope:** your developer Macs.

Because the hook only writes to agents that are already present (or whose config dir exists), it's harmless to scope broadly.

---

## Running by hand / other MDMs (Intune, Ansible)

All parameters also read from environment variables, so the script works outside Jamf:

```bash
sudo CX_API_KEY=cxtp_xxx \
     CX_OTLP_ENDPOINT=https://ingress.eu2.coralogix.com \
     HOOK_SOURCE_DIR=/path/to/ai-agent-instrumentation \
     ./jamf-repo-tracker.sh
```

(Positional Jamf args `$4…$9` take precedence over the env vars when present.)

### Uninstall

```bash
sudo ./jamf-repo-tracker.sh "" "" "" "" "" "" "" "" uninstall
# or, via env:  sudo ./jamf-repo-tracker.sh   with $9=uninstall
```

Uninstall removes the installed `coralogix_repo_tracker.*` files and cleanly strips the registration from each agent's config (the Codex block is delimited by begin/end markers so only our lines are removed).

---

## Verify

After a developer runs an agent session in a git repo:

```bash
# Across all agents:
cx metrics search --name "*session_repo*" --region <region>

# One-shot gauge points need a RANGE query (an instant query only sees "now"):
cx metrics query-range 'codex_cli_session_repo_info' --start now-1h --region <region>
```

Each series carries `session_id`, `repository_name`, `user_email`, and `cx_application_name` so you can break repo activity down by user and agent.

---

## Requirements

- macOS with a logged-in console user at install time.
- Python 3 on the user's `PATH` (the script aborts with a clear error if absent). Hooks use **stdlib only**.
- `git` on the user's `PATH` (used to resolve repo name; the hook degrades to `unknown` if a path isn't in a repo).
