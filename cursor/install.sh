#!/usr/bin/env bash
# cursor-coralogix MDM install script
#
# Deploys the Coralogix telemetry hook for Cursor to a single user account.
# Designed to be run by an MDM (Jamf, Intune, JumpCloud, Ansible, etc.) during
# provisioning, or by hand for a local setup.
#
# MDM note
#   MDMs run this as *root* in a bare environment: $HOME is unset and the
#   "current user" is root — but Cursor runs as the logged-in desktop user.
#   When it detects it is running as root, this script auto-resolves the console
#   user and installs into THAT user's ~/.cursor (and chowns the files back to
#   them). Override the target with --target-user <name> / TARGET_USER=<name>.
#
#   The hook (hook.py) is embedded in this script, so it is fully self-contained
#   — you can paste it straight into an MDM command runner with no repo alongside
#   it. Credentials are read from CLI flags OR environment variables, so an MDM
#   can inject CX_API_KEY / CX_OTLP_ENDPOINT from its secrets manager.
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
#   --hook-source   PATH   Path to hook.py     (default: embedded copy)
#   --target-user   NAME   TARGET_USER         Install for this user (default: console user when run as root)
#   --uninstall            Remove the hook

set -euo pipefail

# ╔═════════════════════════════════════════════════════════════════════════╗
# ║  ▼▼▼   MDM OPERATORS: FILL IN YOUR CORALOGIX DETAILS HERE   ▼▼▼          ║
# ║                                                                         ║
# ║  When you deploy via an MDM (JumpCloud / Jamf / Intune) you paste this   ║
# ║  whole script, so there are no command-line flags to pass. Put your      ║
# ║  values between the quotes below and they will be baked into the hook's  ║
# ║  env file, which is sourced and exported on EVERY hook run.              ║
# ║                                                                         ║
# ║  Only CFG_API_KEY is mandatory. CLI flags / CX_* environment variables   ║
# ║  (e.g. from an MDM secrets manager) still override anything set here.     ║
# ╚═════════════════════════════════════════════════════════════════════════╝

CFG_API_KEY=""                                     # REQUIRED — Coralogix Send-Your-Data API key
CFG_ENDPOINT="https://ingress.eu2.coralogix.com"   # OTLP ingress for your region (us1/us2/eu1/eu2/ap1/ap2/ap3)
CFG_APPLICATION="cursor"                           # applicationName as it appears in Coralogix
CFG_SUBSYSTEM="ai-agent"                            # subsystemName as it appears in Coralogix
CFG_MASK_PROMPTS="false"                            # "true" to redact prompt text from spans
CFG_OMIT_PRE_TOOL_USE="false"                       # "true" to skip preToolUse spans
CFG_DEBUG="false"                                   # "true" to print export debug info to stderr
CFG_TARGET_USER=""                                  # leave empty to auto-detect the logged-in user

# ╔═════════════════════════════════════════════════════════════════════════╗
# ║  ▲▲▲   END OF OPERATOR CONFIG — nothing to edit below this line   ▲▲▲    ║
# ╚═════════════════════════════════════════════════════════════════════════╝

# ---------------------------------------------------------------------------
# Defaults — precedence: CLI flag > CX_* env var > operator config block above
# ---------------------------------------------------------------------------

API_KEY="${CX_API_KEY:-$CFG_API_KEY}"
ENDPOINT="${CX_OTLP_ENDPOINT:-$CFG_ENDPOINT}"
APPLICATION="${CX_APPLICATION_NAME:-$CFG_APPLICATION}"
SUBSYSTEM="${CX_SUBSYSTEM_NAME:-$CFG_SUBSYSTEM}"
MASK_PROMPTS="${CURSOR_MASK_PROMPTS:-$CFG_MASK_PROMPTS}"
OMIT_PRE_TOOL_USE="${CURSOR_OMIT_PRE_TOOL_USE_SPANS:-$CFG_OMIT_PRE_TOOL_USE}"
DEBUG="${CX_OTLP_DEBUG:-$CFG_DEBUG}"
HOOK_SOURCE=""
ENV_FILE=""
UNINSTALL=false
TARGET_USER="${TARGET_USER:-$CFG_TARGET_USER}"

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
    --target-user)       TARGET_USER="$2";   shift 2 ;;
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
# Resolve the target user + home directory
#
# An MDM runs this as root with no $HOME. Installing into root's home is useless
# because Cursor runs as the logged-in user, so when we are root we detect the
# console user and install into THEIR home. When run by hand as a normal user we
# just use that user. --target-user / TARGET_USER always wins.
# ---------------------------------------------------------------------------

RUN_UID="$(id -u)"
UNAME_S="$(uname -s)"

if [[ -n "$TARGET_USER" ]]; then
  :  # explicit override — use as-is
elif [[ "$RUN_UID" -eq 0 ]]; then
  # macOS: the owner of /dev/console is the user logged into the GUI.
  if [[ "$UNAME_S" == "Darwin" ]]; then
    TARGET_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
  fi
  # Fall back to the invoking user (sudo) or login name (covers Linux MDMs).
  if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="${SUDO_USER:-${LOGNAME:-}}"
  fi
  if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo "Error: running as root but could not determine the target user." >&2
    echo "Pass --target-user <name> (or set TARGET_USER=<name>) and re-run." >&2
    exit 1
  fi
else
  TARGET_USER="$(id -un)"
fi

# Resolve that user's home directory.
TARGET_HOME=""
if [[ "$UNAME_S" == "Darwin" ]]; then
  TARGET_HOME="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
fi
if [[ -z "$TARGET_HOME" ]]; then
  TARGET_HOME="$(eval echo "~$TARGET_USER" 2>/dev/null || true)"
fi
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "Error: could not resolve a home directory for user '$TARGET_USER'." >&2
  exit 1
fi

# Are we root installing on behalf of a different user? If so we run per-user
# steps via sudo and chown the results back to them at the end.
IS_ROOT_FOR_OTHER=false
if [[ "$RUN_UID" -eq 0 && "$TARGET_USER" != "root" ]]; then
  IS_ROOT_FOR_OTHER=true
fi

