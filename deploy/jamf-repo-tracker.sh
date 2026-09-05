#!/bin/bash
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ===========================================================================
# Jamf deployment script — Coralogix AI agent repo-tracker hooks
# ===========================================================================
#
# Installs the repo-tracker PostToolUse hook for every supported AI coding
# agent found on the machine (Claude Code, Codex CLI, GitHub Copilot CLI),
# for the currently logged-in console user. Each hook emits the OTLP gauge
# metric <agent>_session_repo_info{session_id, repository_name, user_email}
# on each tool call.
#
# Jamf runs policy scripts as ROOT. These hooks are per-user (installed under
# the user's ~/.claude, ~/.codex, ~/.copilot), so the script detects the
# console user and performs all writes AS that user.
#
# ---------------------------------------------------------------------------
# Jamf parameters (script parameters in the Jamf policy; $1-$3 are reserved
# by Jamf for mount point / computer name / username):
#
#   $4  Coralogix Send-Your-Data API key        (required)
#   $5  Coralogix OTLP ingress endpoint          (default: https://ingress.eu2.coralogix.com)
#   $6  Application name override                (default: per-agent, e.g. "codex")
#   $7  Subsystem name override                  (default: per-agent, e.g. "codex-sessions")
#   $8  Hook source directory                    (default: auto-detected repo root)
#   $9  "uninstall" to remove instead of install
#
# The same values can be supplied via environment variables (CX_API_KEY,
# CX_OTLP_ENDPOINT, CX_APPLICATION_NAME, CX_SUBSYSTEM_NAME, HOOK_SOURCE_DIR)
# so the script can also be run by hand or by other MDMs (Intune, Ansible).
# ===========================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve configuration: Jamf positional params take precedence over env vars.
# ---------------------------------------------------------------------------

API_KEY="${4:-${CX_API_KEY:-}}"
ENDPOINT="${5:-${CX_OTLP_ENDPOINT:-https://ingress.eu2.coralogix.com}}"
APP_OVERRIDE="${6:-${CX_APPLICATION_NAME:-}}"
SUBSYSTEM_OVERRIDE="${7:-${CX_SUBSYSTEM_NAME:-}}"
SOURCE_DIR="${8:-${HOOK_SOURCE_DIR:-}}"
ACTION="${9:-install}"

# Strip any trailing slash from the endpoint.
ENDPOINT="${ENDPOINT%/}"

INSTALL_BASENAME="coralogix_repo_tracker"   # file stem used under each ~/.<agent>/hooks
MARKER_BEGIN="# >>> coralogix-repo-tracker >>>"  # delimit our appended config.toml block
MARKER_END="# <<< coralogix-repo-tracker <<<"    # so uninstall can strip it exactly

