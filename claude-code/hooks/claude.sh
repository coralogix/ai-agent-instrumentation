#!/bin/sh
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

# Claude Code PostToolUse hook that tracks repository names per session (macOS).
#
# Emits an OTLP/JSON gauge metric claude_code_session_repo_info with labels
# {session_id, repository_name, user_email} on each tool use.
#
# ZERO runtime assumptions: uses only tools that ship with macOS itself —
# /bin/sh, plutil (JSON parsing), curl (HTTPS), awk, uname, mktemp. No node, no
# python, no binaries to sign. git is optional: repo detection degrades to
# "unknown" without it, and every git call is bounded to 5s so a stale mount
# can never hang the session.
#
# Config is read from the same Claude Code settings files that hold the
# telemetry env block (Claude Code does not reliably pass its `env` block to
# hook subprocesses — see claude-code#20112):
#   OTEL_EXPORTER_OTLP_ENDPOINT   (bare URL)
#   OTEL_EXPORTER_OTLP_HEADERS    ("Authorization=Bearer <KEY>")
#   OTEL_RESOURCE_ATTRIBUTES      ("cx.application.name=x,cx.subsystem.name=y")
# Legacy CX_HOOK_* keys (CX_HOOK_OTLP_ENDPOINT / CX_HOOK_API_KEY /
# CX_HOOK_APPLICATION_NAME / CX_HOOK_SUBSYSTEM_NAME) are read as fallbacks so
# fleets mid-migration keep reporting.
# Optional flags (manual testing): --settings-file, --otlp-endpoint,
# --otlp-headers, --resource-attributes.

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
trim() { # strip leading/trailing whitespace
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
SETTINGS_FILE=""; F_EP=""; F_HD=""; F_RA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --settings-file=*)        SETTINGS_FILE="${1#*=}" ;;
    --settings-file)          shift; SETTINGS_FILE="${1:-}" ;;
    --otlp-endpoint=*)        F_EP="${1#*=}" ;;
    --otlp-endpoint)          shift; F_EP="${1:-}" ;;
    --otlp-headers=*)         F_HD="${1#*=}" ;;
    --otlp-headers)           shift; F_HD="${1:-}" ;;
    --resource-attributes=*)  F_RA="${1#*=}" ;;
    --resource-attributes)    shift; F_RA="${1:-}" ;;
  esac
  [ $# -gt 0 ] && shift
done

# ---------------------------------------------------------------------------
# Config resolution (same file precedence as the reference implementation)
# ---------------------------------------------------------------------------
extract_env() { # $1=file $2=key -> value on stdout (empty if absent)
  [ -f "$1" ] || return 1
  plutil -extract "env.$2" raw -o - "$1" 2>/dev/null
}

get_cfg() { # $1=env key — first non-empty value across the settings files
  if [ -n "$SETTINGS_FILE" ]; then
    v="$(extract_env "$SETTINGS_FILE" "$1")" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  v="$(extract_env "/Library/Application Support/ClaudeCode/managed-settings.json" "$1")" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(extract_env "$HOME/.claude/remote-settings.json" "$1")" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(extract_env "$HOME/.claude/settings.json" "$1")" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  return 0
}

# Pull the value of the exact `Authorization` pair out of an OTLP headers string
# (comma-separated key=value pairs). Matches the key exactly after trimming, so
# X-Authorization / Proxy-Authorization are ignored; takes the first match.
parse_auth() { # $1 = headers string
  _oldifs=$IFS; IFS=','
  for _p in $1; do
    _p="$(trim "$_p")"
    case "$_p" in
      Authorization=*) trim "${_p#Authorization=}"; break ;;
    esac
  done
  IFS=$_oldifs
}

EP="${F_EP:-$(get_cfg OTEL_EXPORTER_OTLP_ENDPOINT)}"
[ -n "$EP" ] || EP="$(get_cfg CX_HOOK_OTLP_ENDPOINT)"
HD="${F_HD:-$(get_cfg OTEL_EXPORTER_OTLP_HEADERS)}"
RA="${F_RA:-$(get_cfg OTEL_RESOURCE_ATTRIBUTES)}"

