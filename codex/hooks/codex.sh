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

# Codex PostToolUse hook that tracks repository names per session (macOS/Linux).
#
# Emits an OTLP/JSON gauge metric codex_session_repo_info with labels
# {session_id, repository_name, user_email} on each tool use. session_id is the
# Codex thread id (joins with conversation.id on Codex OTel log events);
# repository_name is the checkout's `origin` URL, credentials stripped.
#
# ZERO runtime assumptions: /bin/sh, curl, awk, sed, mktemp — all ship with
# macOS and every mainstream Linux. plutil is used for JSON parsing when
# present (macOS), with a sed fallback elsewhere. No node, no python. git is
# optional: repo detection degrades to "unknown" without it, and every git
# call is bounded to 5s so a stale mount can never hang the session.
#
# Config is read from the same Codex TOML files that hold the [otel] blocks,
# reusing the metrics exporter's endpoint and headers — no separate hook
# credentials:
#   [otel.metrics_exporter.otlp-http]          endpoint
#   [otel.metrics_exporter.otlp-http.headers]  "Authorization",
#                                              "CX-Application-Name",
#                                              "CX-Subsystem-Name"
# File precedence (first non-empty value per key): --config-file, the macOS
# managed preference com.openai.codex/config_toml_base64, then
# /etc/codex/managed_config.toml, then $CODEX_HOME/config.toml (~/.codex).
#
# user_email is decoded from the ChatGPT id_token in $CODEX_HOME/auth.json;
# it stays empty for API-key sign-in (Codex hook events carry no email field).
# Optional flags (manual testing): --config-file, --auth-file,
# --otlp-endpoint, --authorization.

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
trim() { # strip leading/trailing whitespace
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
CONFIG_FILE=""; AUTH_FILE=""; F_EP=""; F_AUTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config-file=*)    CONFIG_FILE="${1#*=}" ;;
    --config-file)      shift; CONFIG_FILE="${1:-}" ;;
    --auth-file=*)      AUTH_FILE="${1#*=}" ;;
    --auth-file)        shift; AUTH_FILE="${1:-}" ;;
    --otlp-endpoint=*)  F_EP="${1#*=}" ;;
    --otlp-endpoint)    shift; F_EP="${1:-}" ;;
    --authorization=*)  F_AUTH="${1#*=}" ;;
    --authorization)    shift; F_AUTH="${1:-}" ;;
  esac
  [ $# -gt 0 ] && shift
done

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HAVE_PLUTIL=0
command -v plutil >/dev/null 2>&1 && HAVE_PLUTIL=1

# ---------------------------------------------------------------------------
# JSON field extraction: plutil when available (macOS), sed fallback (Linux).
# The fallback matches the first `"key": "value"` pair in the file — fine for
# the flat identifier fields this hook reads (UUIDs, paths, JWTs).
# ---------------------------------------------------------------------------
json_get() { # $1=file $2=plutil keypath $3=bare key for the sed fallback
  [ -f "$1" ] || return 1
  if [ "$HAVE_PLUTIL" = 1 ]; then
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
  else
    sed -n 's/.*"'"$3"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n 1
  fi
}

# ---------------------------------------------------------------------------
# Minimal TOML lookup: first `key = "value"` under an exact [section] header.
# Handles quoted and bare keys, basic ("...") and literal ('...') strings —
# the shapes the documented Coralogix template uses.
# ---------------------------------------------------------------------------
toml_get() { # $1=file $2=section $3=key
  [ -f "$1" ] || return 1
  awk -v want="$2" -v key="$3" -v sq="'" '
    /^[ \t]*\[/ {
      s = $0
      sub(/^[ \t]*\[+/, "", s); sub(/\]+[ \t]*(#.*)?$/, "", s)
      insec = (s == want); next
    }
    insec {
      line = $0
      sub(/^[ \t]*/, "", line)
      if (line !~ /=/) next
      k = line
      sub(/[ \t]*=.*$/, "", k)
      gsub(/^"|"$/, "", k)
      if (k != key) next
      v = line
      sub(/^[^=]*=[ \t]*/, "", v)
      if (v ~ /^"/)       { sub(/^"/, "", v);  sub(/".*$/, "", v) }
      else if (v ~ "^" sq) { sub("^" sq, "", v); sub(sq ".*$", "", v) }
      else                { sub(/[ \t]*(#.*)?$/, "", v) }
      print v; exit
    }' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Config file candidates, highest precedence first (mirrors the Codex loader:
# macOS MDM payload > /etc/codex/managed_config.toml > user config.toml).
# ---------------------------------------------------------------------------
b64_decode() { # portable base64 decode (GNU -d / older macOS -D)
  base64 -d 2>/dev/null || base64 -D 2>/dev/null
}

MDM_TMP=""
if [ "$HAVE_PLUTIL" = 1 ]; then
  _b64="$(plutil -extract config_toml_base64 raw -o - \
    "/Library/Managed Preferences/com.openai.codex.plist" 2>/dev/null)"
  if [ -n "$_b64" ]; then
    MDM_TMP="$(mktemp "${TMPDIR:-/tmp}/cx-codex-mdm.XXXXXX")" 2>/dev/null &&
      printf '%s' "$_b64" | b64_decode > "$MDM_TMP" 2>/dev/null
  fi
fi

cfg_get() { # $1=section $2=key — first non-empty value across the candidates
  for f in "$CONFIG_FILE" "$MDM_TMP" "/etc/codex/managed_config.toml" "$CODEX_HOME/config.toml"; do
    [ -n "$f" ] || continue
    v="$(toml_get "$f" "$1" "$2")" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 0
}

MSEC="otel.metrics_exporter.otlp-http"
EP="${F_EP:-$(cfg_get "$MSEC" endpoint)}"
AUTH="${F_AUTH:-$(cfg_get "$MSEC.headers" Authorization)}"
APP="$(cfg_get "$MSEC.headers" CX-Application-Name)"
SUB="$(cfg_get "$MSEC.headers" CX-Subsystem-Name)"
[ -n "$MDM_TMP" ] && rm -f "$MDM_TMP"
[ -n "$EP" ] && [ -n "$AUTH" ] || exit 0

# ---------------------------------------------------------------------------
# Event (PostToolUse JSON on stdin). cwd is always present; a shell tool's
# tool_input.workdir is used as a second candidate when the model set one.
# ---------------------------------------------------------------------------
EV="$(mktemp "${TMPDIR:-/tmp}/cx-hook.XXXXXX")" || exit 0
trap 'rm -f "$EV"' EXIT
cat > "$EV" 2>/dev/null || exit 0

SID="$(json_get "$EV" session_id session_id)"
[ -n "$SID" ] || exit 0
EV_CWD="$(json_get "$EV" cwd cwd)"
WD="$(json_get "$EV" tool_input.workdir workdir)"
case "$WD" in
  "" | /*) ;;
  *) [ -n "$EV_CWD" ] && WD="$EV_CWD/$WD" ;; # relative workdir is cwd-relative
esac
[ -n "$EV_CWD$WD" ] || exit 0

# user_email: decode the id_token JWT payload from auth.json (ChatGPT
# sign-in); silently empty for API-key auth or unreadable files.
EMAIL=""
AUTH_JSON="${AUTH_FILE:-$CODEX_HOME/auth.json}"
IDT="$(json_get "$AUTH_JSON" tokens.id_token id_token)"
if [ -n "$IDT" ]; then
  _seg="$(printf '%s' "$IDT" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#_seg} % 4 )) in
    2) _seg="$_seg==" ;;
    3) _seg="$_seg=" ;;
  esac
  EMAIL="$(printf '%s' "$_seg" | b64_decode |
    sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
fi

# ---------------------------------------------------------------------------
# Repo detection (git optional; on macOS avoid the /usr/bin/git CLT stub,
# which pops a GUI install dialog on Macs without Command Line Tools). Every
# git call is bounded to 5s so a hung fs/mount degrades instead of stalling.
# ---------------------------------------------------------------------------
GIT_OK=0
GIT_PATH="$(command -v git 2>/dev/null)"
if [ -n "$GIT_PATH" ]; then
  if [ "$(uname -s)" = "Darwin" ] && [ "$GIT_PATH" = "/usr/bin/git" ]; then
    xcode-select -p >/dev/null 2>&1 && GIT_OK=1
  else
    GIT_OK=1
  fi
fi

git_bounded() { # git args...; echoes stdout; returns git rc; SIGTERM'd after 5s
  _o="$(mktemp "${TMPDIR:-/tmp}/cx-git.XXXXXX")" || return 1
  git "$@" >"$_o" 2>/dev/null & _gp=$!
  ( sleep 5; kill -TERM "$_gp" 2>/dev/null ) & _gw=$!
  wait "$_gp" 2>/dev/null; _rc=$?
  kill -TERM "$_gw" 2>/dev/null; wait "$_gw" 2>/dev/null
  cat "$_o"; rm -f "$_o"
  return "$_rc"
}

repo_root() { # $1=dir
  [ "$GIT_OK" = 1 ] || return 1
  git_bounded -C "$1" rev-parse --show-toplevel
}

repo_name() { # $1=repo root; sets REPO_NAME to the origin URL (dir-name fallback)
  REPO_NAME="$(git_bounded -C "$1" remote get-url origin)"
  [ -n "$REPO_NAME" ] || REPO_NAME="${1##*/}"
  # Never label a token; an '@' after the authority belongs to the path.
  rest="${REPO_NAME#*://}"
  case "$REPO_NAME" in
    *://*@*)
      case "${rest%%/*}" in
        *@*) REPO_NAME="${REPO_NAME%%://*}://${rest#*@}" ;;
      esac ;;
  esac
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
# share one origin URL; emit one data point per name).
ROOTS=""; NAMES=""
for p in "$EV_CWD" "$WD"; do
  [ -n "$p" ] || continue
  d="$p"
  [ -d "$d" ] || d="$(dirname "$p" 2>/dev/null)"
  [ -n "$d" ] && [ -d "$d" ] || continue
  root="$(repo_root "$d")" || continue
  [ -n "$root" ] || continue
  printf '%s\n' "$ROOTS" | grep -Fqx "$root" && continue
  ROOTS="$ROOTS$root
"
  repo_name "$root"
  [ -n "$REPO_NAME" ] || continue
  printf '%s\n' "$NAMES" | grep -Fqx "$REPO_NAME" && continue
  NAMES="$NAMES$REPO_NAME
"
  add_dp "$REPO_NAME"
done
[ -n "$DPS" ] || add_dp "unknown"

RATTRS="{\"key\":\"service.name\",\"value\":{\"stringValue\":\"codex-hook\"}}"
[ -n "$APP" ] && RATTRS="$RATTRS,{\"key\":\"cx.application.name\",\"value\":{\"stringValue\":\"$(json_escape "$APP")\"}}"
[ -n "$SUB" ] && RATTRS="$RATTRS,{\"key\":\"cx.subsystem.name\",\"value\":{\"stringValue\":\"$(json_escape "$SUB")\"}}"

PAYLOAD="{\"resourceMetrics\":[{\"resource\":{\"attributes\":[$RATTRS]},\"scopeMetrics\":[{\"scope\":{\"name\":\"repo-tracker\",\"version\":\"1.0.0\"},\"metrics\":[{\"name\":\"codex_session_repo_info\",\"gauge\":{\"dataPoints\":[$DPS]}}]}]}]}"

# ---------------------------------------------------------------------------
# Emit (errors swallowed by design; the hook must never disturb the session).
# The configured endpoint is the metrics exporter's URL, which already ends in
# /v1/metrics in the documented template; append the path when given a bare
# ingress host.
# ---------------------------------------------------------------------------
case "$EP" in
  http://*|https://*) ;;
  *) EP="https://$EP" ;;
esac
EP="${EP%/}"
case "$EP" in
  */v1/metrics) ;;
  *) EP="$EP/v1/metrics" ;;
esac

curl -s -o /dev/null --max-time 5 -X POST "$EP" \
  -H 'Content-Type: application/json' \
  -H "Authorization: $AUTH" \
  --data-binary "$PAYLOAD" 2>/dev/null

exit 0
