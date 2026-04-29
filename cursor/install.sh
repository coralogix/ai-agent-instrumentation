#!/usr/bin/env bash
# cursor-coralogix MDM install script
#
# Deploys the Coralogix telemetry hook for Cursor to a single user account.
# Designed to be run by an MDM (Jamf, Intune, Ansible, etc.) during provisioning.
#
# Usage:
#   ./install.sh --api-key <key> --endpoint <url> [options]
#   ./install.sh --env-file .env                  (load credentials from a .env file)
#
# All flags can also be set via environment variables.
#
# Options:
#   --api-key       KEY    CX_API_KEY          (required unless --env-file is used)
#   --endpoint      URL    CX_OTLP_ENDPOINT    (default: https://ingress.eu2.coralogix.com)
#   --application   NAME   CX_APPLICATION_NAME (default: cursor)
#   --subsystem     NAME   CX_SUBSYSTEM_NAME   (default: ai-agent)
#   --mask-prompts         CURSOR_MASK_PROMPTS (default: false)
#   --omit-pre-tool-use    CURSOR_OMIT_PRE_TOOL_USE_SPANS (default: false)
#   --debug                CX_OTLP_DEBUG       (default: false)
#   --env-file      PATH   Load credentials from a .env file (local use)
#   --hook-source   PATH   Path to hook.py     (default: ../extension/resources/hook.py)
#   --uninstall            Remove the hook

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (overridable via env vars)
# ---------------------------------------------------------------------------

API_KEY="${CX_API_KEY:-}"
ENDPOINT="${CX_OTLP_ENDPOINT:-https://ingress.eu2.coralogix.com}"
APPLICATION="${CX_APPLICATION_NAME:-cursor}"
SUBSYSTEM="${CX_SUBSYSTEM_NAME:-ai-agent}"
MASK_PROMPTS="${CURSOR_MASK_PROMPTS:-false}"
OMIT_PRE_TOOL_USE="${CURSOR_OMIT_PRE_TOOL_USE_SPANS:-false}"
DEBUG="${CX_OTLP_DEBUG:-false}"
HOOK_SOURCE=""
ENV_FILE=""
UNINSTALL=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case $1 in
    --api-key)           API_KEY="$2";       shift 2 ;;
    --endpoint)          ENDPOINT="$2";      shift 2 ;;
    --application)       APPLICATION="$2";   shift 2 ;;
    --subsystem)         SUBSYSTEM="$2";     shift 2 ;;
    --mask-prompts)      MASK_PROMPTS="true"; shift ;;
    --omit-pre-tool-use) OMIT_PRE_TOOL_USE="true"; shift ;;
    --debug)             DEBUG="true";       shift ;;
    --hook-source)       HOOK_SOURCE="$2";   shift 2 ;;
    --env-file)          ENV_FILE="$2";      shift 2 ;;
    --uninstall)         UNINSTALL=true;     shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Load .env file if provided
# ---------------------------------------------------------------------------

if [[ -n "$ENV_FILE" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: env file not found: $ENV_FILE" >&2
    exit 1
  fi
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    key="${key// /}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$key" in
      CX_API_KEY)                    API_KEY="$value" ;;
      CX_OTLP_ENDPOINT)              ENDPOINT="$value" ;;
      CX_APPLICATION_NAME)           APPLICATION="$value" ;;
      CX_SUBSYSTEM_NAME)             SUBSYSTEM="$value" ;;
      CURSOR_MASK_PROMPTS)           MASK_PROMPTS="$value" ;;
      CURSOR_OMIT_PRE_TOOL_USE_SPANS) OMIT_PRE_TOOL_USE="$value" ;;
      CX_OTLP_DEBUG)                 DEBUG="$value" ;;
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
# Uninstall
# ---------------------------------------------------------------------------

if $UNINSTALL; then
  echo "Removing Coralogix hook..."

  python3 - "$HOOKS_JSON" "$WRAPPER_SH" <<'PYEOF'
