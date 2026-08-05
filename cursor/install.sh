#!/usr/bin/env bash
# cursor-coralogix install script (macOS / Linux)
#
# Deploys the Coralogix telemetry hook for Cursor into a single user account.
# Works for a local install and for MDM provisioning (Jamf, Ansible, etc.).
#
# Run with --help for usage. Requires Python 3.8+ available as python3.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./install.sh --api-key <key> --endpoint <url> --application <name> --subsystem <name>
  ./install.sh --env-file .env
  ./install.sh --uninstall

Each option can also be supplied through the environment variable named beside it.
Values from --env-file take precedence over both.

  --api-key       KEY    CX_API_KEY                      (required)
  --endpoint      URL    CX_OTLP_ENDPOINT                (required: your region's OTLP ingress)
  --application   NAME   CX_APPLICATION_NAME             (required; conventional: cursor)
  --subsystem     NAME   CX_SUBSYSTEM_NAME               (required; conventional: cursor-sessions)
  --mask-prompts         CURSOR_MASK_PROMPTS             (default: true)
  --no-mask-prompts      Send full prompt/response text (CURSOR_MASK_PROMPTS=false).
                         Wins if both --mask-prompts and --no-mask-prompts are passed.
  --omit-pre-tool-use    CURSOR_OMIT_PRE_TOOL_USE_SPANS  (default: false)
  --debug                CX_OTLP_DEBUG                   (default: false)
  --env-file      PATH   Load the values above from a .env file
  --hook-source   PATH   Path to hook.py (default: extension/resources/hook.py next to this script)
  --uninstall            Remove the hook
  -h, --help             Show this help
EOF
}

# ---------------------------------------------------------------------------
# Defaults (overridable via env vars)
# ---------------------------------------------------------------------------

API_KEY="${CX_API_KEY:-}"
ENDPOINT="${CX_OTLP_ENDPOINT:-}"
APPLICATION="${CX_APPLICATION_NAME:-}"
SUBSYSTEM="${CX_SUBSYSTEM_NAME:-}"
MASK_PROMPTS="${CURSOR_MASK_PROMPTS:-true}"
OMIT_PRE_TOOL_USE="${CURSOR_OMIT_PRE_TOOL_USE_SPANS:-false}"
DEBUG="${CX_OTLP_DEBUG:-false}"
HOOK_SOURCE=""
ENV_FILE=""
UNINSTALL=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# Resolved after parsing so that --no-mask-prompts wins regardless of flag order.
MASK_FLAG=""

require_value() {
  # $1 = flag, $2 = number of args still on the command line (including the flag)
  if [[ $2 -lt 2 ]]; then
    echo "Error: $1 requires a value." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --api-key)           require_value "$1" $#; API_KEY="$2";     shift 2 ;;
    --endpoint)          require_value "$1" $#; ENDPOINT="$2";    shift 2 ;;
    --application)       require_value "$1" $#; APPLICATION="$2"; shift 2 ;;
    --subsystem)         require_value "$1" $#; SUBSYSTEM="$2";   shift 2 ;;
    --hook-source)       require_value "$1" $#; HOOK_SOURCE="$2"; shift 2 ;;
    --env-file)          require_value "$1" $#; ENV_FILE="$2";    shift 2 ;;
    --mask-prompts)      [[ $MASK_FLAG == "false" ]] || MASK_FLAG="true"; shift ;;
    --no-mask-prompts)   MASK_FLAG="false";        shift ;;
    --omit-pre-tool-use) OMIT_PRE_TOOL_USE="true"; shift ;;
    --debug)             DEBUG="true";             shift ;;
    --uninstall)         UNINSTALL=true;           shift ;;
    -h|--help)           usage; exit 0 ;;
    *)
      echo "Error: unknown option: $1" >&2
      echo "Run './install.sh --help' for usage." >&2
      exit 1
      ;;
  esac
done

if [[ -n "$MASK_FLAG" ]]; then
  MASK_PROMPTS="$MASK_FLAG"
fi

# ---------------------------------------------------------------------------
# Load .env file if provided
# ---------------------------------------------------------------------------

# Strips an unquoted trailing comment, surrounding quotes and stray whitespace,
# so a value pasted straight out of the docs ("https://... # see table") still
# reaches the env file clean.
clean_env_value() {
  local v="$1"
  v="${v%%[[:space:]]#*}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ ${#v} -ge 2 && ${v:0:1} == '"' && ${v: -1} == '"' ]] \
    || [[ ${#v} -ge 2 && ${v:0:1} == "'" && ${v: -1} == "'" ]]; then
    v="${v:1:${#v}-2}"
  fi
  printf '%s' "$v"
}

