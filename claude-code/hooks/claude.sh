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

# Claude Code hook (macOS): one span per session event, so AI Center can link
# each session to the git branches it works on.
#
# Sends one OTLP/JSON span "agent_hook.<event>" to /v1/traces on SessionStart,
# UserPromptSubmit, CwdChanged, SessionEnd, and PostToolUse of Edit, MultiEdit,
# Write and NotebookEdit. Other events and tools are ignored. The span holds the
# session id, the event name, the tool name of an edit, the claude.ai login
# email cached on the machine, and the host URL, owner/repo and branch of the
# repository's origin. It never holds prompts, tool input or output, local
# paths or credentials.
#
# The hook reads the event, stamps its time and starts a background sender that
# runs git and the POST, so the session never waits, and the send survives the
# SessionEnd budget and the end of `claude -p`.
#
# Uses only tools that ship with macOS: /bin/sh, plutil, curl, awk, shasum, od.
# git is optional: without it the span has no vcs_* attributes.
#
# Config is read in Claude Code's managed-source order (the server-managed
# cache, the MDM profile com.anthropic.claudecode, managed-settings.json), then
# the user settings, because Claude Code does not reliably pass its `env` block
# to hooks (claude-code#20112):
#   OTEL_EXPORTER_OTLP_ENDPOINT   (bare URL)
#   OTEL_EXPORTER_OTLP_HEADERS    ("Authorization=Bearer <KEY>")
#   OTEL_RESOURCE_ATTRIBUTES      ("cx.application.name=x,cx.subsystem.name=y")
# Legacy CX_HOOK_* keys (CX_HOOK_OTLP_ENDPOINT / CX_HOOK_API_KEY /
# CX_HOOK_APPLICATION_NAME / CX_HOOK_SUBSYSTEM_NAME) are read as fallbacks.
# Optional flags (manual testing): --settings-file, --otlp-endpoint,
# --otlp-headers, --resource-attributes.
# A failed send writes its time and HTTP status (never the key) to
# ~/.claude/coralogix-hook-last-error.txt.

AGENT_NAME="claude-code"
SERVICE_NAME="claude-code-hook"
# Coralogix routes spans of this source type to the Claude Code spans dataset.
SOURCE_TYPE="claude_code_agent"
LAST_ERROR_FILE="$HOME/.claude/coralogix-hook-last-error.txt"

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
# Config: env.<KEY> from the first settings source that defines it, in Claude
# Code's managed-source order, so a defined empty value turns the key off as it
# does for Claude Code. plutil reads both the plist and the JSON.
# ---------------------------------------------------------------------------
extract_env() { # $1=file $2=key -> value on stdout (empty if absent)
  [ -f "$1" ] || return 1
  plutil -extract "env.$2" raw -o - "$1" 2>/dev/null
}

get_cfg() { # $1=env key
  for _f in \
    "$SETTINGS_FILE" \
    "$HOME/.claude/remote-settings.json" \
    "/Library/Managed Preferences/$(id -un 2>/dev/null)/com.anthropic.claudecode.plist" \
    "/Library/Managed Preferences/com.anthropic.claudecode.plist" \
    "/Library/Application Support/ClaudeCode/managed-settings.json" \
    "$HOME/.claude/settings.json"
  do
    [ -n "$_f" ] || continue
    _v="$(extract_env "$_f" "$1")" && { printf '%s' "$_v"; return 0; }
  done
  return 0
}

# The value of the exact `Authorization` pair of an OTLP headers string
# (comma-separated key=value pairs); X-Authorization and the like are ignored.
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
# Off until an endpoint and a key are configured.
[ -n "$EP" ] && [ -n "$AUTH" ] || exit 0

case "$EP" in
  http://*|https://*) ;;
  *) EP="https://$EP" ;;
esac
EP="${EP%/}"

# Application/subsystem are stamped only when configured; otherwise routing
# falls to the send-data key's defaults.
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
# Event (hook JSON on stdin): only what the span needs leaves this process.
# ---------------------------------------------------------------------------
EV="$(mktemp "${TMPDIR:-/tmp}/cx-hook.XXXXXX")" || exit 0
trap 'rm -f "$EV"' EXIT
cat > "$EV" 2>/dev/null || exit 0

get_ev() { plutil -extract "$1" raw -o - "$EV" 2>/dev/null; }

SID="$(get_ev session_id)"
HOOK="$(get_ev hook_event_name)"
[ -n "$SID" ] && [ -n "$HOOK" ] || exit 0

TOOL=""; DIR=""
case "$HOOK" in
  SessionStart|UserPromptSubmit|CwdChanged|SessionEnd) ;;
  PostToolUse)
    # The edit goes to the branch of the edited file, which can differ from the cwd's.
    TOOL="$(get_ev tool_name)"
    case "$TOOL" in
      Edit|MultiEdit|Write) _file="$(get_ev tool_input.file_path)" ;;
      NotebookEdit)         _file="$(get_ev tool_input.notebook_path)" ;;
      *) exit 0 ;;
    esac
    [ -n "$_file" ] && DIR="$(dirname "$_file")"
    ;;
  *) exit 0 ;;