run_as_user() {
  if $IS_ROOT_FOR_OTHER; then
    sudo -u "$TARGET_USER" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
HOOKS_DIR="$TARGET_HOME/.cursor/hooks"
HOOKS_JSON="$TARGET_HOME/.cursor/hooks.json"
INSTALLED_PY="$HOOKS_DIR/coralogix_hook.py"
INSTALLED_ENV="$HOOKS_DIR/coralogix_hook.env"
WRAPPER_SH="$HOOKS_DIR/coralogix_hook.sh"

# ---------------------------------------------------------------------------
# Embedded hook.py (base64)
#
# The block below is generated by ./build-installer.sh from the canonical
# extension/resources/hook.py — do NOT edit it by hand. Re-run build-installer.sh
# whenever hook.py changes so this stays in sync.
# ---------------------------------------------------------------------------

embedded_hook_b64() {
  cat <<'CX_HOOK_B64_EOF'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIGN1cnNvci1jb3JhbG9naXgtaG9vayAgdjIuMC4wCiMK
IyBDdXJzb3IgY2FsbHMgdGhpcyBzY3JpcHQgZm9yIGV2ZXJ5IGFnZW50IGxpZmVjeWNsZSBldmVu
dCwgcGFzc2luZyBhIEpTT04KIyBwYXlsb2FkIG9uIHN0ZGluLiBXZSBjb252ZXJ0IHRoZSBldmVu
dCB0byBhbiBPVExQIHRyYWNlIHNwYW4gYW5kIHNlbmQgaXQKIyB0byB0aGUgQ29yYWxvZ2l4IE9U
TFAgZW5kcG9pbnQgdmlhIHRoZSBuYXRpdmUgT1RlbCBTREsuCiMKIyBSZXF1aXJlZCBlbnYgdmFy
czoKIyAgIENYX0FQSV9LRVkgICAgICAgICAgLSBDb3JhbG9naXggU2VuZC1Zb3VyLURhdGEgQVBJ
IGtleQojICAgQ1hfT1RMUF9FTkRQT0lOVCAgICAtIGUuZy4gaHR0cHM6Ly9pbmdyZXNzLmV1Mi5j
b3JhbG9naXguY29tCiMgICBDWF9BUFBMSUNBVElPTl9OQU1FIC0gZS5nLiBjdXJzb3IgIChkZWZh
dWx0OiBjdXJzb3IpCiMgICBDWF9TVUJTWVNURU1fTkFNRSAgIC0gZS5nLiBhaS1hZ2VudCAoZGVm
YXVsdDogYWktYWdlbnQpCgppbXBvcnQgY29udGV4dGxpYgppbXBvcnQgaGFzaGxpYgppbXBvcnQg
anNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQpmcm9tIHBhdGhsaWIgaW1wb3J0
IFBhdGgKCnRyeToKICAgIGltcG9ydCBmY250bCBhcyBfZmNudGwKICAgIGRlZiBfbG9jayhmKTog
ICBfZmNudGwuZmxvY2soZiwgX2ZjbnRsLkxPQ0tfRVgpCiAgICBkZWYgX3VubG9jayhmKTogX2Zj
bnRsLmZsb2NrKGYsIF9mY250bC5MT0NLX1VOKQpleGNlcHQgSW1wb3J0RXJyb3I6CiAgICB0cnk6
CiAgICAgICAgaW1wb3J0IG1zdmNydCBhcyBfbXN2Y3J0CiAgICAgICAgZGVmIF9sb2NrKGYpOiAg
IF9tc3ZjcnQubG9ja2luZyhmLmZpbGVubygpLCBfbXN2Y3J0LkxLX0xPQ0ssIDEpCiAgICAgICAg
ZGVmIF91bmxvY2soZik6IF9tc3ZjcnQubG9ja2luZyhmLmZpbGVubygpLCBfbXN2Y3J0LkxLX1VO
TENLLCAxKQogICAgZXhjZXB0IEltcG9ydEVycm9yOgogICAgICAgIGRlZiBfbG9jayhfKTogICBw
YXNzCiAgICAgICAgZGVmIF91bmxvY2soXyk6IHBhc3MKCnRyeToKICAgIGZyb20gb3BlbnRlbGVt
ZXRyeSBpbXBvcnQgdHJhY2UKICAgIGZyb20gb3BlbnRlbGVtZXRyeS5zZGsudHJhY2UgaW1wb3J0
IFRyYWNlclByb3ZpZGVyCiAgICBmcm9tIG9wZW50ZWxlbWV0cnkuc2RrLnRyYWNlLmV4cG9ydCBp
bXBvcnQgU2ltcGxlU3BhblByb2Nlc3NvcgogICAgZnJvbSBvcGVudGVsZW1ldHJ5LnNkay5yZXNv
dXJjZXMgaW1wb3J0IFJlc291cmNlCiAgICBmcm9tIG9wZW50ZWxlbWV0cnkuZXhwb3J0ZXIub3Rs
cC5wcm90by5odHRwLnRyYWNlX2V4cG9ydGVyIGltcG9ydCBPVExQU3BhbkV4cG9ydGVyCiAgICBm
cm9tIG9wZW50ZWxlbWV0cnkudHJhY2UgaW1wb3J0IE5vblJlY29yZGluZ1NwYW4sIFNwYW5Db250
ZXh0LCBUcmFjZUZsYWdzLCBTdGF0dXMsIFN0YXR1c0NvZGUKZXhjZXB0IEltcG9ydEVycm9yOgog
ICAgc3lzLmV4aXQoCiAgICAgICAgImN1cnNvci1jb3JhbG9naXgtaG9vazogbWlzc2luZyBkZXBl
bmRlbmN5IOKAlCBydW46XG4iCiAgICAgICAgIiAgcGlwIGluc3RhbGwgb3BlbnRlbGVtZXRyeS1z
ZGsgb3BlbnRlbGVtZXRyeS1leHBvcnRlci1vdGxwLXByb3RvLWh0dHAiCiAgICApCgojIC0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLQojIENvbmZpZwojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQoKQ1hfQVBJX0tFWSAg
ICAgICAgICA9IG9zLmVudmlyb24uZ2V0KCJDWF9BUElfS0VZIiwgIiIpCkNYX09UTFBfRU5EUE9J
TlQgICAgPSBvcy5lbnZpcm9uLmdldCgiQ1hfT1RMUF9FTkRQT0lOVCIsICIiKS5yc3RyaXAoIi8i
KQpDWF9BUFBMSUNBVElPTl9OQU1FID0gb3MuZW52aXJvbi5nZXQoIkNYX0FQUExJQ0FUSU9OX05B
TUUiLCAiY3Vyc29yIikKQ1hfU1VCU1lTVEVNX05BTUUgICA9IG9zLmVudmlyb24uZ2V0KCJDWF9T
VUJTWVNURU1fTkFNRSIsICJhaS1hZ2VudCIpCk1BU0tfUFJPTVBUUyAgICAgICAgPSBvcy5lbnZp
cm9uLmdldCgiQ1VSU09SX01BU0tfUFJPTVBUUyIsICIiKS5sb3dlcigpID09ICJ0cnVlIgpPTUlU
X1BSRV9UT09MX1VTRSAgID0gb3MuZW52aXJvbi5nZXQoIkNVUlNPUl9PTUlUX1BSRV9UT09MX1VT
RV9TUEFOUyIsICIiKS5sb3dlcigpID09ICJ0cnVlIgpERUJVRyAgICAgICAgICAgICAgID0gb3Mu
ZW52aXJvbi5nZXQoIkNYX09UTFBfREVCVUciLCAiIikubG93ZXIoKSA9PSAidHJ1ZSIKCl9TRVJW
SUNFX1ZFUlNJT04gPSAiMi4wLjAiCgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQojIFN0YXRlIHBlcnNp
c3RlbmNlCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgpfU1RBVEVfRElSID0gUGF0aC5ob21lKCkgLyAi
LmN1cnNvci1ob29rLXN0YXRlIgoKCmRlZiBfc3RhdGVfZmlsZShjb252X2lkKToKICAgIGggPSBo
YXNobGliLnNoYTI1Nihjb252X2lkLmVuY29kZSgpKS5oZXhkaWdlc3QoKQogICAgcmV0dXJuIF9T
VEFURV9ESVIgLyAoaFs6MTZdICsgIi5qc29uIikKCgpkZWYgbG9hZF9zdGF0ZShjb252X2lkKToK
ICAgIHRyeToKICAgICAgICByZXR1cm4ganNvbi5sb2Fkcyhfc3RhdGVfZmlsZShjb252X2lkKS5y
ZWFkX3RleHQoKSkKICAgIGV4Y2VwdCAoRmlsZU5vdEZvdW5kRXJyb3IsIGpzb24uSlNPTkRlY29k
ZUVycm9yKToKICAgICAgICByZXR1cm4gTm9uZQoKCmRlZiBzYXZlX3N0YXRlKGNvbnZfaWQsIHN0
YXRlKToKICAgIGYgPSBfc3RhdGVfZmlsZShjb252X2lkKQogICAgZi53cml0ZV90ZXh0KGpzb24u
ZHVtcHMoc3RhdGUpKQogICAgZi5jaG1vZCgwbzYwMCkKCgpkZWYgZGVsZXRlX3N0YXRlKGNvbnZf
aWQpOgogICAgdHJ5OgogICAgICAgIF9zdGF0ZV9maWxlKGNvbnZfaWQpLnVubGluaygpCiAgICBl
eGNlcHQgRmlsZU5vdEZvdW5kRXJyb3I6CiAgICAgICAgcGFzcwoKCmRlZiBwcnVuZV9vbGRfc3Rh
dGVzKCk6CiAgICBjdXRvZmYgPSB0aW1lLnRpbWUoKSAtIDg2NDAwCiAgICB0cnk6CiAgICAgICAg
Zm9yIGYgaW4gX1NUQVRFX0RJUi5nbG9iKCIqLmpzb24iKToKICAgICAgICAgICAgaWYgZi5zdGF0
KCkuc3RfbXRpbWUgPCBjdXRvZmY6CiAgICAgICAgICAgICAgICBmLnVubGluaygpCiAgICBleGNl
cHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKCgpAY29udGV4dGxpYi5jb250ZXh0bWFuYWdlcgpk
ZWYgX3N0YXRlX2xvY2soY29udl9pZCk6CiAgICAiIiJFeGNsdXNpdmUgcGVyLWNvbnZlcnNhdGlv
biBsb2NrIGZvciB0aGUgbG9hZC1tb2RpZnktc2F2ZSBjeWNsZS4KCiAgICBDdXJzb3Igc3Bhd25z
IGEgbmV3IHByb2Nlc3MgZm9yIGV2ZXJ5IGhvb2sgZXZlbnQsIHNvIHR3byBldmVudHMgZm9yIHRo
ZQogICAgc2FtZSBjb252ZXJzYXRpb24gY2FuIHJhY2UgdG8gcmVhZC1tb2RpZnktd3JpdGUgdGhl
IHNhbWUgc3RhdGUgZmlsZS4gIFRoZQogICAgbG9jayBpcyBoZWxkIG9ubHkgZm9yIHRoZSBpbi1t
ZW1vcnkgc3RhdGUgdXBkYXRlOyBpdCBpcyByZWxlYXNlZCBiZWZvcmUgdGhlCiAgICAoc2xvdykg
bmV0d29yayBleHBvcnQgc28gY29uY3VycmVudCBldmVudHMgYXJlIG5vdCBibG9ja2VkIGR1cmlu
ZyB0aGUgSFRUUAogICAgY2FsbCB0byBDb3JhbG9naXguCgogICAgSWYgbG9ja2luZyBpcyB1bmF2
YWlsYWJsZSAobm8gZmNudGwvbXN2Y3J0KSB0aGUgbm8tb3AgZmFsbGJhY2sgYWJvdmUgbWVhbnMK
ICAgIHdlIHNraXAgcHJvdGVjdGlvbiByYXRoZXIgdGhhbiBjcmFzaCDigJQgYWNjZXB0YWJsZSBi
ZWNhdXNlIHJhY2VzIGFyZSByYXJlIGFuZAogICAgdGhlIHdvcnN0IG91dGNvbWUgaXMgYSBsb3N0
IHRpbWluZyBzYW1wbGUsIG5vdCBkYXRhIGNvcnJ1cHRpb24uCiAgICAiIiIKICAgIF9TVEFURV9E
SVIubWtkaXIobW9kZT0wbzcwMCwgZXhpc3Rfb2s9VHJ1ZSkKICAgIGxvY2tfcGF0aCA9IF9TVEFU
RV9ESVIgLyAoX3N0YXRlX2ZpbGUoY29udl9pZCkuc3RlbSArICIubG9jayIpCiAgICB3aXRoIG9w
ZW4obG9ja19wYXRoLCAidyIpIGFzIGxmOgogICAgICAgIHRyeToKICAgICAgICAgICAgX2xvY2so
bGYpCiAgICAgICAgICAgIHlpZWxkCiAgICAgICAgZmluYWxseToKICAgICAgICAgICAgX3VubG9j
ayhsZikKCgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQojIENvbnZlcnNhdGlvbiBJRAojIC0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLQoKZGVmIGNvbnZlcnNhdGlvbl9pZChldmVudCk6CiAgICByZXR1cm4gKGV2ZW50
LmdldCgiY29udmVyc2F0aW9uX2lkIikgb3IgZXZlbnQuZ2V0KCJzZXNzaW9uX2lkIikgb3IgIiIp
LnN0cmlwKCkKCgpkZWYgc2Vzc2lvbl9pZChldmVudCk6CiAgICByZXR1cm4gKGV2ZW50LmdldCgi
c2Vzc2lvbl9pZCIpIG9yICIiKS5zdHJpcCgpCgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyBTdGF0
ZSB1cGRhdGUgKHRyYWNrcyBwZXItb3BlcmF0aW9uIHN0YXJ0IHRpbWVzIGZvciBlbGFwc2VkLW1z
IGZhbGxiYWNrKQojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQoKZGVmIHVwZGF0ZV9zdGF0ZShldmVudCwg
c3RhdGUpOgogICAgbm93ICA9IHRpbWUudGltZV9ucygpCiAgICBuYW1lID0gZXZlbnQuZ2V0KCJo
b29rX2V2ZW50X25hbWUiLCAiIikKCiAgICBpZiBuYW1lID09ICJwcmVUb29sVXNlIjoKICAgICAg
ICBzdGF0ZS5zZXRkZWZhdWx0KCJ0b29sX3N0YXJ0cyIsIHt9KVtldmVudC5nZXQoInRvb2xfbmFt
ZSIsICIiKV0gPSBub3cKICAgIGVsaWYgbmFtZSBpbiAoInBvc3RUb29sVXNlIiwgInBvc3RUb29s
VXNlRmFpbHVyZSIpOgogICAgICAgIHN0YXRlLmdldCgidG9vbF9zdGFydHMiLCB7fSkucG9wKGV2
ZW50LmdldCgidG9vbF9uYW1lIiwgIiIpLCBOb25lKQogICAgZWxpZiBuYW1lID09ICJiZWZvcmVT
aGVsbEV4ZWN1dGlvbiI6CiAgICAgICAgc3RhdGUuc2V0ZGVmYXVsdCgic2hlbGxfc3RhcnRzIiwg
e30pW2V2ZW50LmdldCgiY29tbWFuZCIsICIiKV0gPSBub3cKICAgIGVsaWYgbmFtZSA9PSAiYWZ0
ZXJTaGVsbEV4ZWN1dGlvbiI6CiAgICAgICAgc3RhdGUuZ2V0KCJzaGVsbF9zdGFydHMiLCB7fSku
cG9wKGV2ZW50LmdldCgiY29tbWFuZCIsICIiKSwgTm9uZSkKICAgIGVsaWYgbmFtZSA9PSAiYmVm
b3JlTUNQRXhlY3V0aW9uIjoKICAgICAgICBrZXkgPSBldmVudC5nZXQoInRvb2xfbmFtZSIpIG9y
ICJ7fTp7fSIuZm9ybWF0KGV2ZW50LmdldCgibWNwX3NlcnZlciIsICIiKSwgZXZlbnQuZ2V0KCJt
Y3BfdG9vbCIsICIiKSkKICAgICAgICBzdGF0ZS5zZXRkZWZhdWx0KCJtY3Bfc3RhcnRzIiwge30p
W2tleV0gPSBub3cKICAgIGVsaWYgbmFtZSA9PSAiYWZ0ZXJNQ1BFeGVjdXRpb24iOgogICAgICAg
IGtleSA9IGV2ZW50LmdldCgidG9vbF9uYW1lIikgb3IgInt9Ont9Ii5mb3JtYXQoZXZlbnQuZ2V0
KCJtY3Bfc2VydmVyIiwgIiIpLCBldmVudC5nZXQoIm1jcF90b29sIiwgIiIpKQogICAgICAgIHN0
YXRlLmdldCgibWNwX3N0YXJ0cyIsIHt9KS5wb3Aoa2V5LCBOb25lKQogICAgZWxpZiBuYW1lID09
ICJiZWZvcmVTdWJtaXRQcm9tcHQiOgogICAgICAgIHN0YXRlWyJwcm9tcHRfc3RhcnRfbnMiXSA9
IG5vdwogICAgZWxpZiBuYW1lID09ICJhZnRlckFnZW50UmVzcG9uc2UiOgogICAgICAgIHN0YXRl
LnBvcCgicHJvbXB0X3N0YXJ0X25zIiwgTm9uZSkKCgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyBC
dWlsZCBzcGFuIGF0dHJpYnV0ZXMKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCmRlZiBfdHJ1bmNhdGUo
cywgbWF4X2xlbik6CiAgICByZXR1cm4gc1s6bWF4X2xlbl0gaWYgcyBlbHNlIHMKCgpkZWYgX3Jh
d19zdHIodik6CiAgICBpZiBpc2luc3RhbmNlKHYsIHN0cik6CiAgICAgICAgcmV0dXJuIHYKICAg
IHJldHVybiBqc29uLmR1bXBzKHYpCgoKZGVmIF9lbGFwc2VkX21zKHN0YXJ0X25zKToKICAgIHJl
dHVybiAodGltZS50aW1lX25zKCkgLSBzdGFydF9ucykgLy8gMV8wMDBfMDAwCgoKZGVmIF9jb3Vu
dF9saW5lcyh0ZXh0KToKICAgIGlmIG5vdCB0ZXh0OgogICAgICAgIHJldHVybiAwCiAgICByZXR1
cm4gdGV4dC5jb3VudCgiXG4iKSArIDEKCgpkZWYgYnVpbGRfYXR0cmlidXRlcyhldmVudCwgc3Rh
dGUpOgogICAgYXR0cnMgPSB7fQoKICAgIGRlZiBhZGQoa2V5LCB2YWx1ZSk6CiAgICAgICAgaWYg
dmFsdWUgaXMgbm90IE5vbmUgYW5kIHZhbHVlICE9ICIiOgogICAgICAgICAgICBhdHRyc1trZXld
ID0gc3RyKHZhbHVlKQoKICAgIGRlZiBhZGRfaW50KGtleSwgdmFsdWUpOgogICAgICAgIGF0dHJz
W2tleV0gPSBpbnQodmFsdWUpCgogICAgbmFtZSA9IGV2ZW50LmdldCgiaG9va19ldmVudF9uYW1l
IiwgIiIpCgogICAgIyBDb3JlIGlkZW50aXR5CiAgICBhZGQoImN1cnNvci5jb252ZXJzYXRpb25f
aWQiLCBjb252ZXJzYXRpb25faWQoZXZlbnQpKQogICAgYWRkKCJjdXJzb3IuZ2VuZXJhdGlvbl9p
ZCIsICAgZXZlbnQuZ2V0KCJnZW5lcmF0aW9uX2lkIikpCiAgICBhZGQoImN1cnNvci51c2VyX2Vt
YWlsIiwgICAgICBldmVudC5nZXQoInVzZXJfZW1haWwiKSkKICAgIGFkZCgiY3Vyc29yLmN1cnNv
cl92ZXJzaW9uIiwgIGV2ZW50LmdldCgiY3Vyc29yX3ZlcnNpb24iKSkKCiAgICAjIEdlbkFJIHNl
bWFudGljIGNvbnZlbnRpb25zCiAgICBhZGQoImdlbl9haS5zeXN0ZW0iLCAgICAgICAgImN1cnNv
ciIpCiAgICBhZGQoImdlbl9haS5yZXF1ZXN0Lm1vZGVsIiwgZXZlbnQuZ2V0KCJtb2RlbCIpKQoK
ICAgIGlmIG5hbWUgPT0gImJlZm9yZVN1Ym1pdFByb21wdCI6CiAgICAgICAgYWRkKCJnZW5fYWku
b3BlcmF0aW9uLm5hbWUiLCAiY2hhdCIpCiAgICAgICAgcHJvbXB0ID0gZXZlbnQuZ2V0KCJwcm9t
cHQiLCAiIikKICAgICAgICBpZiBwcm9tcHQ6CiAgICAgICAgICAgIGFkZCgiY3Vyc29yLnByb21w
dCIsICJbTUFTS0VEXSIgaWYgTUFTS19QUk9NUFRTIGVsc2UgX3RydW5jYXRlKHByb21wdCwgNDAw
MCkpCiAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci5wcm9tcHRfbGVuZ3RoIiwgbGVuKHByb21w
dCkpCgogICAgZWxpZiBuYW1lIGluICgiYWZ0ZXJBZ2VudFJlc3BvbnNlIiwgImFmdGVyQWdlbnRU
aG91Z2h0Iik6CiAgICAgICAgYWRkKCJnZW5fYWkub3BlcmF0aW9uLm5hbWUiLCAiY2hhdCIpCiAg
ICAgICAgdGV4dCA9IGV2ZW50LmdldCgidGV4dCIsICIiKQogICAgICAgIGlmIHRleHQ6CiAgICAg
ICAgICAgIGFkZCgiY3Vyc29yLnRleHQiLCAiW01BU0tFRF0iIGlmIE1BU0tfUFJPTVBUUyBlbHNl
IF90cnVuY2F0ZSh0ZXh0LCA0MDAwKSkKICAgICAgICAgICAgYWRkX2ludCgiY3Vyc29yLnJlc3Bv
bnNlX2xpbmVzIiwgX2NvdW50X2xpbmVzKHRleHQpKQogICAgICAgIGlmIGV2ZW50LmdldCgiZHVy
YXRpb25fbXMiKSBpcyBub3QgTm9uZToKICAgICAgICAgICAgYWRkX2ludCgiY3Vyc29yLmR1cmF0
aW9uX21zIiwgZXZlbnRbImR1cmF0aW9uX21zIl0pCiAgICAgICAgaWYgbmFtZSA9PSAiYWZ0ZXJB
Z2VudFJlc3BvbnNlIiBhbmQgc3RhdGUgYW5kIHN0YXRlLmdldCgicHJvbXB0X3N0YXJ0X25zIik6
CiAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci50aGlua2luZ19tcyIsIF9lbGFwc2VkX21zKHN0
YXRlWyJwcm9tcHRfc3RhcnRfbnMiXSkpCgogICAgZWxpZiBuYW1lID09ICJwcmVUb29sVXNlIjoK
ICAgICAgICBhZGQoImdlbl9haS5vcGVyYXRpb24ubmFtZSIsICJ0b29sX2NhbGwiKQogICAgICAg
IGFkZCgiZ2VuX2FpLnRvb2wubmFtZSIsICAgICAgZXZlbnQuZ2V0KCJ0b29sX25hbWUiKSkKICAg
ICAgICBhZGQoImN1cnNvci50b29sX3VzZV9pZCIsICAgIGV2ZW50LmdldCgidG9vbF91c2VfaWQi
KSkKICAgICAgICBhZGQoImN1cnNvci5hZ2VudF9tZXNzYWdlIiwgIF90cnVuY2F0ZShldmVudC5n
ZXQoImFnZW50X21lc3NhZ2UiLCAiIiksIDEwMDApKQogICAgICAgIGlmIGV2ZW50LmdldCgidG9v
bF9pbnB1dCIpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBhZGQoImN1cnNvci50b29sX2lucHV0
IiwgX3RydW5jYXRlKF9yYXdfc3RyKGV2ZW50WyJ0b29sX2lucHV0Il0pLCAyMDAwKSkKCiAgICBl
bGlmIG5hbWUgPT0gInBvc3RUb29sVXNlIjoKICAgICAgICBhZGQoImdlbl9haS5vcGVyYXRpb24u
bmFtZSIsICJ0b29sX2NhbGwiKQogICAgICAgIGFkZCgiZ2VuX2FpLnRvb2wubmFtZSIsICAgZXZl
bnQuZ2V0KCJ0b29sX25hbWUiKSkKICAgICAgICBhZGQoImN1cnNvci50b29sX3VzZV9pZCIsIGV2
ZW50LmdldCgidG9vbF91c2VfaWQiKSkKICAgICAgICBpZiBldmVudC5nZXQoInRvb2xfaW5wdXQi
KSBpcyBub3QgTm9uZToKICAgICAgICAgICAgYWRkKCJjdXJzb3IudG9vbF9pbnB1dCIsIF90cnVu
Y2F0ZShfcmF3X3N0cihldmVudFsidG9vbF9pbnB1dCJdKSwgMjAwMCkpCiAgICAgICAgaWYgZXZl
bnQuZ2V0KCJ0b29sX291dHB1dCIpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBhZGQoImN1cnNv
ci50b29sX291dHB1dCIsIF90cnVuY2F0ZShfcmF3X3N0cihldmVudFsidG9vbF9vdXRwdXQiXSks
IDIwMDApKQogICAgICAgIGlmIGV2ZW50LmdldCgiZHVyYXRpb24iKSBpcyBub3QgTm9uZToKICAg
ICAgICAgICAgYWRkX2ludCgiY3Vyc29yLmR1cmF0aW9uX21zIiwgZXZlbnRbImR1cmF0aW9uIl0p
CiAgICAgICAgZWxpZiBzdGF0ZSBhbmQgZXZlbnQuZ2V0KCJ0b29sX25hbWUiKSBpbiBzdGF0ZS5n
ZXQoInRvb2xfc3RhcnRzIiwge30pOgogICAgICAgICAgICBhZGRfaW50KCJjdXJzb3IuZHVyYXRp
b25fbXMiLCBfZWxhcHNlZF9tcyhzdGF0ZVsidG9vbF9zdGFydHMiXVtldmVudFsidG9vbF9uYW1l
Il1dKSkKCiAgICBlbGlmIG5hbWUgPT0gInBvc3RUb29sVXNlRmFpbHVyZSI6CiAgICAgICAgYWRk
KCJnZW5fYWkub3BlcmF0aW9uLm5hbWUiLCAidG9vbF9jYWxsIikKICAgICAgICBhZGQoImdlbl9h
aS50b29sLm5hbWUiLCAgIGV2ZW50LmdldCgidG9vbF9uYW1lIikpCiAgICAgICAgYWRkKCJjdXJz
b3IudG9vbF91c2VfaWQiLCBldmVudC5nZXQoInRvb2xfdXNlX2lkIikpCiAgICAgICAgaWYgZXZl
bnQuZ2V0KCJ0b29sX2lucHV0IikgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGFkZCgiY3Vyc29y
LnRvb2xfaW5wdXQiLCBfdHJ1bmNhdGUoX3Jhd19zdHIoZXZlbnRbInRvb2xfaW5wdXQiXSksIDIw
MDApKQogICAgICAgIGFkZCgiY3Vyc29yLmVycm9yIiwgICAgICAgIF90cnVuY2F0ZShldmVudC5n
ZXQoImVycm9yX21lc3NhZ2UiLCAiIiksIDEwMDApKQogICAgICAgIGFkZCgiY3Vyc29yLmZhaWx1
cmVfdHlwZSIsIGV2ZW50LmdldCgiZmFpbHVyZV90eXBlIikpCiAgICAgICAgYWRkKCJlcnJvci50
eXBlIiwgICAgICAgICAgInRvb2xfZmFpbHVyZSIpCiAgICAgICAgaWYgZXZlbnQuZ2V0KCJpc19p
bnRlcnJ1cHQiKToKICAgICAgICAgICAgYWRkKCJjdXJzb3IuaXNfaW50ZXJydXB0IiwgInRydWUi
KQogICAgICAgIGlmIGV2ZW50LmdldCgiZHVyYXRpb24iKSBpcyBub3QgTm9uZToKICAgICAgICAg
ICAgYWRkX2ludCgiY3Vyc29yLmR1cmF0aW9uX21zIiwgZXZlbnRbImR1cmF0aW9uIl0pCiAgICAg
ICAgZWxpZiBzdGF0ZSBhbmQgZXZlbnQuZ2V0KCJ0b29sX25hbWUiKSBpbiBzdGF0ZS5nZXQoInRv
b2xfc3RhcnRzIiwge30pOgogICAgICAgICAgICBhZGRfaW50KCJjdXJzb3IuZHVyYXRpb25fbXMi
LCBfZWxhcHNlZF9tcyhzdGF0ZVsidG9vbF9zdGFydHMiXVtldmVudFsidG9vbF9uYW1lIl1dKSkK
CiAgICBlbGlmIG5hbWUgPT0gImJlZm9yZVNoZWxsRXhlY3V0aW9uIjoKICAgICAgICBhZGQoImdl
bl9haS5vcGVyYXRpb24ubmFtZSIsICJzaGVsbF9leGVjdXRpb24iKQogICAgICAgIGFkZCgiY3Vy
c29yLnNoZWxsX2NvbW1hbmQiLCAgZXZlbnQuZ2V0KCJjb21tYW5kIikpCiAgICAgICAgYWRkKCJj
dXJzb3IuY3dkIiwgICAgICAgICAgICBldmVudC5nZXQoImN3ZCIpKQogICAgICAgIGlmIGV2ZW50
LmdldCgic2FuZGJveCIpOgogICAgICAgICAgICBhZGQoImN1cnNvci5zYW5kYm94IiwgInRydWUi
KQoKICAgIGVsaWYgbmFtZSA9PSAiYWZ0ZXJTaGVsbEV4ZWN1dGlvbiI6CiAgICAgICAgYWRkKCJn
ZW5fYWkub3BlcmF0aW9uLm5hbWUiLCAic2hlbGxfZXhlY3V0aW9uIikKICAgICAgICBhZGQoImN1
cnNvci5zaGVsbF9jb21tYW5kIiwgIGV2ZW50LmdldCgiY29tbWFuZCIpKQogICAgICAgIGFkZCgi
Y3Vyc29yLmN3ZCIsICAgICAgICAgICAgZXZlbnQuZ2V0KCJjd2QiKSkKICAgICAgICBpZiBldmVu
dC5nZXQoImV4aXRfY29kZSIpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBhZGRfaW50KCJjdXJz
b3IuZXhpdF9jb2RlIiwgZXZlbnRbImV4aXRfY29kZSJdKQogICAgICAgICAgICBpZiBldmVudFsi
ZXhpdF9jb2RlIl0gIT0gMDoKICAgICAgICAgICAgICAgIGFkZCgiZXJyb3IudHlwZSIsICJzaGVs
bF9mYWlsdXJlIikKICAgICAgICBpZiBldmVudC5nZXQoInNhbmRib3giKToKICAgICAgICAgICAg
YWRkKCJjdXJzb3Iuc2FuZGJveCIsICJ0cnVlIikKICAgICAgICBpZiBldmVudC5nZXQoIm91dHB1
dCIpOgogICAgICAgICAgICBhZGQoImN1cnNvci5zaGVsbF9vdXRwdXQiLCBfdHJ1bmNhdGUoZXZl
bnRbIm91dHB1dCJdLCAyMDAwKSkKICAgICAgICBpZiBldmVudC5nZXQoImR1cmF0aW9uIikgaXMg
bm90IE5vbmU6CiAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci5kdXJhdGlvbl9tcyIsIGV2ZW50
WyJkdXJhdGlvbiJdKQogICAgICAgIGVsaWYgc3RhdGUgYW5kIGV2ZW50LmdldCgiY29tbWFuZCIp
IGluIHN0YXRlLmdldCgic2hlbGxfc3RhcnRzIiwge30pOgogICAgICAgICAgICBhZGRfaW50KCJj
dXJzb3IuZHVyYXRpb25fbXMiLCBfZWxhcHNlZF9tcyhzdGF0ZVsic2hlbGxfc3RhcnRzIl1bZXZl
bnRbImNvbW1hbmQiXV0pKQoKICAgIGVsaWYgbmFtZSA9PSAiYmVmb3JlTUNQRXhlY3V0aW9uIjoK
ICAgICAgICBhZGQoImdlbl9haS5vcGVyYXRpb24ubmFtZSIsICJtY3BfY2FsbCIpCiAgICAgICAg
YWRkKCJnZW5fYWkudG9vbC5uYW1lIiwgICAgICBldmVudC5nZXQoInRvb2xfbmFtZSIpKQogICAg
ICAgIGlmIGV2ZW50LmdldCgidG9vbF9pbnB1dCIpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBh
ZGQoImN1cnNvci50b29sX2lucHV0IiwgX3RydW5jYXRlKF9yYXdfc3RyKGV2ZW50WyJ0b29sX2lu
cHV0Il0pLCAyMDAwKSkKICAgICAgICBhZGQoInBlZXIuc2VydmljZSIsIGV2ZW50LmdldCgidXJs
Iikgb3IgZXZlbnQuZ2V0KCJtY3Bfc2VydmVyIiwgIiIpKQoKICAgIGVsaWYgbmFtZSA9PSAiYWZ0
ZXJNQ1BFeGVjdXRpb24iOgogICAgICAgIGFkZCgiZ2VuX2FpLm9wZXJhdGlvbi5uYW1lIiwgIm1j
cF9jYWxsIikKICAgICAgICBhZGQoImdlbl9haS50b29sLm5hbWUiLCAgICAgIGV2ZW50LmdldCgi
dG9vbF9uYW1lIikpCiAgICAgICAgaWYgZXZlbnQuZ2V0KCJ0b29sX2lucHV0IikgaXMgbm90IE5v
bmU6CiAgICAgICAgICAgIGFkZCgiY3Vyc29yLnRvb2xfaW5wdXQiLCBfdHJ1bmNhdGUoX3Jhd19z
dHIoZXZlbnRbInRvb2xfaW5wdXQiXSksIDIwMDApKQogICAgICAgIGlmIGV2ZW50LmdldCgicmVz
dWx0X2pzb24iKToKICAgICAgICAgICAgYWRkKCJjdXJzb3IucmVzdWx0X2pzb24iLCBfdHJ1bmNh
dGUoZXZlbnRbInJlc3VsdF9qc29uIl0sIDIwMDApKQogICAgICAgIGFkZCgicGVlci5zZXJ2aWNl
IiwgZXZlbnQuZ2V0KCJ1cmwiKSBvciBldmVudC5nZXQoIm1jcF9zZXJ2ZXIiLCAiIikpCiAgICAg
ICAgaWYgZXZlbnQuZ2V0KCJkdXJhdGlvbiIpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBhZGRf
aW50KCJjdXJzb3IuZHVyYXRpb25fbXMiLCBldmVudFsiZHVyYXRpb24iXSkKICAgICAgICBlbGlm
IHN0YXRlOgogICAgICAgICAgICBrZXkgPSBldmVudC5nZXQoInRvb2xfbmFtZSIpIG9yICJ7fTp7
fSIuZm9ybWF0KGV2ZW50LmdldCgibWNwX3NlcnZlciIsICIiKSwgZXZlbnQuZ2V0KCJtY3BfdG9v
bCIsICIiKSkKICAgICAgICAgICAgaWYga2V5IGluIHN0YXRlLmdldCgibWNwX3N0YXJ0cyIsIHt9
KToKICAgICAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci5kdXJhdGlvbl9tcyIsIF9lbGFwc2Vk
X21zKHN0YXRlWyJtY3Bfc3RhcnRzIl1ba2V5XSkpCgogICAgZWxpZiBuYW1lID09ICJiZWZvcmVS
ZWFkRmlsZSI6CiAgICAgICAgYWRkKCJjdXJzb3IuZmlsZV9wYXRoIiwgZXZlbnQuZ2V0KCJmaWxl
X3BhdGgiKSkKCiAgICBlbGlmIG5hbWUgPT0gImFmdGVyRmlsZUVkaXQiOgogICAgICAgIGFkZCgi
Y3Vyc29yLmZpbGVfcGF0aCIsIGV2ZW50LmdldCgiZmlsZV9wYXRoIikpCiAgICAgICAgZWRpdHMg
PSBldmVudC5nZXQoImVkaXRzIikgb3IgW10KICAgICAgICBpZiBlZGl0czoKICAgICAgICAgICAg
YWRkX2ludCgiY3Vyc29yLmVkaXRfY291bnQiLCBsZW4oZWRpdHMpKQogICAgICAgICAgICBsaW5l
c19hZGRlZCAgID0gc3VtKF9jb3VudF9saW5lcyhlLmdldCgibmV3X3N0cmluZyIsICIiKSkgZm9y
IGUgaW4gZWRpdHMpCiAgICAgICAgICAgIGxpbmVzX2RlbGV0ZWQgPSBzdW0oX2NvdW50X2xpbmVz
KGUuZ2V0KCJvbGRfc3RyaW5nIiwgIiIpKSBmb3IgZSBpbiBlZGl0cykKICAgICAgICAgICAgYWRk
X2ludCgiY3Vyc29yLmxpbmVzX2FkZGVkIiwgICBsaW5lc19hZGRlZCkKICAgICAgICAgICAgYWRk
X2ludCgiY3Vyc29yLmxpbmVzX2RlbGV0ZWQiLCBsaW5lc19kZWxldGVkKQogICAgICAgICAgICBh
ZGRfaW50KCJjdXJzb3IubGluZXNfbmV0IiwgICAgIGxpbmVzX2FkZGVkIC0gbGluZXNfZGVsZXRl
ZCkKCiAgICBlbGlmIG5hbWUgPT0gInN1YmFnZW50U3RhcnQiOgogICAgICAgIGFkZCgiZ2VuX2Fp
Lm9wZXJhdGlvbi5uYW1lIiwgICAgICAgICAic3ViYWdlbnRfc3RhcnQiKQogICAgICAgIGFkZCgi
Y3Vyc29yLnN1YmFnZW50X2lkIiwgICAgICAgICAgICBldmVudC5nZXQoInN1YmFnZW50X2lkIikp
CiAgICAgICAgYWRkKCJjdXJzb3Iuc3ViYWdlbnRfdHlwZSIsICAgICAgICAgIGV2ZW50LmdldCgi
c3ViYWdlbnRfdHlwZSIpKQogICAgICAgIGFkZCgiY3Vyc29yLnRhc2siLCAgICAgICAgICAgICAg
ICAgICBfdHJ1bmNhdGUoZXZlbnQuZ2V0KCJ0YXNrIiwgIiIpLCAyMDAwKSkKICAgICAgICBhZGQo
ImN1cnNvci5wYXJlbnRfY29udmVyc2F0aW9uX2lkIiwgZXZlbnQuZ2V0KCJwYXJlbnRfY29udmVy
c2F0aW9uX2lkIikpCiAgICAgICAgYWRkKCJjdXJzb3Iuc3ViYWdlbnRfbW9kZWwiLCAgICAgICAg
IGV2ZW50LmdldCgic3ViYWdlbnRfbW9kZWwiKSkKICAgICAgICBhZGQoImN1cnNvci5naXRfYnJh
bmNoIiwgICAgICAgICAgICAgZXZlbnQuZ2V0KCJnaXRfYnJhbmNoIikpCiAgICAgICAgaWYgZXZl
bnQuZ2V0KCJpc19wYXJhbGxlbF93b3JrZXIiKToKICAgICAgICAgICAgYWRkKCJjdXJzb3IuaXNf
cGFyYWxsZWxfd29ya2VyIiwgInRydWUiKQoKICAgIGVsaWYgbmFtZSA9PSAic3ViYWdlbnRTdG9w
IjoKICAgICAgICBhZGQoImdlbl9haS5vcGVyYXRpb24ubmFtZSIsICJzdWJhZ2VudF9zdG9wIikK
ICAgICAgICBhZGQoImN1cnNvci5zdWJhZ2VudF90eXBlIiwgIGV2ZW50LmdldCgic3ViYWdlbnRf
dHlwZSIpKQogICAgICAgIGFkZCgiY3Vyc29yLnN0YXR1cyIsICAgICAgICAgZXZlbnQuZ2V0KCJz
dGF0dXMiKSkKICAgICAgICBhZGQoImN1cnNvci50YXNrIiwgICAgICAgICAgIF90cnVuY2F0ZShl
dmVudC5nZXQoInRhc2siLCAiIiksIDIwMDApKQogICAgICAgIGFkZCgiY3Vyc29yLmRlc2NyaXB0
aW9uIiwgICAgX3RydW5jYXRlKGV2ZW50LmdldCgiZGVzY3JpcHRpb24iLCAiIiksIDEwMDApKQog
ICAgICAgIGFkZCgiY3Vyc29yLnN1bW1hcnkiLCAgICAgICAgX3RydW5jYXRlKGV2ZW50LmdldCgi
c3VtbWFyeSIsICIiKSwgMjAwMCkpCiAgICAgICAgaWYgZXZlbnQuZ2V0KCJkdXJhdGlvbl9tcyIp
IGlzIG5vdCBOb25lOgogICAgICAgICAgICBhZGRfaW50KCJjdXJzb3IuZHVyYXRpb25fbXMiLCBl
dmVudFsiZHVyYXRpb25fbXMiXSkKICAgICAgICBpZiBldmVudC5nZXQoIm1lc3NhZ2VfY291bnQi
KSBpcyBub3QgTm9uZToKICAgICAgICAgICAgYWRkX2ludCgiY3Vyc29yLm1lc3NhZ2VfY291bnQi
LCBldmVudFsibWVzc2FnZV9jb3VudCJdKQogICAgICAgIGlmIGV2ZW50LmdldCgidG9vbF9jYWxs
X2NvdW50IikgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci50b29sX2Nh
bGxfY291bnQiLCBldmVudFsidG9vbF9jYWxsX2NvdW50Il0pCiAgICAgICAgaWYgZXZlbnQuZ2V0
KCJsb29wX2NvdW50IikgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci5s
b29wX2NvdW50IiwgZXZlbnRbImxvb3BfY291bnQiXSkKICAgICAgICBpZiBldmVudC5nZXQoIm1v
ZGlmaWVkX2ZpbGVzIik6CiAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci5tb2RpZmllZF9maWxl
X2NvdW50IiwgbGVuKGV2ZW50WyJtb2RpZmllZF9maWxlcyJdKSkKICAgICAgICBpZiBldmVudC5n
ZXQoInN0YXR1cyIpID09ICJlcnJvciI6CiAgICAgICAgICAgIGFkZCgiZXJyb3IudHlwZSIsICJz
dWJhZ2VudF9lcnJvciIpCgogICAgZWxpZiBuYW1lID09ICJzZXNzaW9uU3RhcnQiOgogICAgICAg
IGFkZCgiZ2VuX2FpLm9wZXJhdGlvbi5uYW1lIiwgInNlc3Npb25fc3RhcnQiKQogICAgICAgIGFk
ZCgiY3Vyc29yLnNlc3Npb25faWQiLCAgICAgZXZlbnQuZ2V0KCJzZXNzaW9uX2lkIikpCiAgICAg
ICAgYWRkKCJjdXJzb3IuY29tcG9zZXJfbW9kZSIsICBldmVudC5nZXQoImNvbXBvc2VyX21vZGUi
KSkKICAgICAgICBpZiBldmVudC5nZXQoImlzX2JhY2tncm91bmRfYWdlbnQiKToKICAgICAgICAg
ICAgYWRkKCJjdXJzb3IuaXNfYmFja2dyb3VuZF9hZ2VudCIsICJ0cnVlIikKCiAgICBlbGlmIG5h
bWUgPT0gInNlc3Npb25FbmQiOgogICAgICAgIGFkZCgiZ2VuX2FpLm9wZXJhdGlvbi5uYW1lIiwg
InNlc3Npb25fZW5kIikKICAgICAgICBhZGQoImN1cnNvci5zZXNzaW9uX2lkIiwgICAgIGV2ZW50
LmdldCgic2Vzc2lvbl9pZCIpKQogICAgICAgIGFkZCgiY3Vyc29yLnJlYXNvbiIsICAgICAgICAg
ZXZlbnQuZ2V0KCJyZWFzb24iKSkKICAgICAgICBhZGQoImN1cnNvci5maW5hbF9zdGF0dXMiLCAg
IGV2ZW50LmdldCgiZmluYWxfc3RhdHVzIikpCiAgICAgICAgaWYgZXZlbnQuZ2V0KCJpc19iYWNr
Z3JvdW5kX2FnZW50Iik6CiAgICAgICAgICAgIGFkZCgiY3Vyc29yLmlzX2JhY2tncm91bmRfYWdl
bnQiLCAidHJ1ZSIpCiAgICAgICAgaWYgZXZlbnQuZ2V0KCJkdXJhdGlvbl9tcyIpIGlzIG5vdCBO
b25lOgogICAgICAgICAgICBhZGRfaW50KCJjdXJzb3IuZHVyYXRpb25fbXMiLCBldmVudFsiZHVy
YXRpb25fbXMiXSkKICAgICAgICBpZiBldmVudC5nZXQoImVycm9yX21lc3NhZ2UiKToKICAgICAg
ICAgICAgYWRkKCJjdXJzb3IuZXJyb3IiLCBfdHJ1bmNhdGUoZXZlbnRbImVycm9yX21lc3NhZ2Ui
XSwgMTAwMCkpCiAgICAgICAgICAgIGFkZCgiZXJyb3IudHlwZSIsICAgInNlc3Npb25fZXJyb3Ii
KQoKICAgIGVsaWYgbmFtZSA9PSAicHJlQ29tcGFjdCI6CiAgICAgICAgYWRkKCJnZW5fYWkub3Bl
cmF0aW9uLm5hbWUiLCAgImNvbXBhY3QiKQogICAgICAgIGFkZCgiY3Vyc29yLmNvbXBhY3RfdHJp
Z2dlciIsIGV2ZW50LmdldCgidHJpZ2dlciIpKQogICAgICAgIGlmIGV2ZW50LmdldCgiY29udGV4
dF90b2tlbnMiKSBpcyBub3QgTm9uZToKICAgICAgICAgICAgYWRkX2ludCgiY3Vyc29yLmNvbnRl
eHRfdG9rZW5zIiwgICAgIGV2ZW50WyJjb250ZXh0X3Rva2VucyJdKQogICAgICAgICAgICBhZGRf
aW50KCJnZW5fYWkudXNhZ2UuaW5wdXRfdG9rZW5zIiwgZXZlbnRbImNvbnRleHRfdG9rZW5zIl0p
CiAgICAgICAgaWYgZXZlbnQuZ2V0KCJjb250ZXh0X3dpbmRvd19zaXplIikgaXMgbm90IE5vbmU6
CiAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci5jb250ZXh0X3dpbmRvd19zaXplIiwgZXZlbnRb
ImNvbnRleHRfd2luZG93X3NpemUiXSkKICAgICAgICBpZiBldmVudC5nZXQoImNvbnRleHRfdXNh
Z2VfcGVyY2VudCIpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBhZGRfaW50KCJjdXJzb3IuY29u
dGV4dF91c2FnZV9wY3QiLCBpbnQoZXZlbnRbImNvbnRleHRfdXNhZ2VfcGVyY2VudCJdKSkKICAg
ICAgICBpZiBldmVudC5nZXQoIm1lc3NhZ2VfY291bnQiKSBpcyBub3QgTm9uZToKICAgICAgICAg
ICAgYWRkX2ludCgiY3Vyc29yLm1lc3NhZ2VfY291bnQiLCBldmVudFsibWVzc2FnZV9jb3VudCJd
KQogICAgICAgIGlmIGV2ZW50LmdldCgibWVzc2FnZXNfdG9fY29tcGFjdCIpIGlzIG5vdCBOb25l
OgogICAgICAgICAgICBhZGRfaW50KCJjdXJzb3IubWVzc2FnZXNfdG9fY29tcGFjdCIsIGV2ZW50
WyJtZXNzYWdlc190b19jb21wYWN0Il0pCiAgICAgICAgaWYgZXZlbnQuZ2V0KCJpc19maXJzdF9j
b21wYWN0aW9uIik6CiAgICAgICAgICAgIGFkZCgiY3Vyc29yLmlzX2ZpcnN0X2NvbXBhY3Rpb24i
LCAidHJ1ZSIpCgogICAgZWxpZiBuYW1lID09ICJzdG9wIjoKICAgICAgICBhZGQoImdlbl9haS5v
cGVyYXRpb24ubmFtZSIsICJzdG9wIikKICAgICAgICBhZGQoImN1cnNvci5zdGF0dXMiLCAgICAg
ICAgIGV2ZW50LmdldCgic3RhdHVzIikpCiAgICAgICAgaWYgZXZlbnQuZ2V0KCJsb29wX2NvdW50
IikgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGFkZF9pbnQoImN1cnNvci5sb29wX2NvdW50Iiwg
ZXZlbnRbImxvb3BfY291bnQiXSkKICAgICAgICAgICAgaWYgZXZlbnRbImxvb3BfY291bnQiXSA+
IDIwOgogICAgICAgICAgICAgICAgYWRkKCJjdXJzb3IuYWdlbnRfcnVuYXdheSIsICJ0cnVlIikK
ICAgICAgICBpZiBzdGF0ZSBhbmQgc3RhdGUuZ2V0KCJzdGFydF90aW1lX25zIik6CiAgICAgICAg
ICAgIGFkZF9pbnQoImN1cnNvci5zZXNzaW9uX2R1cmF0aW9uX21zIiwgX2VsYXBzZWRfbXMoc3Rh
dGVbInN0YXJ0X3RpbWVfbnMiXSkpCgogICAgcmV0dXJuIGF0dHJzCgoKIyAtLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0KIyBFeHBvcnQgdmlhIE9UZWwgU0RLCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgpkZWYgZW1p
dF9zcGFuKGV2ZW50LCBzdGF0ZSk6CiAgICAiIiJCdWlsZCBhbmQgc3luY2hyb25vdXNseSBleHBv
cnQgYSBzaW5nbGUgc3Bhbi4gUmV0dXJucyB0aGUgU3BhbkNvbnRleHQuCgogICAgTmV2ZXIgcmFp
c2VzIOKAlCBleHBvcnQgZXJyb3JzIGFyZSBsb2dnZWQgKERFQlVHKSBvciBzaWxlbnRseSBkcm9w
cGVkIHNvIHRoYXQKICAgIGEgQ29yYWxvZ2l4IG91dGFnZSBjYW5ub3QgYnJlYWsgQ3Vyc29yJ3Mg
bm9ybWFsIHdvcmtmbG93LgogICAgIiIiCiAgICBpZiBub3QgQ1hfQVBJX0tFWSBvciBub3QgQ1hf
T1RMUF9FTkRQT0lOVDoKICAgICAgICByZXR1cm4gTm9uZQoKICAgIGhvb2tfbmFtZSA9IGV2ZW50
LmdldCgiaG9va19ldmVudF9uYW1lIiwgIiIpCgogICAgdHJ5OgogICAgICAgIHJldHVybiBfZW1p
dF9zcGFuX2lubmVyKGV2ZW50LCBob29rX25hbWUsIHN0YXRlKQogICAgZXhjZXB0IEV4Y2VwdGlv
biBhcyBleGM6CiAgICAgICAgaWYgREVCVUc6CiAgICAgICAgICAgIHByaW50KCJjdXJzb3ItY29y
YWxvZ2l4LWhvb2s6IGV4cG9ydCBlcnJvcjoge30iLmZvcm1hdChleGMpLCBmaWxlPXN5cy5zdGRl
cnIpCiAgICAgICAgcmV0dXJuIE5vbmUKCgpkZWYgX2VtaXRfc3Bhbl9pbm5lcihldmVudCwgaG9v
a19uYW1lLCBzdGF0ZSk6CiAgICByZXNvdXJjZSA9IFJlc291cmNlLmNyZWF0ZSh7CiAgICAgICAg
InNlcnZpY2UubmFtZSI6ICAgICAgICJjdXJzb3ItYWdlbnQiLAogICAgICAgICJzZXJ2aWNlLnZl
cnNpb24iOiAgICBfU0VSVklDRV9WRVJTSU9OLAogICAgICAgICJ0ZWxlbWV0cnkuc2RrLm5hbWUi
OiAiY3Vyc29yLWNvcmFsb2dpeC1ob29rIiwKICAgIH0pCgogICAgZXhwb3J0ZXIgPSBPVExQU3Bh
bkV4cG9ydGVyKAogICAgICAgIGVuZHBvaW50PUNYX09UTFBfRU5EUE9JTlQgKyAiL3YxL3RyYWNl
cyIsCiAgICAgICAgaGVhZGVycz17CiAgICAgICAgICAgICJBdXRob3JpemF0aW9uIjogICAgICAg
IkJlYXJlciAiICsgQ1hfQVBJX0tFWSwKICAgICAgICAgICAgIkNYLUFwcGxpY2F0aW9uLU5hbWUi
OiBDWF9BUFBMSUNBVElPTl9OQU1FLAogICAgICAgICAgICAiQ1gtU3Vic3lzdGVtLU5hbWUiOiAg
IENYX1NVQlNZU1RFTV9OQU1FLAogICAgICAgIH0sCiAgICApCgogICAgcHJvdmlkZXIgPSBUcmFj
ZXJQcm92aWRlcihyZXNvdXJjZT1yZXNvdXJjZSkKICAgIHByb3ZpZGVyLmFkZF9zcGFuX3Byb2Nl
c3NvcihTaW1wbGVTcGFuUHJvY2Vzc29yKGV4cG9ydGVyKSkKICAgIHRyYWNlciA9IHByb3ZpZGVy
LmdldF90cmFjZXIoImN1cnNvci1jb3JhbG9naXgiLCBfU0VSVklDRV9WRVJTSU9OKQoKICAgICMg
Rm9yIGV4aXN0aW5nIGNvbnZlcnNhdGlvbnMsIGluamVjdCB0aGUgcm9vdCBzcGFuIGFzIHBhcmVu
dCBzbyBhbGwgc3BhbnMKICAgICMgc2hhcmUgdGhlIHNhbWUgdHJhY2UgYW5kIGhhbmcgb2ZmIHRo
ZSBmaXJzdCBzcGFuLgogICAgY3R4ID0gTm9uZQogICAgaWYgc3RhdGUgYW5kIHN0YXRlLmdldCgi
dHJhY2VfaWQiKSBhbmQgc3RhdGUuZ2V0KCJyb290X3NwYW5faWQiKToKICAgICAgICBwYXJlbnRf
Y3R4ID0gU3BhbkNvbnRleHQoCiAgICAgICAgICAgIHRyYWNlX2lkPWludChzdGF0ZVsidHJhY2Vf
aWQiXSwgMTYpLAogICAgICAgICAgICBzcGFuX2lkPWludChzdGF0ZVsicm9vdF9zcGFuX2lkIl0s
IDE2KSwKICAgICAgICAgICAgaXNfcmVtb3RlPVRydWUsCiAgICAgICAgICAgIHRyYWNlX2ZsYWdz
PVRyYWNlRmxhZ3MoMHgwMSksCiAgICAgICAgKQogICAgICAgIGN0eCA9IHRyYWNlLnNldF9zcGFu
X2luX2NvbnRleHQoTm9uUmVjb3JkaW5nU3BhbihwYXJlbnRfY3R4KSkKCiAgICBhdHRycyAgICA9
IGJ1aWxkX2F0dHJpYnV0ZXMoZXZlbnQsIHN0YXRlKQogICAgaXNfZXJyb3IgPSAiZXJyb3IudHlw
ZSIgaW4gYXR0cnMKCiAgICBzcGFuID0gdHJhY2VyLnN0YXJ0X3NwYW4oImN1cnNvci4iICsgaG9v
a19uYW1lLCBjb250ZXh0PWN0eCwga2luZD10cmFjZS5TcGFuS2luZC5TRVJWRVIpCiAgICB0cnk6
CiAgICAgICAgc3Bhbi5zZXRfYXR0cmlidXRlcyhhdHRycykKICAgICAgICBpZiBpc19lcnJvcjoK
ICAgICAgICAgICAgc3Bhbi5zZXRfc3RhdHVzKFN0YXR1cyhTdGF0dXNDb2RlLkVSUk9SKSkKICAg
IGZpbmFsbHk6CiAgICAgICAgc3Bhbi5lbmQoKSAgIyBTaW1wbGVTcGFuUHJvY2Vzc29yIGV4cG9y
dHMgc3luY2hyb25vdXNseSBoZXJlCgogICAgc2MgPSBzcGFuLmdldF9zcGFuX2NvbnRleHQoKQog
ICAgaWYgREVCVUc6CiAgICAgICAgcHJpbnQoCiAgICAgICAgICAgICJjdXJzb3ItY29yYWxvZ2l4
LWhvb2s6IGV4cG9ydGVkIHNwYW4gZXZlbnQ9e30gdHJhY2VfaWQ9e30gc3Bhbl9pZD17fSIuZm9y
bWF0KAogICAgICAgICAgICAgICAgaG9va19uYW1lLAogICAgICAgICAgICAgICAgZm9ybWF0KHNj
LnRyYWNlX2lkLCAiMDMyeCIpLAogICAgICAgICAgICAgICAgZm9ybWF0KHNjLnNwYW5faWQsICIw
MTZ4IiksCiAgICAgICAgICAgICksCiAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVyciwKICAgICAg
ICApCgogICAgcmV0dXJuIHNjCgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyBNYWluCiMgLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tCgpkZWYgbWFpbigpOgogICAgcmF3ID0gc3lzLnN0ZGluLmJ1ZmZlci5yZWFk
KCkuc3RyaXAoKQogICAgaWYgbm90IHJhdzoKICAgICAgICBwcmludCgie30iKQogICAgICAgIHJl
dHVybgoKICAgIHRyeToKICAgICAgICBldmVudCA9IGpzb24ubG9hZHMocmF3KQogICAgZXhjZXB0
IGpzb24uSlNPTkRlY29kZUVycm9yOgogICAgICAgIHByaW50KCJ7fSIpCiAgICAgICAgcmV0dXJu
CgogICAgaWYgREVCVUc6CiAgICAgICAgcHJpbnQoCiAgICAgICAgICAgICJjdXJzb3ItY29yYWxv
Z2l4LWhvb2s6IFJBVyBFVkVOVFxue30iLmZvcm1hdCgKICAgICAgICAgICAgICAgIGpzb24uZHVt
cHMoZXZlbnQsIGluZGVudD0yLCBkZWZhdWx0PXN0cikKICAgICAgICAgICAgKSwKICAgICAgICAg
ICAgZmlsZT1zeXMuc3RkZXJyLAogICAgICAgICkKCiAgICBjb252X2lkICAgICAgICAgPSBjb252
ZXJzYXRpb25faWQoZXZlbnQpCiAgICBob29rX25hbWUgICAgICAgPSBldmVudC5nZXQoImhvb2tf
ZXZlbnRfbmFtZSIsICIiKQogICAgc3RhdGUgICAgICAgICAgID0gTm9uZQogICAgc2F2ZV9hZnRl
cl9lbWl0ID0gRmFsc2UgICMgVHJ1ZSBmb3IgdGhlIGZpcnN0IGV2ZW50IG9mIGEgbmV3IGNvbnZl
cnNhdGlvbgoKICAgIGlmIGNvbnZfaWQ6CiAgICAgICAgc2Vzc19pZCA9IHNlc3Npb25faWQoZXZl
bnQpCiAgICAgICAgd2l0aCBfc3RhdGVfbG9jayhjb252X2lkKToKICAgICAgICAgICAgc3RhdGUg
PSBsb2FkX3N0YXRlKGNvbnZfaWQpCiAgICAgICAgICAgIGlmIHN0YXRlIGlzIE5vbmU6CiAgICAg
ICAgICAgICAgICAjIE5ldyBjb252ZXJzYXRpb24g4oCUIGlmIGEgc2Vzc2lvblN0YXJ0IGFscmVh
ZHkgcmFuIHVuZGVyIHNlc3Npb25faWQsCiAgICAgICAgICAgICAgICAjIGFkb3B0IGl0cyB0cmFj
ZSBjb250ZXh0IHNvIHNlc3Npb25TdGFydCBiZWNvbWVzIHRoZSByb290IHNwYW4uCiAgICAgICAg
ICAgICAgICBpbmhlcml0ZWQgPSB7fQogICAgICAgICAgICAgICAgaWYgc2Vzc19pZCBhbmQgc2Vz
c19pZCAhPSBjb252X2lkOgogICAgICAgICAgICAgICAgICAgIHNlc3Npb25fc3RhdGUgPSBsb2Fk
X3N0YXRlKHNlc3NfaWQpCiAgICAgICAgICAgICAgICAgICAgaWYgc2Vzc2lvbl9zdGF0ZSBhbmQg
c2Vzc2lvbl9zdGF0ZS5nZXQoInRyYWNlX2lkIik6CiAgICAgICAgICAgICAgICAgICAgICAgIGlu
aGVyaXRlZCA9IHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgICJ0cmFjZV9pZCI6ICAgICBz
ZXNzaW9uX3N0YXRlWyJ0cmFjZV9pZCJdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgInJv
b3Rfc3Bhbl9pZCI6IHNlc3Npb25fc3RhdGVbInJvb3Rfc3Bhbl9pZCJdLAogICAgICAgICAgICAg
ICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBzdGF0ZSA9IHsic3RhcnRfdGltZV9ucyI6IHRp
bWUudGltZV9ucygpLCAqKmluaGVyaXRlZH0KICAgICAgICAgICAgICAgIHNhdmVfYWZ0ZXJfZW1p
dCA9IG5vdCBpbmhlcml0ZWQgYW5kIGhvb2tfbmFtZSAhPSAic3RvcCIKICAgICAgICAgICAgdXBk
YXRlX3N0YXRlKGV2ZW50LCBzdGF0ZSkKICAgICAgICAgICAgaWYgbm90IHNhdmVfYWZ0ZXJfZW1p
dDoKICAgICAgICAgICAgICAgIGlmIGhvb2tfbmFtZSA9PSAic2Vzc2lvbkVuZCI6CiAgICAgICAg
ICAgICAgICAgICAgZGVsZXRlX3N0YXRlKGNvbnZfaWQpCiAgICAgICAgICAgICAgICBlbHNlOgog
ICAgICAgICAgICAgICAgICAgIHNhdmVfc3RhdGUoY29udl9pZCwgc3RhdGUpCgogICAgaWYgaG9v
a19uYW1lIGluICgic3RvcCIsICJzZXNzaW9uRW5kIik6CiAgICAgICAgcHJ1bmVfb2xkX3N0YXRl
cygpCgogICAgaWYgbm90IChPTUlUX1BSRV9UT09MX1VTRSBhbmQgaG9va19uYW1lID09ICJwcmVU
b29sVXNlIik6CiAgICAgICAgc2MgPSBlbWl0X3NwYW4oZXZlbnQsIHN0YXRlKQoKICAgICAgICBp
ZiBzYXZlX2FmdGVyX2VtaXQgYW5kIGNvbnZfaWQ6CiAgICAgICAgICAgIHN0YXRlWyJ0cmFjZV9p
ZCJdICAgICA9IGZvcm1hdChzYy50cmFjZV9pZCwgIjAzMngiKSBpZiBzYyBlbHNlICIiCiAgICAg
ICAgICAgIHN0YXRlWyJyb290X3NwYW5faWQiXSA9IGZvcm1hdChzYy5zcGFuX2lkLCAiMDE2eCIp
IGlmIHNjIGVsc2UgIiIKICAgICAgICAgICAgd2l0aCBfc3RhdGVfbG9jayhjb252X2lkKToKICAg
ICAgICAgICAgICAgIHNhdmVfc3RhdGUoY29udl9pZCwgc3RhdGUpCiAgICBlbGlmIHNhdmVfYWZ0
ZXJfZW1pdCBhbmQgY29udl9pZDoKICAgICAgICAjIEZpcnN0IGV2ZW50IHdhcyBza2lwcGVkIChP
TUlUX1BSRV9UT09MX1VTRSk7IHNhdmUgc3RhdGUgd2l0aG91dCB0cmFjZV9pZC4KICAgICAgICB3
aXRoIF9zdGF0ZV9sb2NrKGNvbnZfaWQpOgogICAgICAgICAgICBzYXZlX3N0YXRlKGNvbnZfaWQs
IHN0YXRlKQoKICAgIHByaW50KCJ7fSIpCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAg
IG1haW4oKQo=
CX_HOOK_B64_EOF
}

has_embedded_hook() { [[ -n "$(embedded_hook_b64 | tr -d '[:space:]')" ]]; }

decode_embedded_hook() {
  embedded_hook_b64 | python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode("".join(sys.stdin.read().split())))'
}

