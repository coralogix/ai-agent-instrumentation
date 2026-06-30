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
# Jamf deployment — Coralogix native OTLP for GitHub Copilot CLI
# ===========================================================================
#
# Installs ~/.copilot/coralogix.env for the logged-in console user and wires it
# into their shell rc, fleet-wide via a Jamf Pro policy. Copilot's own native
# OpenTelemetry then exports traces + metrics straight to Coralogix — no hooks,
# no collector, no uploader.
#
# Jamf runs policy scripts as ROOT; the env file is per-user, so the script
# detects the console user and performs all writes AS that user.
#
# Jamf parameters ($1-$3 are reserved by Jamf for mount/computer/username):
#   $4  Coralogix Send-Your-Data API key   (required)
#   $5  Coralogix OTLP ingress endpoint     (required, e.g. https://ingress.eu2.coralogix.com)
#   $6  Application name                     (default: copilot-cli)
#   $7  Subsystem name                       (default: copilot-sessions)
#   $8  Mode: "full" (capture prompt/response content, default) | "metadata" (no text)
#   $9  "uninstall" to remove
#
# The same parameters work as environment variables for other MDMs
# (Intune, Ansible): CX_API_KEY, CX_OTLP_ENDPOINT, CX_APPLICATION_NAME,
# CX_SUBSYSTEM_NAME.
# ===========================================================================

set -euo pipefail

API_KEY="${4:-${CX_API_KEY:-}}"
ENDPOINT="${5:-${CX_OTLP_ENDPOINT:-}}"
APPLICATION="${6:-${CX_APPLICATION_NAME:-copilot-cli}}"
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

COPILOT_DIR="$USER_HOME/.copilot"
ENV_FILE="$COPILOT_DIR/coralogix.env"

# The shell rc files we manage, and the marker that tags our line in them so it
# can be found/removed idempotently.
RC_MARKER="# coralogix-copilot"
RC_LINE='[ -f "$HOME/.copilot/coralogix.env" ] && . "$HOME/.copilot/coralogix.env"  '"$RC_MARKER"
RC_FILES=("$USER_HOME/.zshrc" "$USER_HOME/.bash_profile" "$USER_HOME/.bashrc")

# Remove our marker line from an rc file (no-op if absent / file missing).
rc_strip() {
  local rc="$1"
  run_as_user /bin/test -f "$rc" || return 0
  local kept
  kept="$(run_as_user /usr/bin/grep -vF "$RC_MARKER" "$rc" 2>/dev/null || true)"
  if [[ -n "$kept" ]]; then printf '%s\n' "$kept"; fi | run_as_user /usr/bin/tee "$rc" >/dev/null
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ "$ACTION" == "uninstall" ]]; then
  log "Uninstalling Coralogix Copilot instrumentation for $CONSOLE_USER..."
  run_as_user /bin/test -f "$ENV_FILE" && run_as_user /bin/rm -f "$ENV_FILE" && log "Removed $ENV_FILE" || true
  for rc in "${RC_FILES[@]}"; do
    if run_as_user /bin/test -f "$rc"; then rc_strip "$rc"; log "Cleaned $rc"; fi
  done
  log "Done."
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

[[ -n "$API_KEY" ]]  || die "Coralogix API key is required (Jamf parameter \$4 or CX_API_KEY)."
[[ -n "$ENDPOINT" ]] || die "OTLP endpoint is required (Jamf parameter \$5 or CX_OTLP_ENDPOINT)."

case "$MODE" in
  full)     CAPTURE=true ;;
  metadata) CAPTURE=false ;;
  *) die "Unknown mode '$MODE' (use full | metadata)." ;;
esac

# ---------------------------------------------------------------------------
# Install (as the console user)
# ---------------------------------------------------------------------------

log "Installing for $CONSOLE_USER (mode=$MODE)..."
run_as_user /bin/mkdir -p "$COPILOT_DIR"

# Build the env file. Substitute the concrete settings now; keep the
# user.email command substitution literal (\$) so it resolves in the user's
# shell when the file is sourced.
ENV_CONTENT="$(cat <<EOF
# GitHub Copilot CLI → Coralogix — native OTLP. Deployed by jamf-deploy.sh.
# Sourced from your shell rc; Copilot's native OpenTelemetry exports traces
# (GenAI spans) + metrics straight to Coralogix. chmod 600 (holds an API key).

export COPILOT_OTEL_ENABLED=true
export OTEL_EXPORTER_OTLP_ENDPOINT=$ENDPOINT
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $API_KEY,CX-Application-Name=$APPLICATION,CX-Subsystem-Name=$SUBSYSTEM"

# true captures prompt/response/system/tool content into spans; false = metadata only.
export OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=$CAPTURE
export OTEL_SERVICE_NAME=github-copilot

# user.email attributes usage to a real person; cx.integration.source.* routes
# the telemetry to the ai.sessions.* dataset (CX-46024).
export OTEL_RESOURCE_ATTRIBUTES="user.email=\$(git config user.email 2>/dev/null || echo "\$USER"),cx.integration.source.type=copilot_cli_agent,cx.integration.source.version=1.0.0"

# Required on hosts without working IPv6: Copilot's OTLP client tries IPv6
# first and does not fall back to IPv4. Make Node resolve IPv4 first.
export NODE_OPTIONS="--dns-result-order=ipv4first"
EOF
)"

printf '%s\n' "$ENV_CONTENT" | run_as_user /usr/bin/tee "$ENV_FILE" >/dev/null
run_as_user /bin/chmod 600 "$ENV_FILE"
log "Env file: $ENV_FILE (chmod 600)"

# Wire it into the user's shell rc(s): always zsh (macOS default), plus bash
# rc files that already exist. Strip any prior line first so re-runs are idempotent.
run_as_user /usr/bin/touch "$USER_HOME/.zshrc"
for rc in "${RC_FILES[@]}"; do
  run_as_user /bin/test -f "$rc" || continue
  rc_strip "$rc"
  printf '%s\n' "$RC_LINE" | run_as_user /usr/bin/tee -a "$rc" >/dev/null
  log "Sourced from: $rc"
done

log "Done. New shells will instrument Copilot to Coralogix (app=$APPLICATION)."
exit 0
