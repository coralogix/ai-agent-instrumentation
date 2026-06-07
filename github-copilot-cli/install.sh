#!/usr/bin/env bash
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
# Install the Coralogix hooks for GitHub Copilot CLI
# ===========================================================================
#
# Always installs the repo-tracker (postToolUse -> copilot_cli_session_repo_info
# metric). With --with-prompts it also installs the prompt/response logger
# (userPromptSubmitted + agentStop -> copilot_cli.user_prompt /
# copilot_cli.assistant_message OTLP logs, mirroring Claude Code's structure).
#
# Both hooks are Python 3 stdlib only. Credentials are written to a single
# 0600 env file; the registered hooks are wrappers that source it, so they
# work regardless of how Copilot was launched.
#
# Usage:
#   ./install.sh --api-key <key> --endpoint <url> [--with-prompts] [options]
#   ./install.sh --env-file .env [--with-prompts]
#   ./install.sh --uninstall
#
# Options (all also accepted as environment variables):
#   --api-key      KEY    CX_API_KEY           (required unless --env-file)
#   --endpoint     URL    CX_OTLP_ENDPOINT     (required)
#   --application  NAME   CX_APPLICATION_NAME  (optional routing header)
#   --subsystem    NAME   CX_SUBSYSTEM_NAME    (optional routing header)
#   --user-email   EMAIL  CX_HOOK_USER_EMAIL   (optional; defaults to git config user.email)
#   --with-prompts        also log prompts AND responses (captures content!)
#   --mask-prompts        with --with-prompts, log only lengths/metadata (no text)
#   --env-file     PATH   load the above from a .env file
#   --uninstall           remove all installed hooks
# ===========================================================================

set -euo pipefail

API_KEY="${CX_API_KEY:-}"
ENDPOINT="${CX_OTLP_ENDPOINT:-}"
APPLICATION="${CX_APPLICATION_NAME:-}"
SUBSYSTEM="${CX_SUBSYSTEM_NAME:-}"
USER_EMAIL="${CX_HOOK_USER_EMAIL:-}"
ENV_FILE=""
WITH_PROMPTS=false
LOG_PROMPTS=true
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --api-key)     API_KEY="$2";     shift 2 ;;
    --endpoint)    ENDPOINT="$2";    shift 2 ;;
    --application) APPLICATION="$2"; shift 2 ;;
    --subsystem)   SUBSYSTEM="$2";   shift 2 ;;
    --user-email)  USER_EMAIL="$2";  shift 2 ;;
    --env-file)    ENV_FILE="$2";    shift 2 ;;
    --with-prompts) WITH_PROMPTS=true; shift ;;
    --mask-prompts) LOG_PROMPTS=false; shift ;;
    --uninstall)   UNINSTALL=true;   shift ;;
    -h|--help)     sed -n '15,45p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.copilot/hooks"
ENV_F="$HOOKS_DIR/coralogix.env"
REPO_PY="$HOOKS_DIR/coralogix_repo_tracker.py"
REPO_WRAPPER="$HOOKS_DIR/coralogix_repo_tracker.sh"
PROMPTS_PY="$HOOKS_DIR/coralogix_prompts.py"
PROMPTS_WRAPPER="$HOOKS_DIR/coralogix_prompts.sh"
HOOK_JSON="$HOOKS_DIR/coralogix.json"

# Old filenames from a previous version of this installer (cleaned up on every run).
LEGACY_FILES=(
  "$HOOKS_DIR/coralogix_repo_tracker.env"
  "$HOOKS_DIR/coralogix-repo-tracker.json"
)

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if $UNINSTALL; then
  echo "Removing Coralogix hooks for Copilot..."
  for f in "$ENV_F" "$REPO_PY" "$REPO_WRAPPER" "$PROMPTS_PY" "$PROMPTS_WRAPPER" \
           "$HOOK_JSON" "${LEGACY_FILES[@]}"; do
    [[ -f "$f" ]] && rm -f "$f" && echo "Removed: $f"
  done
  rm -rf "$HOOKS_DIR/.coralogix-state" 2>/dev/null || true
  echo "Done. Restart any running Copilot sessions."
  exit 0
fi

# ---------------------------------------------------------------------------
# Load .env if given
# ---------------------------------------------------------------------------

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || { echo "Error: env file not found: $ENV_FILE" >&2; exit 1; }
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    key="${key// /}"
    value="${value%\"}"; value="${value#\"}"
    case "$key" in
      CX_API_KEY)          API_KEY="${API_KEY:-$value}" ;;
      CX_OTLP_ENDPOINT)    ENDPOINT="${ENDPOINT:-$value}" ;;
      CX_APPLICATION_NAME) APPLICATION="${APPLICATION:-$value}" ;;
      CX_SUBSYSTEM_NAME)   SUBSYSTEM="${SUBSYSTEM:-$value}" ;;
      CX_HOOK_USER_EMAIL)  USER_EMAIL="${USER_EMAIL:-$value}" ;;
    esac
  done < "$ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Validate + normalize
# ---------------------------------------------------------------------------