log()  { echo "[coralogix-repo-tracker] $*"; }
warn() { echo "[coralogix-repo-tracker] WARNING: $*" >&2; }
die()  { echo "[coralogix-repo-tracker] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Detect the logged-in console user (the human whose agents we instrument).
# ---------------------------------------------------------------------------

CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
  die "No regular user is logged in at the console — nothing to install. (got: '${CONSOLE_USER:-none}')"
fi

USER_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
[[ -d "$USER_HOME" ]] || die "Could not resolve home directory for $CONSOLE_USER"

log "Console user: $CONSOLE_USER (uid=$USER_UID, home=$USER_HOME)"

# run_as_user CMD... — execute a command as the console user, not root.
# When the script is already running as that user (manual run), execute directly.
run_as_user() {
  if [[ "$(/usr/bin/id -u)" == "$USER_UID" ]]; then
    "$@"
  else
    /usr/bin/sudo -u "$CONSOLE_USER" "$@"
  fi
}

# Run a command as the user with the user's login PATH (finds Homebrew python3).
run_as_user_shell() {
  run_as_user /bin/bash -lc "$1"
}

# agent_present <cli-name> <config-dir> — true if the agent's CLI is on the
# user's PATH or its config dir already exists. (Checked as the console user,
# since root's PATH won't see user-installed CLIs.)
agent_present() {
  local cli="$1" dir="$2"
  [[ -d "$dir" ]] && return 0
  run_as_user_shell "command -v $cli >/dev/null 2>&1"
}

# ---------------------------------------------------------------------------
# Locate python3 in the user's environment.
# ---------------------------------------------------------------------------

PYTHON_BIN="$(run_as_user_shell 'command -v python3 || true')"
[[ -n "$PYTHON_BIN" ]] || die "python3 not found in $CONSOLE_USER's PATH. The repo-tracker hooks require Python 3 (stdlib only)."
log "Using python3: $PYTHON_BIN"

# ---------------------------------------------------------------------------
# Locate the canonical hook source files (copied from the repo, not embedded,
# so there is a single source of truth).
# ---------------------------------------------------------------------------

if [[ -z "$SOURCE_DIR" ]]; then
  # Default: the repo root, relative to this script (deploy/..).
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
log "Hook source directory: $SOURCE_DIR"

# Agent table: name | settings location | hook source | install dir | default app | default subsystem
# (parsed below)

# ---------------------------------------------------------------------------
# Per-agent installers
# ---------------------------------------------------------------------------

# Write a credentials env file + a wrapper that sources it and execs the hook.
# Exports BOTH the CX_* names (Codex/Copilot hooks) and the OTEL_* names
# (Claude Code hook) so one env file works for any agent.
write_env_and_wrapper() {
  local hooks_dir="$1" app="$2" subsystem="$3" hook_py="$4" env_file="$5" wrapper="$6"

  run_as_user /bin/mkdir -p "$hooks_dir"

  # Env file — contains the API key, so lock it down to 600. Values are quoted
  # because the wrapper sources this file: OTEL_EXPORTER_OTLP_HEADERS holds a
  # space ("Bearer <key>"), and app/subsystem names may too.
  run_as_user /usr/bin/tee "$env_file" >/dev/null <<EOF
# Auto-generated by jamf-repo-tracker.sh — do not edit manually
CX_API_KEY="$API_KEY"
CX_OTLP_ENDPOINT="$ENDPOINT"
CX_APPLICATION_NAME="$app"
CX_SUBSYSTEM_NAME="$subsystem"
OTEL_EXPORTER_OTLP_ENDPOINT="$ENDPOINT"
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $API_KEY"
CX_HOOK_APPLICATION_NAME="$app"
CX_HOOK_SUBSYSTEM_NAME="$subsystem"
EOF
  run_as_user /bin/chmod 600 "$env_file"

  # Wrapper — sources the env file then execs the hook so credentials are
  # present regardless of how the agent process was launched.
  run_as_user /usr/bin/tee "$wrapper" >/dev/null <<EOF
#!/bin/bash
# Auto-generated by jamf-repo-tracker.sh — do not edit manually
set -a
source "$env_file"
set +a
exec "$PYTHON_BIN" "$hook_py"
EOF
  run_as_user /bin/chmod 755 "$wrapper"
}

install_claude_code() {
  local home="$USER_HOME"
  agent_present claude "$home/.claude" || { log "Claude Code not detected — skipping."; return; }

  local src="$SOURCE_DIR/claude-code/hooks/claude.py"
  [[ -f "$src" ]] || { warn "Claude hook source missing at $src — skipping."; return; }

  local app="${APP_OVERRIDE:-claude-code}"
  local subsystem="${SUBSYSTEM_OVERRIDE:-claude-code-sessions}"
  local hooks_dir="$home/.claude/hooks"
  local hook_py="$hooks_dir/${INSTALL_BASENAME}.py"
  local env_file="$hooks_dir/${INSTALL_BASENAME}.env"
  local wrapper="$hooks_dir/${INSTALL_BASENAME}.sh"
  local settings="$home/.claude/settings.json"

  run_as_user /bin/mkdir -p "$hooks_dir"
  run_as_user /bin/cp "$src" "$hook_py"
  write_env_and_wrapper "$hooks_dir" "$app" "$subsystem" "$hook_py" "$env_file" "$wrapper"

  run_as_user "$PYTHON_BIN" - "$settings" "$wrapper" <<'PYEOF'
import json, os, sys
settings_path, wrapper = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
hooks = cfg.setdefault("hooks", {})
groups = hooks.setdefault("PostToolUse", [])
# Drop any prior group that points at our wrapper, then add a fresh one.
def has_ours(g):
    return any(h.get("command") == wrapper for h in g.get("hooks", []))
groups = [g for g in groups if not has_ours(g)]
groups.append({"matcher": "*", "hooks": [{"type": "command", "command": wrapper}]})
hooks["PostToolUse"] = groups
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  log "Claude Code: hook registered in $settings (app=$app)"
}

install_codex() {
  local home="$USER_HOME"
  agent_present codex "$home/.codex" || { log "Codex CLI not detected — skipping."; return; }

  local src="$SOURCE_DIR/codex/hooks/codex.py"
  [[ -f "$src" ]] || { warn "Codex hook source missing at $src — skipping."; return; }

  local app="${APP_OVERRIDE:-codex}"
  local subsystem="${SUBSYSTEM_OVERRIDE:-codex-sessions}"
  local hooks_dir="$home/.codex/hooks"
  local hook_py="$hooks_dir/${INSTALL_BASENAME}.py"
  local env_file="$hooks_dir/${INSTALL_BASENAME}.env"
  local wrapper="$hooks_dir/${INSTALL_BASENAME}.sh"
  local config="$home/.codex/config.toml"

  run_as_user /bin/mkdir -p "$hooks_dir"
  run_as_user /bin/cp "$src" "$hook_py"
  write_env_and_wrapper "$hooks_dir" "$app" "$subsystem" "$hook_py" "$env_file" "$wrapper"

  # Codex hooks are TOML array-tables. Append our block once, delimited by
  # begin/end markers so uninstall can strip it exactly (idempotent).
  if run_as_user /bin/test -f "$config" && run_as_user /usr/bin/grep -qF "$MARKER_BEGIN" "$config"; then
    log "Codex CLI: hook already present in $config — leaving as-is."
  else
    run_as_user /usr/bin/tee -a "$config" >/dev/null <<EOF

$MARKER_BEGIN
[[hooks.PostToolUse]]
matcher = ".*"

[[hooks.PostToolUse.hooks]]
type = "command"
command = "$wrapper"
timeout = 10
$MARKER_END
EOF
    log "Codex CLI: hook appended to $config (app=$app)"
  fi
}

install_copilot() {
  local home="$USER_HOME"
  agent_present copilot "$home/.copilot" || { log "GitHub Copilot CLI not detected — skipping."; return; }

  local src="$SOURCE_DIR/github-copilot-cli/hooks/copilot.py"
  [[ -f "$src" ]] || { warn "Copilot hook source missing at $src — skipping."; return; }

  local app="${APP_OVERRIDE:-copilot}"
  local subsystem="${SUBSYSTEM_OVERRIDE:-copilot-sessions}"
  local hooks_dir="$home/.copilot/hooks"
  local hook_py="$hooks_dir/${INSTALL_BASENAME}.py"
  local env_file="$hooks_dir/${INSTALL_BASENAME}.env"
  local wrapper="$hooks_dir/${INSTALL_BASENAME}.sh"
  local hook_json="$hooks_dir/${INSTALL_BASENAME}.json"

  run_as_user /bin/mkdir -p "$hooks_dir"
  run_as_user /bin/cp "$src" "$hook_py"
  write_env_and_wrapper "$hooks_dir" "$app" "$subsystem" "$hook_py" "$env_file" "$wrapper"

  run_as_user "$PYTHON_BIN" - "$hook_json" "$wrapper" <<'PYEOF'
import json, sys
hook_json, wrapper = sys.argv[1], sys.argv[2]
cfg = {
    "version": 1,
    "hooks": {
        "postToolUse": [
            {"type": "command", "bash": wrapper, "timeoutSec": 10}
        ]
    },
}
with open(hook_json, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  log "GitHub Copilot CLI: hook written to $hook_json (app=$app)"
}

install_gemini() {
  local home="$USER_HOME"
  agent_present gemini "$home/.gemini" || { log "Gemini CLI not detected — skipping."; return; }

  local src="$SOURCE_DIR/gemini-cli/hooks/gemini.py"
  [[ -f "$src" ]] || { warn "Gemini hook source missing at $src — skipping."; return; }

  local app="${APP_OVERRIDE:-gemini-cli}"
  local subsystem="${SUBSYSTEM_OVERRIDE:-gemini-cli-sessions}"
  local hooks_dir="$home/.gemini/hooks"
  local hook_py="$hooks_dir/${INSTALL_BASENAME}.py"
  local env_file="$hooks_dir/${INSTALL_BASENAME}.env"
  local wrapper="$hooks_dir/${INSTALL_BASENAME}.sh"
  local settings="$home/.gemini/settings.json"

  run_as_user /bin/mkdir -p "$hooks_dir"
  run_as_user /bin/cp "$src" "$hook_py"
  write_env_and_wrapper "$hooks_dir" "$app" "$subsystem" "$hook_py" "$env_file" "$wrapper"

  # Gemini CLI hooks live under "hooks.AfterTool" in settings.json.
  run_as_user "$PYTHON_BIN" - "$settings" "$wrapper" <<'PYEOF'
import json, os, sys
settings_path, wrapper = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
hooks = cfg.setdefault("hooks", {})
groups = hooks.setdefault("AfterTool", [])
def has_ours(g):
    return any(h.get("command") == wrapper for h in g.get("hooks", []))
groups = [g for g in groups if not has_ours(g)]
groups.append({"matcher": ".*", "hooks": [{"type": "command", "command": wrapper}]})
hooks["AfterTool"] = groups
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  log "Gemini CLI: hook registered in $settings (app=$app)"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall_all() {
  local home="$USER_HOME"

  # Claude Code — strip our PostToolUse group from settings.json.
  local claude_settings="$home/.claude/settings.json"
  local claude_wrapper="$home/.claude/hooks/${INSTALL_BASENAME}.sh"
  if run_as_user /bin/test -f "$claude_settings"; then
    run_as_user "$PYTHON_BIN" - "$claude_settings" "$claude_wrapper" <<'PYEOF'
import json, sys
settings_path, wrapper = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)
groups = cfg.get("hooks", {}).get("PostToolUse", [])
groups = [g for g in groups if not any(h.get("command") == wrapper for h in g.get("hooks", []))]
cfg.setdefault("hooks", {})["PostToolUse"] = groups
with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  fi

  # Codex — remove our delimited block (begin marker through end marker, inclusive).
  local codex_config="$home/.codex/config.toml"
  if run_as_user /bin/test -f "$codex_config"; then
    run_as_user "$PYTHON_BIN" - "$codex_config" "$MARKER_BEGIN" "$MARKER_END" <<'PYEOF'
import re, sys
config_path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(config_path) as f:
    text = f.read()
# Remove everything from the begin marker through the end marker, inclusive,
# plus the blank line we inserted before it.
pattern = re.compile(r"\n*" + re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.S)
new = pattern.sub("\n", text)
with open(config_path, "w") as f:
    f.write(new)
PYEOF
  fi

  # Gemini — strip our AfterTool group from settings.json.
  local gemini_settings="$home/.gemini/settings.json"
  local gemini_wrapper="$home/.gemini/hooks/${INSTALL_BASENAME}.sh"
  if run_as_user /bin/test -f "$gemini_settings"; then
    run_as_user "$PYTHON_BIN" - "$gemini_settings" "$gemini_wrapper" <<'PYEOF'
import json, sys
settings_path, wrapper = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)
groups = cfg.get("hooks", {}).get("AfterTool", [])
groups = [g for g in groups if not any(h.get("command") == wrapper for h in g.get("hooks", []))]
cfg.setdefault("hooks", {})["AfterTool"] = groups
with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
  fi

  # Remove installed files across all agents.
  local f
  for agent_dir in "$home/.claude/hooks" "$home/.codex/hooks" "$home/.copilot/hooks" "$home/.gemini/hooks"; do
    for ext in py env sh json; do
      f="$agent_dir/${INSTALL_BASENAME}.$ext"
      run_as_user /bin/test -f "$f" && run_as_user /bin/rm -f "$f" && log "Removed $f" || true
    done
  done

  log "Uninstall complete. Restart any running agent sessions."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "$ACTION" == "uninstall" ]]; then
  log "Uninstalling repo-tracker hooks for $CONSOLE_USER..."
  uninstall_all
  exit 0
fi

[[ -n "$API_KEY" ]] || die "Coralogix API key is required (Jamf parameter \$4 or CX_API_KEY)."

log "Installing repo-tracker hooks for $CONSOLE_USER..."
log "  Endpoint: $ENDPOINT"
[[ -n "$APP_OVERRIDE" ]]       && log "  Application override: $APP_OVERRIDE"
[[ -n "$SUBSYSTEM_OVERRIDE" ]] && log "  Subsystem override: $SUBSYSTEM_OVERRIDE"

install_claude_code
install_codex
install_copilot
install_gemini

log "Done. New agent sessions will report their repository to Coralogix."
exit 0