import json, sys, os
hooks_json, wrapper = sys.argv[1], sys.argv[2]
try:
    with open(hooks_json) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)
hooks = config.get("hooks", {})
for event in list(hooks.keys()):
    hooks[event] = [e for e in hooks[event] if e.get("command") != wrapper]
with open(hooks_json, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF

  for f in "$INSTALLED_PY" "$INSTALLED_ENV" "$WRAPPER_SH"; do
    [ -f "$f" ] && rm -f "$f" && echo "Removed: $f"
  done

  echo "Done. Restart Cursor to deactivate telemetry."
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

if [[ -z "$API_KEY" ]]; then
  echo "Error: --api-key or CX_API_KEY is required." >&2
  exit 1
fi

# Resolve hook.py source
if [[ -z "$HOOK_SOURCE" ]]; then
  HOOK_SOURCE="$SCRIPT_DIR/extension/resources/hook.py"
fi

HOOK_SOURCE="$(cd "$(dirname "$HOOK_SOURCE")" && pwd)/$(basename "$HOOK_SOURCE")"

if [[ ! -f "$HOOK_SOURCE" ]]; then
  echo "Error: hook.py not found at $HOOK_SOURCE" >&2
  echo "Use --hook-source <path> to specify the location." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

echo "Installing Coralogix hook for Cursor..."

# 1. Create hooks directory
mkdir -p "$HOOKS_DIR"

# 2. Write env file (credentials — chmod 600)
cat > "$INSTALLED_ENV" <<EOF
CX_API_KEY=$API_KEY
CX_OTLP_ENDPOINT=$ENDPOINT
CX_APPLICATION_NAME=$APPLICATION
CX_SUBSYSTEM_NAME=$SUBSYSTEM
CURSOR_MASK_PROMPTS=$MASK_PROMPTS
CURSOR_OMIT_PRE_TOOL_USE_SPANS=$OMIT_PRE_TOOL_USE
CX_OTLP_DEBUG=$DEBUG
EOF
chmod 600 "$INSTALLED_ENV"
echo "Env written:    $INSTALLED_ENV"

# 3. Copy hook.py
cp "$HOOK_SOURCE" "$INSTALLED_PY"
echo "Hook installed: $INSTALLED_PY"

# 4. Write shell wrapper
cat > "$WRAPPER_SH" <<EOF
#!/usr/bin/env bash
# Auto-generated by cursor-coralogix MDM install script — do not edit manually
set -a
source "$INSTALLED_ENV"
set +a
exec python3 "$INSTALLED_PY"
EOF
chmod 755 "$WRAPPER_SH"
echo "Wrapper:        $WRAPPER_SH"

# 5. Merge hooks.json
python3 - "$HOOKS_JSON" "$WRAPPER_SH" <<'PYEOF'
import json, sys, os

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
    with open(hooks_json) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

config.setdefault("version", 1)
config.setdefault("hooks", {})

for event in HOOK_EVENTS:
    existing = [e for e in config["hooks"].get(event, []) if e.get("command") != wrapper]
    existing.append(entry)
    config["hooks"][event] = existing

os.makedirs(os.path.dirname(hooks_json), exist_ok=True)
with open(hooks_json, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
echo "hooks.json:     $HOOKS_JSON"

# 6. Install Python dependencies
echo "Installing Python dependencies..."
PACKAGES=(opentelemetry-sdk opentelemetry-exporter-otlp-proto-http)
if ! python3 -m pip install --quiet --user "${PACKAGES[@]}" 2>/dev/null; then
  python3 -m pip install --quiet --user --break-system-packages "${PACKAGES[@]}"
fi
echo "Python dependencies installed."

echo ""
echo "Done. Restart Cursor to activate telemetry."
echo "  Application : $APPLICATION"
echo "  Subsystem   : $SUBSYSTEM"
echo "  Endpoint    : $ENDPOINT"