[[ -n "$API_KEY" ]]  || { echo "Error: --api-key (or CX_API_KEY) is required." >&2; exit 1; }
[[ -n "$ENDPOINT" ]] || { echo "Error: --endpoint (or CX_OTLP_ENDPOINT) is required, e.g. https://ingress.eu2.coralogix.com" >&2; exit 1; }

ENDPOINT="${ENDPOINT%/}"; ENDPOINT="${ENDPOINT%:443}"
[[ "$ENDPOINT" == http://* || "$ENDPOINT" == https://* ]] || ENDPOINT="https://$ENDPOINT"

PYTHON_BIN="$(command -v python3 || true)"
[[ -n "$PYTHON_BIN" ]] || { echo "Error: python3 not found on PATH." >&2; exit 1; }

[[ -f "$SCRIPT_DIR/hooks/copilot.py" ]] || { echo "Error: hooks/copilot.py not found next to installer." >&2; exit 1; }
if $WITH_PROMPTS; then
  [[ -f "$SCRIPT_DIR/hooks/copilot_prompts.py" ]] || { echo "Error: hooks/copilot_prompts.py not found." >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

echo "Installing Coralogix hooks for GitHub Copilot CLI..."
mkdir -p "$HOOKS_DIR"

# Remove stale files from the older installer layout.
for f in "${LEGACY_FILES[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done

# 1. Shared credentials env file (0600)
umask 077
cat > "$ENV_F" <<EOF
# Auto-generated by github-copilot-cli/install.sh — do not edit manually
CX_API_KEY="$API_KEY"
CX_OTLP_ENDPOINT="$ENDPOINT"
CX_APPLICATION_NAME="$APPLICATION"
CX_SUBSYSTEM_NAME="$SUBSYSTEM"
CX_HOOK_USER_EMAIL="$USER_EMAIL"
CX_HOOK_LOG_PROMPTS="$LOG_PROMPTS"
EOF
chmod 600 "$ENV_F"
umask 022
echo "Env:     $ENV_F (chmod 600)"

# 2. Repo-tracker hook + wrapper
cp "$SCRIPT_DIR/hooks/copilot.py" "$REPO_PY"
cat > "$REPO_WRAPPER" <<EOF
#!/usr/bin/env bash
# Auto-generated by github-copilot-cli/install.sh — do not edit manually
set -a; source "$ENV_F"; set +a
exec "$PYTHON_BIN" "$REPO_PY"
EOF
chmod 755 "$REPO_WRAPPER"
echo "Hook:    $REPO_PY (repo-tracker)"

# 3. Prompts/response hook + wrapper (optional)
if $WITH_PROMPTS; then
  cp "$SCRIPT_DIR/hooks/copilot_prompts.py" "$PROMPTS_PY"
  cat > "$PROMPTS_WRAPPER" <<EOF
#!/usr/bin/env bash
# Auto-generated by github-copilot-cli/install.sh — do not edit manually
set -a; source "$ENV_F"; set +a
exec "$PYTHON_BIN" "$PROMPTS_PY"
EOF
  chmod 755 "$PROMPTS_WRAPPER"
  echo "Hook:    $PROMPTS_PY (prompts + responses, content=$LOG_PROMPTS)"
fi

# 4. Register the hooks in one config file
"$PYTHON_BIN" - "$HOOK_JSON" "$REPO_WRAPPER" "$($WITH_PROMPTS && echo "$PROMPTS_WRAPPER" || echo '')" <<'PYEOF'
import json, sys
hook_json, repo_wrapper, prompts_wrapper = sys.argv[1], sys.argv[2], sys.argv[3]
def cmd(w): return {"type": "command", "bash": w, "timeoutSec": 10}
hooks = {"postToolUse": [cmd(repo_wrapper)]}
if prompts_wrapper:
    hooks["userPromptSubmitted"] = [cmd(prompts_wrapper)]
    # agentStop = per-turn (catches flushed prior turns); sessionEnd = backstop
    # for the final turn, since events.jsonl is buffered and the last
    # assistant.message may not be flushed when agentStop fires.
    hooks["agentStop"] = [cmd(prompts_wrapper)]
    hooks["sessionEnd"] = [cmd(prompts_wrapper)]
with open(hook_json, "w") as f:
    json.dump({"version": 1, "hooks": hooks}, f, indent=2)
    f.write("\n")
PYEOF
echo "Config:  $HOOK_JSON"

# 5. Smoke test the repo-tracker
echo "Running a smoke test from $(pwd) ..."
echo "{\"sessionId\":\"install-smoke-test\",\"cwd\":\"$(pwd)\",\"toolName\":\"shell\",\"toolArgs\":{\"command\":\"true\"}}" | "$REPO_WRAPPER" \
  && echo "Smoke test exited cleanly."

echo ""
echo "Done. New Copilot sessions will report to Coralogix."
echo "  Endpoint    : $ENDPOINT"
echo "  Application : ${APPLICATION:-<unset — routed by API key>}"
echo "  repo-tracker: copilot_cli_session_repo_info (metric)"
$WITH_PROMPTS && echo "  prompts     : copilot_cli.user_prompt / copilot_cli.assistant_message (logs, content=$LOG_PROMPTS)"
echo ""
echo "Uninstall:  $0 --uninstall"