if [[ -n "$ENV_FILE" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: env file not found: $ENV_FILE" >&2
    exit 1
  fi
  # `|| [[ -n "$key" ]]` keeps the last line when the file has no trailing newline.
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key//[[:space:]]/}"
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="$(clean_env_value "${value:-}")"
    case "$key" in
      CX_API_KEY)                     API_KEY="$value" ;;
      CX_OTLP_ENDPOINT)               ENDPOINT="$value" ;;
      CX_APPLICATION_NAME)            APPLICATION="$value" ;;
      CX_SUBSYSTEM_NAME)              SUBSYSTEM="$value" ;;
      CURSOR_MASK_PROMPTS)            MASK_PROMPTS="$value" ;;
      CURSOR_OMIT_PRE_TOOL_USE_SPANS) OMIT_PRE_TOOL_USE="$value" ;;
      CX_OTLP_DEBUG)                  DEBUG="$value" ;;
    esac
  done < "$ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.cursor/hooks"
HOOKS_JSON="$HOME/.cursor/hooks.json"
INSTALLED_PY="$HOOKS_DIR/coralogix_hook.py"
INSTALLED_ENV="$HOOKS_DIR/coralogix_hook.env"
WRAPPER_SH="$HOOKS_DIR/coralogix_hook.sh"

# ---------------------------------------------------------------------------
# Python (needed by both install and uninstall to edit hooks.json)
# ---------------------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found on PATH. Install Python 3.8+ and re-run." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if $UNINSTALL; then
  echo "Removing Coralogix hook..."

  python3 - "$HOOKS_JSON" "$WRAPPER_SH" <<'PYEOF'
import json, sys

hooks_json, wrapper = sys.argv[1], sys.argv[2]
try:
    with open(hooks_json, encoding="utf-8") as f:
        config = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(config, dict) or not isinstance(config.get("hooks"), dict):
    sys.exit(0)
hooks = config["hooks"]
for event in list(hooks):
    if not isinstance(hooks[event], list):
        continue
    remaining = [e for e in hooks[event] if not (isinstance(e, dict) and e.get("command") == wrapper)]
    # Drop the event entirely when we were its only hook, so uninstalling
    # leaves hooks.json as it was rather than littered with empty arrays.
    if remaining:
        hooks[event] = remaining
    else:
        del hooks[event]
with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF

  for f in "$INSTALLED_PY" "$INSTALLED_ENV" "$WRAPPER_SH"; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      echo "Removed: $f"
    fi
  done

  echo "Done. Restart Cursor to deactivate telemetry."
  echo "Cached conversation state remains in ~/.cursor-hook-state (safe to delete)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

if [[ -z "$API_KEY" ]]; then
  echo "Error: --api-key or CX_API_KEY is required." >&2
  exit 1
fi

if [[ -z "$ENDPOINT" ]]; then
  echo "Error: --endpoint or CX_OTLP_ENDPOINT is required (your region's OTLP ingress, e.g. https://ingress.<domain>)." >&2
  exit 1
fi

if [[ -z "$APPLICATION" ]]; then
  echo "Error: --application or CX_APPLICATION_NAME is required (conventional: cursor)." >&2
  exit 1
fi

if [[ -z "$SUBSYSTEM" ]]; then
  echo "Error: --subsystem or CX_SUBSYSTEM_NAME is required (conventional: cursor-sessions)." >&2
  exit 1
fi

# Reject anything that would put the API key on the wire in cleartext. http:// is
# allowed only for a collector on this machine. Kept in step with the same check
# in install.ps1 and hook.py.
HTTPS_RE='^https://[^[:space:]]+$'
LOCAL_RE='^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$)'
if ! [[ $ENDPOINT =~ $HTTPS_RE || $ENDPOINT =~ $LOCAL_RE ]]; then
  echo "Error: invalid --endpoint: $ENDPOINT" >&2
  echo "It must start with https:// (or http://localhost, http://127.0.0.1, http://[::1] for a local collector) and contain no spaces." >&2
  exit 1
fi

if [[ -z "$HOOK_SOURCE" ]]; then
  HOOK_SOURCE="$SCRIPT_DIR/extension/resources/hook.py"
fi

if [[ ! -f "$HOOK_SOURCE" ]]; then
  echo "Error: hook.py not found at $HOOK_SOURCE" >&2
  echo "Use --hook-source <path> to specify the location." >&2
  exit 1
fi
HOOK_SOURCE="$(cd "$(dirname "$HOOK_SOURCE")" && pwd)/$(basename "$HOOK_SOURCE")"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

echo "Installing Coralogix hook for Cursor..."

