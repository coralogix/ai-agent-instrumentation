#!/bin/zsh
# ==============================================================================
# Local hook test harness — spawns the hook EXACTLY like Codex does:
#   - executed through `sh -c "<command>"` (the shell form Codex uses)
#   - the PostToolUse event JSON delivered on STDIN, in the exact field shape
#     Codex 0.149 emits (captured from a live session)
#   - config read by the hook itself from ~/.codex/config.toml (the same
#     [otel.exporter.otlp-http] block Codex exports with)
#
# Iterate on hooks/codex.sh and re-run this — no trust re-approval needed,
# because Codex itself is not involved.
#
# Usage:
#   ./hooks/test-hook-local.sh                 # runs ./hooks/codex.sh
#   ./hooks/test-hook-local.sh /usr/local/bin/codex-repo-tracker.sh
#   HOOK_CMD='...' ./hooks/test-hook-local.sh  # test an exact command string
#
# It prints a unique session_id marker so you can find the metric in Coralogix.
# ==============================================================================

set -e

# Resolve the script path to test (default: the repo copy next to this file).
SCRIPT_DIR="${0:A:h}"
HOOK_SCRIPT="${1:-$SCRIPT_DIR/codex.sh}"

# The command Codex would run. Override with HOOK_CMD to test the exact
# command string from hooks.json.
HOOK_CMD="${HOOK_CMD:-/bin/sh \"$HOOK_SCRIPT\"}"

# A unique marker so the emitted metric is easy to find.
MARKER="localtest-$(date +%s)"
# Escape the cwd for safe embedding in the JSON event (paths can contain " or \).
CWD_ESC="$(pwd | sed 's/\\/\\\\/g; s/"/\\"/g')"
EVENT="{\"session_id\":\"$MARKER\",\"turn_id\":\"$MARKER-turn\",\"transcript_path\":\"$HOME/.codex/sessions/rollout-test.jsonl\",\"cwd\":\"$CWD_ESC\",\"hook_event_name\":\"PostToolUse\",\"model\":\"gpt-5.5\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -1\"},\"tool_response\":\"README.md\\n\",\"tool_use_id\":\"call_localtest\"}"

echo "hook command : $HOOK_CMD"
echo "event stdin  : $EVENT"
echo "marker       : $MARKER"
echo "--- running (sh -c, event piped to stdin, exactly like Codex) ---"

# Spawn exactly like Codex: shell form + event JSON on stdin. Disable errexit
# around the run so the exit code and the query hint below always print, even
# when the hook command itself exits non-zero (the case worth diagnosing).
set +e
printf '%s' "$EVENT" | sh -c "$HOOK_CMD"
RC=$?
set -e

echo "--- hook exit code: $RC ---"
echo
echo "Now look up the metric in Coralogix (metrics have ~30-60s ingest lag):"
echo "  codex_session_repo_info{session_id=\"$MARKER\"}"
echo
echo "Note: the hook swallows all errors and exits 0 by design, so exit 0 does"
echo "NOT prove delivery — confirm via the query above."
