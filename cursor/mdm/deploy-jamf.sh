#!/bin/bash
# ==============================================================================
# Jamf Deployment Script: Deploy the Cursor Coralogix hook to the console user
# Target Path: ~<console-user>/.cursor/hooks (written by install.sh)
#
# Runs as root via Jamf policy. Unlike the Claude Code hook (machine-wide,
# under /usr/local/bin), the Cursor hook is PER-USER: it must land under the
# logged-in user's home directory and register in that user's
# ~/.cursor/hooks.json. This script resolves the console user and re-execs
# install.sh as that user so $HOME resolves to their profile, not root's.
#
# ------------------------------------------------------------------------
# Packaging (required before this script can run)
# ------------------------------------------------------------------------
# This script does not embed install.sh or hook.py — hook.py is 500+ lines
# and duplicating it here would drift from the source of truth. Instead,
# stage a copy of the repo's cursor/ directory on the Mac before this script
# runs:
#
#   1. Build a .pkg (Composer, pkgbuild, or your packaging tool of choice)
#      whose payload places a copy of cursor/ (install.sh plus
#      extension/resources/hook.py) at a fixed staging path, e.g.
#      /usr/local/coralogix/cursor.
#   2. Upload the .pkg to Jamf Pro as a package, scoped to your fleet.
#   3. Add this script to the SAME Jamf policy, ordered to run AFTER the
#      package installs (Jamf runs package payloads before policy scripts,
#      so a normal "Packages" + "Scripts" policy already orders this right).
#   4. Fill in the script parameters below when adding this script to the
#      policy (Options tab).
#
# Alternative: a script-only policy that fetches cursor/ at runtime (curl,
# an internal artifact repo, etc.) works too, as long as it lands at the
# staging path passed in parameter 9 before this script executes.
#
# ------------------------------------------------------------------------
# Jamf script parameters (Jamf reserves $1-$3: mount point, computer name,
# username; policy parameters start at $4)
# ------------------------------------------------------------------------
#   $4  API key                    (required)  or CX_API_KEY env var
#   $5  OTLP endpoint              (required)  or CX_OTLP_ENDPOINT env var
#   $6  Application name           (optional)  or CX_APPLICATION_NAME env var (default: cursor)
#   $7  Subsystem name             (optional)  or CX_SUBSYSTEM_NAME env var (default: ai-agent)
#   $8  Mask prompts true/false    (optional)  or CURSOR_MASK_PROMPTS env var (default: false)
#   $9  Staging path for cursor/   (optional)  or CX_CURSOR_STAGING_DIR env var
#                                              (default: /usr/local/coralogix/cursor)
#
# Prefer injecting the API key (parameter 4) from Jamf Pro's parameter value
# at policy-run time (populated from your secrets manager / a Jamf Pro
# variable) rather than hardcoding it in a saved policy — anyone with policy
# read access in Jamf can otherwise see it in plain text.
#
# No preflight checks beyond console-user and staging-path resolution: the
# underlying install.sh already validates the API key, endpoint, and Python
# availability, and is idempotent — safe to re-run on every policy check-in.
# ==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve config: Jamf parameters take priority, env vars are the fallback
# (useful for testing this script directly, e.g. `sudo bash deploy-jamf.sh`).
# ---------------------------------------------------------------------------
API_KEY="${4:-${CX_API_KEY:-}}"
ENDPOINT="${5:-${CX_OTLP_ENDPOINT:-}}"
APPLICATION="${6:-${CX_APPLICATION_NAME:-cursor}}"
SUBSYSTEM="${7:-${CX_SUBSYSTEM_NAME:-ai-agent}}"
MASK_PROMPTS="${8:-${CURSOR_MASK_PROMPTS:-false}}"
STAGING_DIR="${9:-${CX_CURSOR_STAGING_DIR:-/usr/local/coralogix/cursor}}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: API key required (Jamf parameter 4 or CX_API_KEY env var)." >&2
  exit 1
fi

if [[ -z "$ENDPOINT" ]]; then
  echo "Error: OTLP endpoint required (Jamf parameter 5 or CX_OTLP_ENDPOINT env var)." >&2
  exit 1
fi

INSTALL_SH="$STAGING_DIR/install.sh"
if [[ ! -f "$INSTALL_SH" ]]; then
  echo "Error: install.sh not found at $INSTALL_SH" >&2
  echo "Stage the cursor/ directory at this path before running this script (see header)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the console (logged-in) user. Bail cleanly if nobody is at the
# console — the per-user hook has no real profile to install into.
# ---------------------------------------------------------------------------
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
  echo "Error: no user is logged in at the console (got: '${CONSOLE_USER:-<empty>}')." >&2
  echo "Skipping install; scope this policy to re-run after a user logs in (e.g. a login or recurring check-in trigger)." >&2
  exit 1
fi

CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null || true)"
if [[ -z "$CONSOLE_UID" ]]; then
  echo "Error: could not resolve a uid for console user '$CONSOLE_USER'." >&2
  exit 1
fi

CONSOLE_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
if [[ -z "$CONSOLE_HOME" || ! -d "$CONSOLE_HOME" ]]; then
  echo "Error: could not resolve a home directory for console user '$CONSOLE_USER'." >&2
  exit 1
fi

echo "Installing Cursor Coralogix hook for console user: $CONSOLE_USER (home: $CONSOLE_HOME)"

# ---------------------------------------------------------------------------
# Build the install.sh argv. --mask-prompts is only passed when explicitly
# enabled, matching install.sh's own default handling.
# ---------------------------------------------------------------------------
INSTALL_ARGS=(--api-key "$API_KEY" --endpoint "$ENDPOINT" --application "$APPLICATION" --subsystem "$SUBSYSTEM")
if [[ "$MASK_PROMPTS" == "true" ]]; then
  INSTALL_ARGS+=(--mask-prompts)
fi

# launchctl asuser bootstraps the console user's session context (the
# standard Jamf pattern for reliably running per-user operations from a root
# policy); sudo -u -H then sets $HOME for install.sh itself.
launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" -H bash "$INSTALL_SH" "${INSTALL_ARGS[@]}"

echo "Deployed Cursor Coralogix hook for $CONSOLE_USER."
exit 0