AUTH="$(parse_auth "$HD")"
if [ -z "$AUTH" ]; then
  _k="$(get_cfg CX_HOOK_API_KEY)"
  [ -n "$_k" ] && AUTH="Bearer $_k"
fi
[ -n "$EP" ] && [ -n "$AUTH" ] || exit 0

# Application/subsystem are stamped only when explicitly configured; otherwise
# routing falls to the API key's admin-panel configuration.
APP=""; SUB=""
_oldifs=$IFS; IFS=','
for pair in $RA; do
  case "$pair" in
    *=*)
      key="$(trim "${pair%%=*}")"
      val="$(trim "${pair#*=}")"
      case "$key" in
        cx.application.name) APP="$val" ;;
        cx.subsystem.name)   SUB="$val" ;;
      esac
      ;;
  esac
done
IFS=$_oldifs
[ -n "$APP" ] || APP="$(get_cfg CX_HOOK_APPLICATION_NAME)"
[ -n "$SUB" ] || SUB="$(get_cfg CX_HOOK_SUBSYSTEM_NAME)"

# ---------------------------------------------------------------------------
# Event (PostToolUse JSON on stdin)
# ---------------------------------------------------------------------------
EV="$(mktemp "${TMPDIR:-/tmp}/cx-hook.XXXXXX")" || exit 0
trap 'rm -f "$EV"' EXIT
cat > "$EV" 2>/dev/null || exit 0

get_ev() { plutil -extract "$1" raw -o - "$EV" 2>/dev/null; }

SID="$(get_ev session_id)"
[ -n "$SID" ] || exit 0
EV_CWD="$(get_ev cwd)"
TOOL="$(get_ev tool_name)"
FP=""
case "$TOOL" in
  Read|Edit|Write|NotebookEdit) FP="$(get_ev tool_input.file_path)" ;;
  Glob|Grep)                    FP="$(get_ev tool_input.path)" ;;
esac
EMAIL="$(get_ev user_email)"
[ -n "$EV_CWD$FP" ] || exit 0

