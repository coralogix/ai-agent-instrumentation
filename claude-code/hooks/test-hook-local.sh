#!/bin/zsh
# ==============================================================================
# Local hook test harness — spawns the hook EXACTLY like Claude Code does:
#   - executed through `sh -c "<command>"` (the shell form Claude Code uses)
#   - the PostToolUse event JSON delivered on STDIN
#   - config read by the hook itself from ~/.claude/remote-settings.json
#     (same file Claude Code writes), so no admin-console edits needed
#
# Iterate on hooks/claude.sh and re-run this — no need to touch the hook
# registration in the admin console each time.
#
# Usage:
#   ./hooks/test-hook-local.sh                 # runs ./hooks/claude.sh
#   ./hooks/test-hook-local.sh /usr/local/bin/claude.sh   # runs deployed copy
#   HOOK_CMD='...' ./hooks/test-hook-local.sh  # test an exact command string
#
# It prints a unique session_id marker so you can find the metric in Coralogix.
# ==============================================================================

set -e

# Resolve the script path to test (default: the repo copy next to this file).
SCRIPT_DIR="${0:A:h}"
HOOK_SCRIPT="${1:-$SCRIPT_DIR/claude.sh}"

# The command Claude Code would run. Override with HOOK_CMD to test the exact
# command string from managed settings.
HOOK_CMD="${HOOK_CMD:-/bin/sh \"$HOOK_SCRIPT\"}"

# A unique marker so the emitted metric is easy to find.
MARKER="localtest-$(date +%s)"
# Escape the cwd for safe embedding in the JSON event (paths can contain " or \).
CWD_ESC="$(pwd | sed 's/\\/\\\\/g; s/"/\\"/g')"
EVENT="{\"session_id\":\"$MARKER\",\"cwd\":\"$CWD_ESC\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$CWD_ESC/README.md\"},\"user_email\":\"yoav.shaked@coralogix.com\"}"

echo "hook command : $HOOK_CMD"
echo "event stdin  : $EVENT"
echo "marker       : $MARKER"
echo "--- running (sh -c, event piped to stdin, exactly like Claude Code) ---"

# Spawn exactly like Claude Code: shell form + event JSON on stdin. Disable
# errexit around the run so the exit code and the query hint below always print,
# even when the hook command itself exits non-zero (the case worth diagnosing).
set +e
printf '%s' "$EVENT" | sh -c "$HOOK_CMD"
RC=$?
set -e

echo "--- hook exit code: $RC ---"
echo
echo "Now look up the metric in Coralogix (metrics have ~30-60s ingest lag):"
echo "  cx metrics query 'claude_code_session_repo_info{session_id=\"$MARKER\"}' --region eu2 -o json"
echo
echo "Note: the hook swallows all errors and exits 0 by design, so exit 0 does"
echo "NOT prove delivery — confirm via the query above."
