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
# Jamf deployment — Coralogix hook for GitHub Copilot CLI
# ===========================================================================
#
# Installs hooks/copilot.py and ~/.copilot/hooks/coralogix.json for the
# logged-in console user, fleet-wide via a Jamf Pro policy. Credentials are
# written into each hook's `env` block (Copilot injects them) — no shell
# exports, wrappers, or separate files.
#
# Jamf runs policy scripts as ROOT; this hook is per-user, so the script
# detects the console user and performs all writes AS that user.
#
# Jamf parameters ($1-$3 are reserved by Jamf for mount/computer/username):
#   $4  Coralogix Send-Your-Data API key   (required)
#   $5  Coralogix OTLP ingress endpoint     (required, e.g. https://ingress.eu2.coralogix.com)
#   $6  Application name                     (default: copilot)
#   $7  Subsystem name                       (default: copilot-sessions)
#   $8  Mode: "full" (repo + prompts + responses, default) | "mask" (no text) |
#            "repo-only" (metric only)
#   $9  "uninstall" to remove
#
# The hook source (hooks/copilot.py) is read from this script's directory by
# default; override with the HOOK_SOURCE_DIR env var (e.g. when deployed to
# /Library/Application Support/... by a companion package).
# ===========================================================================

set -euo pipefail

API_KEY="${4:-${CX_API_KEY:-}}"
ENDPOINT="${5:-${CX_OTLP_ENDPOINT:-}}"
APPLICATION="${6:-${CX_APPLICATION_NAME:-copilot}}"
SUBSYSTEM="${7:-${CX_SUBSYSTEM_NAME:-copilot-sessions}}"
MODE="${8:-full}"
ACTION="${9:-install}"

ENDPOINT="${ENDPOINT%/}"; ENDPOINT="${ENDPOINT%:443}"
[[ -z "$ENDPOINT" || "$ENDPOINT" == http://* || "$ENDPOINT" == https://* ]] || ENDPOINT="https://$ENDPOINT"

log() { echo "[coralogix-copilot] $*"; }
die() { echo "[coralogix-copilot] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Console user
# ---------------------------------------------------------------------------

CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
  die "No regular user is logged in at the console (got: '${CONSOLE_USER:-none}')."
fi
USER_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
[[ -d "$USER_HOME" ]] || die "Could not resolve home directory for $CONSOLE_USER."
log "Console user: $CONSOLE_USER ($USER_HOME)"

run_as_user() {
  if [[ "$(/usr/bin/id -u)" == "$USER_UID" ]]; then "$@"; else /usr/bin/sudo -u "$CONSOLE_USER" "$@"; fi
}
run_as_user_shell() { run_as_user /bin/bash -lc "$1"; }

HOOKS_DIR="$USER_HOME/.copilot/hooks"
INSTALLED_PY="$HOOKS_DIR/copilot.py"
HOOK_JSON="$HOOKS_DIR/coralogix.json"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ "$ACTION" == "uninstall" ]]; then
  log "Uninstalling Coralogix Copilot hook for $CONSOLE_USER..."
  for f in "$INSTALLED_PY" "$HOOK_JSON"; do
    run_as_user /bin/test -f "$f" && run_as_user /bin/rm -f "$f" && log "Removed $f" || true
  done
  run_as_user /bin/rm -rf "$HOOKS_DIR/.coralogix-state" 2>/dev/null || true
  log "Done."
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

[[ -n "$API_KEY" ]]  || die "Coralogix API key is required (Jamf parameter \$4 or CX_API_KEY)."
[[ -n "$ENDPOINT" ]] || die "OTLP endpoint is required (Jamf parameter \$5 or CX_OTLP_ENDPOINT)."

SOURCE_DIR="${HOOK_SOURCE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
HOOK_SRC="$SOURCE_DIR/hooks/copilot.py"
[[ -f "$HOOK_SRC" ]] || HOOK_SRC="$SOURCE_DIR/copilot.py"
[[ -f "$HOOK_SRC" ]] || die "hooks/copilot.py not found under $SOURCE_DIR (set HOOK_SOURCE_DIR)."

PYTHON_BIN="$(run_as_user_shell 'command -v python3 || true')"
[[ -n "$PYTHON_BIN" ]] || die "python3 not found in $CONSOLE_USER's PATH."

case "$MODE" in
  full)      WITH_PROMPTS=true;  LOG_PROMPTS=true ;;
  mask)      WITH_PROMPTS=true;  LOG_PROMPTS=false ;;
  repo-only) WITH_PROMPTS=false; LOG_PROMPTS=true ;;
  *) die "Unknown mode '$MODE' (use full | mask | repo-only)." ;;
esac

# ---------------------------------------------------------------------------
# Install (as the console user)
# ---------------------------------------------------------------------------

log "Installing for $CONSOLE_USER (mode=$MODE)..."
run_as_user /bin/mkdir -p "$HOOKS_DIR"
run_as_user /bin/cp "$HOOK_SRC" "$INSTALLED_PY"
log "Hook:   $INSTALLED_PY"

# Write coralogix.json with credentials in each hook's env block, then 600 it.
run_as_user /usr/bin/env \
  CMD="$PYTHON_BIN $INSTALLED_PY" WITH_PROMPTS="$WITH_PROMPTS" \
  CX_API_KEY="$API_KEY" CX_OTLP_ENDPOINT="$ENDPOINT" \
  CX_APPLICATION_NAME="$APPLICATION" CX_SUBSYSTEM_NAME="$SUBSYSTEM" CX_HOOK_LOG_PROMPTS="$LOG_PROMPTS" \
  "$PYTHON_BIN" - "$HOOK_JSON" <<'PYEOF'
import json, os, sys
hook_json = sys.argv[1]
env = {"CX_API_KEY": os.environ["CX_API_KEY"], "CX_OTLP_ENDPOINT": os.environ["CX_OTLP_ENDPOINT"]}
for k in ("CX_APPLICATION_NAME", "CX_SUBSYSTEM_NAME"):
    if os.environ.get(k):
        env[k] = os.environ[k]
env["CX_HOOK_LOG_PROMPTS"] = os.environ["CX_HOOK_LOG_PROMPTS"]
cmd = os.environ["CMD"]
def entry(t): return {"type": "command", "bash": cmd, "env": env, "timeoutSec": t}
hooks = {"postToolUse": [entry(10)]}
if os.environ["WITH_PROMPTS"] == "true":
    hooks["userPromptSubmitted"] = [entry(10)]
    hooks["agentStop"] = [entry(15)]   # 15s: transcript-flush backoff can take ~4s
    hooks["sessionEnd"] = [entry(15)]
with open(hook_json, "w") as f:
    json.dump({"version": 1, "hooks": hooks}, f, indent=2)
    f.write("\n")
PYEOF
run_as_user /bin/chmod 600 "$HOOK_JSON"
log "Config: $HOOK_JSON (chmod 600; credentials in env blocks)"

log "Done. New Copilot sessions will report to Coralogix (app=$APPLICATION)."
exit 0