esac
[ -n "$DIR" ] || DIR="$(get_ev new_cwd)"
[ -n "$DIR" ] || DIR="$(get_ev cwd)"

# The event time: the sender can spend seconds in git. macOS date has no %N.
TIME_NS="$(perl -MTime::HiRes=time -e 'printf("%.0f", time()*1e9)' 2>/dev/null)"
case "$TIME_NS" in ''|*[!0-9]*) TIME_NS="$(date +%s)000000000" ;; esac

# ---------------------------------------------------------------------------
# Trace: a span inside a turn joins the turn's trace; the other spans of a
# session share one trace (first 32 hex of SHA-256(session_id)).
# ---------------------------------------------------------------------------
tracing_on() { # Claude Code traces only with the beta flag on and a traces exporter set
  _exp="${OTEL_TRACES_EXPORTER:-}"
  [ -n "$_exp" ] || _exp="$(get_cfg OTEL_TRACES_EXPORTER)"
  case "$(trim "$_exp" | tr '[:upper:]' '[:lower:]')" in ""|none) return 1 ;; esac
  for _flag in CLAUDE_CODE_ENHANCED_TELEMETRY_BETA ENABLE_ENHANCED_TELEMETRY_BETA; do
    eval "_v=\${$_flag:-}"
    [ -n "$_v" ] || _v="$(get_cfg "$_flag")"
    case "$(trim "$_v" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|on) return 0 ;;
    esac
  done
  return 1
}

turn_span() { # $1=TRACEPARENT (version-traceid-parentid-flags) -> sets TRACE_ID PARENT_ID
  case "$1" in ""|*[!0-9a-f-]*) return 1 ;; esac
  _oldifs=$IFS; IFS='-'
  # shellcheck disable=SC2086 # split on "-"; the case above allows only hex and "-"
  set -- $1
  IFS=$_oldifs
  [ $# -eq 4 ] && [ ${#1} -eq 2 ] && [ ${#2} -eq 32 ] && [ ${#3} -eq 16 ] && [ ${#4} -eq 2 ] || return 1
  case "$2" in *[!0]*) ;; *) return 1 ;; esac
  case "$3" in *[!0]*) ;; *) return 1 ;; esac
  TRACE_ID="$2"; PARENT_ID="$3"
}

TRACE_ID=""; PARENT_ID=""
# Claude Code sets TRACEPARENT to the turn's span only during a turn with its
# tracing on; otherwise it is inherited from the shell and names another trace.
case "$HOOK" in
  SessionStart|SessionEnd) ;;
  *) tracing_on && turn_span "${TRACEPARENT:-}" ;;
esac
if [ -z "$TRACE_ID" ]; then
  TRACE_ID="$(printf '%s' "$SID" | shasum -a 256 2>/dev/null | cut -c1-32)"
  PARENT_ID=""
fi
SPAN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
[ ${#TRACE_ID} -eq 32 ] && [ ${#SPAN_ID} -eq 16 ] || exit 0

# ---------------------------------------------------------------------------
# Repository (git optional). Resolve an ABSOLUTE git binary: hooks get a
# bare-bones PATH where the only git is the /usr/bin/git shim, which pops a GUI
# install dialog on Macs without the developer tools. Every git call is bounded
# to 5s, so a hung mount degrades instead of stalling.
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
if [ -z "$GIT_BIN" ]; then
  _p="$(command -v git 2>/dev/null)"
  case "$_p" in ""|/usr/bin/git) ;; *) GIT_BIN="$_p" ;; esac
fi

git_bounded() { # git args...; echoes stdout; returns git rc; SIGTERM'd after 5s
  [ -n "$GIT_BIN" ] || return 1
  _o="$(mktemp "${TMPDIR:-/tmp}/cx-git.XXXXXX")" || return 1
  "$GIT_BIN" "$@" </dev/null >"$_o" 2>/dev/null & _gp=$!
  # Detach the watchdog from stdout, or its sleep holds the $(...) pipe open for 5s.
  ( sleep 5; kill -TERM "$_gp" 2>/dev/null ) </dev/null >/dev/null 2>&1 & _gw=$!
  wait "$_gp" 2>/dev/null; _rc=$?
  kill -TERM "$_gw" 2>/dev/null; wait "$_gw" 2>/dev/null
  cat "$_o"; rm -f "$_o"
  return "$_rc"
}