# 1. Create hooks directory
mkdir -p "$HOOKS_DIR"

# 2. Write env file (credentials — chmod 600 before the key is written to it)
touch "$INSTALLED_ENV"
chmod 600 "$INSTALLED_ENV"
cat > "$INSTALLED_ENV" <<EOF
CX_API_KEY=$API_KEY
CX_OTLP_ENDPOINT=$ENDPOINT
CX_APPLICATION_NAME=$APPLICATION
CX_SUBSYSTEM_NAME=$SUBSYSTEM
CURSOR_MASK_PROMPTS=$MASK_PROMPTS
CURSOR_OMIT_PRE_TOOL_USE_SPANS=$OMIT_PRE_TOOL_USE
CX_OTLP_DEBUG=$DEBUG
EOF
echo "Env written:    $INSTALLED_ENV"

# 3. Copy hook.py
cp "$HOOK_SOURCE" "$INSTALLED_PY"
echo "Hook installed: $INSTALLED_PY"

# 4. Write shell wrapper
cat > "$WRAPPER_SH" <<'EOF'
#!/usr/bin/env bash
# Auto-generated by the cursor-coralogix install script — do not edit manually
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HOOK_DIR/coralogix_hook.env"

# Allowlist: the env file only ever holds these keys; refusing anything else
# closes off a PYTHONPATH-style injection surface if it is ever tampered with.
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      CX_API_KEY=*|CX_OTLP_ENDPOINT=*|CX_APPLICATION_NAME=*|CX_SUBSYSTEM_NAME=*|CURSOR_MASK_PROMPTS=*|CURSOR_OMIT_PRE_TOOL_USE_SPANS=*|CX_OTLP_DEBUG=*)
        export "${line%%=*}=${line#*=}"
        ;;
    esac
  done < "$ENV_FILE"
fi

# No interpreter: exit quietly. A hook must never break the Cursor session.
command -v python3 >/dev/null 2>&1 || exit 0

exec python3 "$HOOK_DIR/coralogix_hook.py"
EOF
chmod 755 "$WRAPPER_SH"
echo "Wrapper:        $WRAPPER_SH"

# 5. Merge hooks.json
python3 - "$HOOKS_JSON" "$WRAPPER_SH" <<'PYEOF'
import json, os, sys

HOOK_EVENTS = [
    "sessionStart", "sessionEnd", "beforeSubmitPrompt",
    "preToolUse", "postToolUse", "postToolUseFailure",
    "beforeShellExecution", "afterShellExecution",
    "beforeMCPExecution", "afterMCPExecution",
    "beforeReadFile", "afterFileEdit", "preCompact", "stop",
    "subagentStart", "subagentStop", "afterAgentResponse", "afterAgentThought",
]

hooks_json, wrapper = sys.argv[1], sys.argv[2]
entry = {"command": wrapper, "timeout": 10}

try:
    with open(hooks_json, encoding="utf-8") as f:
        config = json.load(f)
except (OSError, ValueError):
    config = {}

if not isinstance(config, dict):
    config = {}
config.setdefault("version", 1)
if not isinstance(config.get("hooks"), dict):
    config["hooks"] = {}

for event in HOOK_EVENTS:
    current = config["hooks"].get(event)
    current = current if isinstance(current, list) else []
    # Re-running the installer replaces our entry instead of appending a duplicate.
    existing = [e for e in current if not (isinstance(e, dict) and e.get("command") == wrapper)]
    existing.append(entry)
    config["hooks"][event] = existing

os.makedirs(os.path.dirname(hooks_json), exist_ok=True)
with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
echo "hooks.json:     $HOOKS_JSON"

# 6. Install Python dependencies
echo "Installing Python dependencies..."
PACKAGES=(opentelemetry-sdk opentelemetry-exporter-otlp-proto-http)
PIP=(python3 -m pip install --quiet --user --no-warn-script-location)
# The retry adds --break-system-packages for PEP 668 environments (Homebrew,
# Debian), where a plain --user install is refused.
if ! "${PIP[@]}" "${PACKAGES[@]}" >/dev/null 2>&1 \
  && ! "${PIP[@]}" --break-system-packages "${PACKAGES[@]}"; then
  echo "Warning: Python dependencies could not be installed automatically." >&2
  echo "Install them manually, then restart Cursor:" >&2
  echo "  python3 -m pip install --user ${PACKAGES[*]}" >&2
else
  echo "Python dependencies installed."
fi

echo ""
echo "Done. Restart Cursor to activate telemetry."
echo "  Application : $APPLICATION"
echo "  Subsystem   : $SUBSYSTEM"
echo "  Endpoint    : $ENDPOINT"