# Write hook.py to $1, preferring (1) --hook-source, (2) an on-disk copy next to
# this script (live repo checkout), (3) the embedded copy (standalone / MDM).
write_hook_py() {
  local dest="$1"
  if [[ -n "$HOOK_SOURCE" ]]; then
    cp "$HOOK_SOURCE" "$dest"
  elif [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/extension/resources/hook.py" ]]; then
    cp "$SCRIPT_DIR/extension/resources/hook.py" "$dest"
  elif has_embedded_hook; then
    decode_embedded_hook > "$dest"
  else
    echo "Error: no hook.py available (no --hook-source, no on-disk copy, no embedded copy)." >&2
    echo "If you are hacking on the script, run ./build-installer.sh to embed hook.py." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if $UNINSTALL; then
  echo "Removing Coralogix hook for $TARGET_USER..."

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

  if $IS_ROOT_FOR_OTHER; then
    [ -f "$HOOKS_JSON" ] && chown "$TARGET_USER" "$HOOKS_JSON" || true
  fi

  echo "Done. Restart Cursor to deactivate telemetry."
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

if [[ -z "$API_KEY" ]]; then
  echo "Error: no Coralogix API key set." >&2
  echo "Fill in CFG_API_KEY at the top of this script, or pass --api-key / CX_API_KEY." >&2
  exit 1
fi

# Canonicalize an explicit --hook-source path (if given).
if [[ -n "$HOOK_SOURCE" ]]; then
  HOOK_SOURCE="$(cd "$(dirname "$HOOK_SOURCE")" && pwd)/$(basename "$HOOK_SOURCE")"
  if [[ ! -f "$HOOK_SOURCE" ]]; then
    echo "Error: hook.py not found at $HOOK_SOURCE" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

echo "Installing Coralogix hook for Cursor (user: $TARGET_USER, home: $TARGET_HOME)..."

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

# 3. Write hook.py
write_hook_py "$INSTALLED_PY"
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

# 6. Install Python dependencies (as the target user, into their --user site)
echo "Installing Python dependencies for $TARGET_USER..."
PACKAGES=(opentelemetry-sdk opentelemetry-exporter-otlp-proto-http)
if ! run_as_user env HOME="$TARGET_HOME" python3 -m pip install --quiet --user "${PACKAGES[@]}" 2>/dev/null; then
  run_as_user env HOME="$TARGET_HOME" python3 -m pip install --quiet --user --break-system-packages "${PACKAGES[@]}"
fi
echo "Python dependencies installed."

# 7. Hand ownership of everything we created back to the target user
if $IS_ROOT_FOR_OTHER; then
  chown "$TARGET_USER" "$TARGET_HOME/.cursor" 2>/dev/null || true
  chown -R "$TARGET_USER" "$HOOKS_DIR"
  chown "$TARGET_USER" "$HOOKS_JSON"
fi

echo ""
echo "Done. Restart Cursor to activate telemetry."
echo "  User        : $TARGET_USER"
echo "  Application : $APPLICATION"
echo "  Subsystem   : $SUBSYSTEM"
echo "  Endpoint    : $ENDPOINT"
