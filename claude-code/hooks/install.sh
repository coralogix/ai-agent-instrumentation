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

# Installs the Claude Code repo-tracker hook.
# Idempotent — safe to run multiple times.
#
# Usage:
#   ./install.sh                        # interactive
#   CX_HOOK_API_KEY=xxx ./install.sh    # non-interactive
#   ./install.sh --env-file .env        # from env file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="repo_tracker.py"
DEST_DIR="$HOME/.claude/hooks"
STATE_DIR="$HOME/.claude-hook-state"
SETTINGS_FILE="$HOME/.claude/settings.json"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ENV_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: ./install.sh [--env-file <path>]"
            exit 1
            ;;
    esac
done

# Source env file if provided
if [[ -n "$ENV_FILE" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    else
        echo "Error: env file not found: $ENV_FILE"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
echo "Checking prerequisites..."

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found."
    echo "Install Python 3: https://www.python.org/downloads/"
    exit 1
fi

if ! command -v git &>/dev/null; then
    echo "Error: git is required but not found."
    exit 1
fi

echo "  python3 $(python3 --version 2>&1 | sed 's/Python //')"
echo "  git     $(git --version | sed 's/git version //')"

# ---------------------------------------------------------------------------
# Copy hook script
# ---------------------------------------------------------------------------
echo ""
echo "Installing hook script..."

mkdir -p "$DEST_DIR"
cp "$SCRIPT_DIR/$HOOK_SCRIPT" "$DEST_DIR/$HOOK_SCRIPT"
chmod +x "$DEST_DIR/$HOOK_SCRIPT"
echo "  Copied $HOOK_SCRIPT -> $DEST_DIR/$HOOK_SCRIPT"

# ---------------------------------------------------------------------------
# Write .env file (if API key is available)
# ---------------------------------------------------------------------------
ENV_DEST="$DEST_DIR/.env"
if [[ -n "${CX_HOOK_API_KEY:-}" ]]; then
    cat > "$ENV_DEST" <<ENVEOF
CX_HOOK_API_KEY=${CX_HOOK_API_KEY}
CX_HOOK_OTLP_ENDPOINT=${CX_HOOK_OTLP_ENDPOINT:-https://ingress.eu2.coralogix.com}
CX_HOOK_APPLICATION_NAME=${CX_HOOK_APPLICATION_NAME:-claude-code}
CX_HOOK_SUBSYSTEM_NAME=${CX_HOOK_SUBSYSTEM_NAME:-ai-agent}
ENVEOF
    echo "  Wrote env vars to $ENV_DEST"
fi

# ---------------------------------------------------------------------------
# Register hook in settings.json (using Python for zero-dep JSON merging)
# ---------------------------------------------------------------------------
echo ""
echo "Registering hook in $SETTINGS_FILE..."

# Build the hook command — source .env if it exists, then run the script
HOOK_CMD="python3 $DEST_DIR/$HOOK_SCRIPT"

python3 - "$SETTINGS_FILE" "$HOOK_CMD" <<'PYEOF'
import json
import sys
import os

settings_path = sys.argv[1]
hook_cmd = sys.argv[2]

# Load existing settings or start fresh
settings = {}
if os.path.isfile(settings_path):
    with open(settings_path) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError:
            settings = {}

# Ensure hooks.PostToolUse exists as a list
hooks = settings.setdefault("hooks", {})
post_tool_use = hooks.setdefault("PostToolUse", [])

# Check if our hook is already registered
already_registered = False
for entry in post_tool_use:
    entry_hooks = entry.get("hooks", [])
    for h in entry_hooks:
        if h.get("type") == "command" and h.get("command") == hook_cmd:
            already_registered = True
            break
    if already_registered:
        break

if not already_registered:
    post_tool_use.append({
        "hooks": [{
            "type": "command",
            "command": hook_cmd,
        }]
    })

# Write back
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

if already_registered:
    print("  Hook already registered (skipped)")
else:
    print("  Hook registered in PostToolUse")
PYEOF

# ---------------------------------------------------------------------------
# Create state directory
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR"
echo "  State directory: $STATE_DIR"

# ---------------------------------------------------------------------------
# Dry-run test
# ---------------------------------------------------------------------------
echo ""
echo "Running dry-run test..."

TEST_OUTPUT=$(echo '{"session_id":"install-test","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | CX_HOOK_DEBUG=1 CX_HOOK_API_KEY="${CX_HOOK_API_KEY:-test}" python3 "$DEST_DIR/$HOOK_SCRIPT" 2>&1) || true

if echo "$TEST_OUTPUT" | grep -q "\[repo-tracker\]"; then
    echo "  Dry-run passed (hook script parses events correctly)"
else
    echo "  Warning: dry-run output unexpected. Check $DEST_DIR/$HOOK_SCRIPT"
fi

# Clean up test state
rm -f "$STATE_DIR/install-test.repos"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "====================================="
echo "  Repo-tracker hook installed!"
echo "====================================="
echo ""
if [[ -z "${CX_HOOK_API_KEY:-}" ]]; then
    echo "Next steps:"
    echo "  1. Set env vars (choose one):"
    echo "     a. Managed Settings (recommended for teams):"
    echo "        Paste the hook config into Claude.ai Admin Settings."
    echo "        See the README for the exact JSON block."
    echo ""
    echo "     b. Per-developer env file:"
    echo "        cp $SCRIPT_DIR/.env.example $ENV_DEST"
    echo "        Edit $ENV_DEST with your Coralogix API key"
    echo "        Re-run: ./install.sh --env-file $ENV_DEST"
    echo ""
    echo "  2. Start a Claude Code session and use some tools"
    echo "  3. Check Coralogix Metrics Explorer for: claude_code_session_repo_info"
else
    echo "Configuration:"
    echo "  Endpoint: ${CX_HOOK_OTLP_ENDPOINT:-https://ingress.eu2.coralogix.com}"
    echo "  App:      ${CX_HOOK_APPLICATION_NAME:-claude-code}"
    echo "  Subsystem: ${CX_HOOK_SUBSYSTEM_NAME:-ai-agent}"
    echo ""
    echo "Start a Claude Code session and use some tools."
    echo "Then check Coralogix Metrics Explorer for: claude_code_session_repo_info"
fi