# Origin URL without user info, query or fragment, and owner/repo, as GitHub
# events name it. Fails for an origin on this machine: /path, C:\path, file://,
# or a remote helper address such as hg::/path.
parse_remote() { # $1=origin URL -> sets REPO_URL REPO_NAME
  REPO_URL=""; REPO_NAME=""
  case "$1" in
    "") return 1 ;;
    *://*)
      _scheme="${1%%://*}"
      _rest="${1#*://}"
      _authority="${_rest%%/*}"
      _host="${_authority##*@}"
      case "$_host" in
        *[?#]*) _host="${_host%%[?#]*}"; _path="" ;;
        *)
          case "$_rest" in */*) _path="/${_rest#*/}" ;; *) _path="" ;; esac
          _path="${_path%%[?#]*}"
          ;;
      esac
      [ "$_scheme" != file ] && [ -n "$_host" ] || return 1
      REPO_URL="$_scheme://$_host$_path"
      ;;
    *:*)
      _prefix="${1%%:*}"
      _path="${1#*:}"
      _host="${_prefix##*@}"
      case "$_path" in :*) return 1 ;; esac
      case "$_prefix" in */*|*\\*) return 1 ;; esac
      [ ${#_host} -ge 2 ] || return 1
      while case "$_path" in /*) true ;; *) false ;; esac; do _path="${_path#/}"; done
      REPO_URL="ssh://$_host/$_path"
      ;;
    *) return 1 ;;
  esac
  while case "$_path" in /*) true ;; *) false ;; esac; do _path="${_path#/}"; done
  while case "$_path" in */) true ;; *) false ;; esac; do _path="${_path%/}"; done
  _path="${_path%.git}"
  case "$_path" in
    */*) _parent="${_path%/*}"; REPO_NAME="${_parent##*/}/${_path##*/}" ;;
    *)   REPO_NAME="$_path" ;;
  esac
}

# JSON-escape a string: backslash, double quote, tab, CR, LF.
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

ATTRS=""
add_attr() { # $1=key $2=value -> string attribute, skipped when empty
  [ -n "$2" ] || return 0
  ATTRS="${ATTRS:+$ATTRS,}{\"key\":\"$1\",\"value\":{\"stringValue\":\"$(json_escape "$2")\"}}"
}

record_error() { # $1=message; the sender runs detached, so this file is the only trace of a failure
  [ -d "$HOME/.claude" ] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$LAST_ERROR_FILE" 2>/dev/null
}

send_span() {
  # An inherited GIT_DIR or GIT_WORK_TREE would point `git -C` at another repository.
  for _var in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_var"; done

  add_attr agent_name "$AGENT_NAME"
  add_attr hook_event "$HOOK"
  add_attr session_id "$SID"
  # The claude.ai login cached in ~/.claude.json, when present. It can outlive a switch to an API key.
  add_attr user_email "$(plutil -extract oauthAccount.emailAddress raw -o - "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)"
  add_attr tool_name "$TOOL"
  if [ -n "$DIR" ] && parse_remote "$(git_bounded -C "$DIR" remote get-url origin)"; then
    add_attr vcs_repository_url_full "$REPO_URL"
    add_attr vcs_repository_name "$REPO_NAME"
    # Not --short: it prints heads/<name> when a tag has the same name. Fails on a detached HEAD.
    _ref="$(git_bounded -C "$DIR" symbolic-ref --quiet HEAD)"
    case "$_ref" in refs/heads/?*) add_attr vcs_ref_head_name "${_ref#refs/heads/}" ;; esac
  fi

  _rattrs="{\"key\":\"service.name\",\"value\":{\"stringValue\":\"$SERVICE_NAME\"}},{\"key\":\"cx.source.integration.type\",\"value\":{\"stringValue\":\"$SOURCE_TYPE\"}}"
  [ -n "$APP" ] && _rattrs="$_rattrs,{\"key\":\"cx.application.name\",\"value\":{\"stringValue\":\"$(json_escape "$APP")\"}}"
  [ -n "$SUB" ] && _rattrs="$_rattrs,{\"key\":\"cx.subsystem.name\",\"value\":{\"stringValue\":\"$(json_escape "$SUB")\"}}"
  _parent=""
  [ -n "$PARENT_ID" ] && _parent=",\"parentSpanId\":\"$PARENT_ID\""
  _span="{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\"$_parent,\"name\":\"agent_hook.$(json_escape "$HOOK")\",\"kind\":1,\"startTimeUnixNano\":\"$TIME_NS\",\"endTimeUnixNano\":\"$TIME_NS\",\"attributes\":[$ATTRS]}"
  _payload="{\"resourceSpans\":[{\"resource\":{\"attributes\":[$_rattrs]},\"scopeSpans\":[{\"scope\":{\"name\":\"$SERVICE_NAME\"},\"spans\":[$_span]}]}]}"

  # curl follows no redirect, so the key never goes to another URL.
  _code="$(printf '%s' "$_payload" | curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -X POST "$EP/v1/traces" \
    -H 'Content-Type: application/json' \
    -H "Authorization: $AUTH" \
    --data-binary @- 2>/dev/null)"
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    record_error "curl exit $_rc"
  else
    case "$_code" in 2??) ;; *) record_error "HTTP $_code" ;; esac
  fi
}

# Background sender: SIGHUP ignored so a closing terminal does not cut the send;
# SIGINT is already ignored in a background job of a non-interactive shell.
( trap '' HUP; send_span ) </dev/null >/dev/null 2>&1 &
exit 0