# ---------------------------------------------------------------------------
# Repo detection (git optional). Resolve an ABSOLUTE git binary instead of
# trusting PATH: Claude Code launches hooks with a bare-bones PATH where the
# only git is /usr/bin/git, and that is a shim for Apple's developer tools which
# pops a GUI install dialog when they are absent. So we look for the real
# binaries the shim forwards to (plus the usual package-manager prefixes) and
# never exec the shim itself — which also means a Homebrew git is used even
# though /opt/homebrew/bin is missing from the hook's PATH. Every git call is
# bounded to 5s via a watchdog so a hung fs/mount degrades instead of stalling.
# ---------------------------------------------------------------------------
GIT_BIN=""
for _cand in \
  /opt/homebrew/bin/git \
  /usr/local/bin/git \
  /Library/Developer/CommandLineTools/usr/bin/git \
  /Applications/*.app/Contents/Developer/usr/bin/git
do
  if [ -x "$_cand" ]; then GIT_BIN="$_cand"; break; fi
done
# Anything on PATH except the shim is fine too (custom prefix, or non-macOS).
if [ -z "$GIT_BIN" ]; then
  _p="$(command -v git 2>/dev/null)"
  case "$_p" in ""|/usr/bin/git) ;; *) GIT_BIN="$_p" ;; esac
fi

git_bounded() { # git args...; echoes stdout; returns git rc; SIGTERM'd after 5s
  _o="$(mktemp "${TMPDIR:-/tmp}/cx-git.XXXXXX")" || return 1
  "$GIT_BIN" "$@" >"$_o" 2>/dev/null & _gp=$!
  ( sleep 5; kill -TERM "$_gp" 2>/dev/null ) & _gw=$!
  wait "$_gp" 2>/dev/null; _rc=$?
  kill -TERM "$_gw" 2>/dev/null; wait "$_gw" 2>/dev/null
  cat "$_o"; rm -f "$_o"
  return "$_rc"
}

repo_root() { # $1=dir
  [ -n "$GIT_BIN" ] || return 1
  git_bounded -C "$1" rev-parse --show-toplevel
}

repo_name() { # $1=repo root -> owner/repo (or basename fallback)
  url="$(git_bounded -C "$1" remote get-url origin)"
  if [ -n "$url" ]; then
    u="${url%/}"; u="${u%.git}"
    u="$(printf '%s' "$u" | tr ':' '/')"
    o="$(basename "$(dirname "$u")")"
    n="$(basename "$u")"
    case "$o" in
      ""|"."|"/") printf '%s' "$n" ;;
      *)          printf '%s/%s' "$o" "$n" ;;
    esac
  else
    basename "$1"
  fi
}

# JSON-escape a string: backslash and double-quote, plus the control characters
# (tab, CR, LF) that would otherwise produce invalid JSON. awk processes the
# whole value (sed is line-oriented and can't see embedded newlines).
json_escape() {
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) printf "\\n"
      s = $0
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      gsub(/\t/, "\\t", s)
      gsub(/\r/, "\\r", s)
      printf "%s", s
    }'
}

# ---------------------------------------------------------------------------
# Build OTLP/JSON payload
# ---------------------------------------------------------------------------
NOW_NS=$(( $(date +%s) * 1000000000 ))
SID_E="$(json_escape "$SID")"
EMAIL_E="$(json_escape "$EMAIL")"

DPS=""
add_dp() { # $1=repo name
  r_e="$(json_escape "$1")"
  dp="{\"attributes\":[{\"key\":\"session_id\",\"value\":{\"stringValue\":\"$SID_E\"}},{\"key\":\"repository_name\",\"value\":{\"stringValue\":\"$r_e\"}},{\"key\":\"user_email\",\"value\":{\"stringValue\":\"$EMAIL_E\"}}],\"timeUnixNano\":\"$NOW_NS\",\"asInt\":\"1\"}"
  DPS="${DPS:+$DPS,}$dp"
}

# Dedupe by repo root AND by resolved name (two roots — e.g. a linked worktree —
# can resolve to the same owner/repo; emit one data point per name).
ROOTS=""; NAMES=""
for p in "$EV_CWD" "$FP"; do
  [ -n "$p" ] || continue
  d="$p"
  [ -d "$d" ] || d="$(dirname "$p" 2>/dev/null)"
  [ -n "$d" ] && [ -d "$d" ] || continue
  root="$(repo_root "$d")" || continue
  [ -n "$root" ] || continue
  printf '%s\n' "$ROOTS" | grep -Fqx "$root" && continue
  ROOTS="$ROOTS$root
"
  name="$(repo_name "$root")"
  [ -n "$name" ] || continue
  printf '%s\n' "$NAMES" | grep -Fqx "$name" && continue
  NAMES="$NAMES$name
"
  add_dp "$name"
done
[ -n "$DPS" ] || add_dp "unknown"

RATTRS="{\"key\":\"service.name\",\"value\":{\"stringValue\":\"claude-code-hook\"}}"
[ -n "$APP" ] && RATTRS="$RATTRS,{\"key\":\"cx.application.name\",\"value\":{\"stringValue\":\"$(json_escape "$APP")\"}}"
[ -n "$SUB" ] && RATTRS="$RATTRS,{\"key\":\"cx.subsystem.name\",\"value\":{\"stringValue\":\"$(json_escape "$SUB")\"}}"

PAYLOAD="{\"resourceMetrics\":[{\"resource\":{\"attributes\":[$RATTRS]},\"scopeMetrics\":[{\"scope\":{\"name\":\"repo-tracker\",\"version\":\"1.0.0\"},\"metrics\":[{\"name\":\"claude_code_session_repo_info\",\"gauge\":{\"dataPoints\":[$DPS]}}]}]}]}"

# ---------------------------------------------------------------------------
# Emit (errors swallowed by design; the hook must never disturb the session)
# ---------------------------------------------------------------------------
case "$EP" in
  http://*|https://*) ;;
  *) EP="https://$EP" ;;
esac
EP="${EP%/}"

curl -s -o /dev/null --max-time 5 -X POST "$EP/v1/metrics" \
  -H 'Content-Type: application/json' \
  -H "Authorization: $AUTH" \
  --data-binary "$PAYLOAD" 2>/dev/null

exit 0
