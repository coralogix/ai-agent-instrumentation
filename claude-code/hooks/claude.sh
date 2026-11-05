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

# Claude Code hook that reports session activity and repositories (macOS).
#
# Sends one OTLP/JSON span "agent_hook.<event>" to /v1/traces for each of:
# SessionStart, UserPromptSubmit, PostToolUse, PostToolUseFailure, CwdChanged,
# DirectoryAdded, SessionEnd (other events are ignored). The span carries the
# session/user ids, per-event fields and the vcs_* attributes of the target
# repo; never prompt text, tool input/output or file paths. On PostToolUse it
# also sends the OTLP/JSON gauge metric claude_code_session_repo_info with
# labels {session_id, repository_name, branch_name, user_email} to /v1/metrics.
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
# Event (hook JSON on stdin)
# ---------------------------------------------------------------------------
EV="$(mktemp "${TMPDIR:-/tmp}/cx-hook.XXXXXX")" || exit 0
trap 'rm -f "$EV"' EXIT
cat > "$EV" 2>/dev/null || exit 0

get_ev() { plutil -extract "$1" raw -o - "$EV" 2>/dev/null; }

SID="$(get_ev session_id)"
[ -n "$SID" ] || exit 0
# Empty event name = PostToolUse, for old registrations and the test harness.
HOOK="$(get_ev hook_event_name)"
[ -n "$HOOK" ] || HOOK="PostToolUse"
case "$HOOK" in
  SessionStart|UserPromptSubmit|PostToolUse|PostToolUseFailure|CwdChanged|DirectoryAdded|SessionEnd) ;;
  *) exit 0 ;;
esac
EV_CWD="$(get_ev cwd)"
TOOL="$(get_ev tool_name)"
FP=""
case "$TOOL" in
  Read|Edit|Write|NotebookEdit) FP="$(get_ev tool_input.file_path)" ;;
  Glob|Grep)                    FP="$(get_ev tool_input.path)" ;;
esac
EMAIL="$(get_ev user_email)"

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
  # Detach the watchdog from stdout, or its sleep holds the $(...) pipe open for 5s.
  ( sleep 5; kill -TERM "$_gp" 2>/dev/null ) </dev/null >/dev/null 2>&1 & _gw=$!
  wait "$_gp" 2>/dev/null; _rc=$?
  kill -TERM "$_gw" 2>/dev/null; wait "$_gw" 2>/dev/null
  cat "$_o"; rm -f "$_o"
  return "$_rc"
}

repo_root() { # $1=dir
  [ -n "$GIT_BIN" ] || return 1
  git_bounded -C "$1" rev-parse --show-toplevel
}

origin_url() { # $1=repo root -> origin URL with no user or password
  # An https remote can hold a token (https://user:token@host/...): never send it.
  git_bounded -C "$1" remote get-url origin | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@#\1#'
}

repo_name() { # $1=repo root -> owner/repo (or basename fallback)
  url="$(origin_url "$1")"
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

repo_branch() { # $1=repo root -> branch name ("HEAD" when detached)
  # symbolic-ref (not rev-parse) so a fresh repo with no commits still resolves.
  git_bounded -C "$1" symbolic-ref --short -q HEAD || printf 'HEAD'
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

RATTRS="{\"key\":\"service.name\",\"value\":{\"stringValue\":\"claude-code-hook\"}}"
[ -n "$APP" ] && RATTRS="$RATTRS,{\"key\":\"cx.application.name\",\"value\":{\"stringValue\":\"$(json_escape "$APP")\"}}"
[ -n "$SUB" ] && RATTRS="$RATTRS,{\"key\":\"cx.subsystem.name\",\"value\":{\"stringValue\":\"$(json_escape "$SUB")\"}}"
# roi-service keeps only the hook spans with this source type (the Kafka header of the span).
SPAN_RATTRS="$RATTRS,{\"key\":\"cx.integration.source.type\",\"value\":{\"stringValue\":\"anthropic-claude-code\"}}"

case "$EP" in
  http://*|https://*) ;;
  *) EP="https://$EP" ;;
esac
EP="${EP%/}"

# ---------------------------------------------------------------------------
# Span (every listed event). Errors swallowed by design; the hook must never
# disturb the session.
# ---------------------------------------------------------------------------
SATTRS=""
add_str() { # $1=key $2=value -> string attribute, skipped when empty
  [ -n "$2" ] || return 0
  SATTRS="${SATTRS:+$SATTRS,}{\"key\":\"$1\",\"value\":{\"stringValue\":\"$(json_escape "$2")\"}}"
}
add_typed() { # $1=key $2=boolValue|intValue $3=value -> skipped unless valid
  case "$2:$3" in
    boolValue:true|boolValue:false) _v="$3" ;;
    intValue:*[!0-9]*|intValue:) return 0 ;;
    intValue:*) _v="\"$3\"" ;;
    *) return 0 ;;
  esac
  SATTRS="${SATTRS:+$SATTRS,}{\"key\":\"$1\",\"value\":{\"$2\":$_v}}"
}

add_str agent_name "claude-code"
add_str hook_event "$HOOK"
add_str session_id "$SID"
add_str user_email "$EMAIL"
for _k in prompt_id permission_mode agent_id agent_type; do
  add_str "$_k" "$(get_ev "$_k")"
done

case "$HOOK" in
  SessionStart)
    add_str session_source "$(get_ev source)"
    add_str model "$(get_ev model)"
    ;;
  UserPromptSubmit)
    # Length only, never the text. plutil appends one newline: count minus 1.
    _n="$(get_ev prompt | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')"
    [ "${_n:-0}" -gt 0 ] 2>/dev/null && add_typed user_prompt_length intValue "$((_n - 1))"
    ;;
  PostToolUse|PostToolUseFailure)
    _tid="$(get_ev tool_use_id)"
    add_str tool_use_id "$_tid"
    add_str gen_ai.tool_call_id "$_tid"
    add_str tool_name "$TOOL"
    if [ "$HOOK" = "PostToolUse" ]; then
      add_typed tool_success boolValue true
    else
      add_typed tool_success boolValue false
      add_typed tool_interrupted boolValue "$(get_ev is_interrupt)"
    fi
    ;;
  SessionEnd)
    add_str session_end_reason "$(get_ev reason)"
    ;;
esac

# VCS of the target directory: the new/added dir for CwdChanged/DirectoryAdded,
# else the file_path of a file tool, else cwd. Missing path -> its dirname -> cwd.
# Only the tools the ROI service reads as file tools: another tool with a
# file_path (an MCP tool) keeps the cwd repo.
TGT=""
case "$HOOK" in
  CwdChanged)     TGT="$(get_ev new_cwd)" ;;
  DirectoryAdded) TGT="$(get_ev directory)" ;;
  *)
    case "$TOOL" in
      Read|Edit|MultiEdit|Write) TGT="$(get_ev tool_input.file_path)" ;;
    esac
    ;;
esac
[ -n "$TGT" ] || TGT="$EV_CWD"
[ -n "$TGT" ] && [ ! -d "$TGT" ] && TGT="$(dirname "$TGT")"
[ -d "$TGT" ] || TGT="$EV_CWD"
ROOT=""
[ -n "$TGT" ] && [ -d "$TGT" ] && ROOT="$(repo_root "$TGT")" || ROOT=""
if [ -n "$ROOT" ]; then
  add_str vcs_repository_url_full "$(origin_url "$ROOT")"
  add_str vcs_repository_name "$(repo_name "$ROOT")"
  add_str vcs_ref_head_name "$(repo_branch "$ROOT")"
  add_str vcs_ref_head_revision "$(git_bounded -C "$ROOT" rev-parse --verify -q HEAD)"
fi

# macOS date has no %N; perl (when present) gives ns precision.
END_NS="$(perl -MTime::HiRes=time -e 'printf("%.0f", time()*1e9)' 2>/dev/null)"
case "$END_NS" in ''|*[!0-9]*) END_NS="$(date +%s)000000000" ;; esac
START_NS="$END_NS"
_dur="$(get_ev duration_ms)"
case "$_dur" in ''|*[!0-9]*) ;; *) START_NS=$(( END_NS - _dur * 1000000 )) ;; esac

# traceId = first 32 hex of SHA-256(session_id), so all spans of a session join.
TRACE_ID="$( { printf '%s' "$SID" | shasum -a 256 2>/dev/null || printf '%s' "$SID" | openssl dgst -sha256 -r 2>/dev/null; } | cut -c1-32)"
SPAN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

if [ ${#TRACE_ID} -eq 32 ] && [ ${#SPAN_ID} -eq 16 ]; then
  SPAN="{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\",\"name\":\"agent_hook.$HOOK\",\"kind\":1,\"startTimeUnixNano\":\"$START_NS\",\"endTimeUnixNano\":\"$END_NS\",\"attributes\":[$SATTRS]}"
  curl -s -o /dev/null --max-time 5 -X POST "$EP/v1/traces" \
    -H 'Content-Type: application/json' \
    -H "Authorization: $AUTH" \
    --data-binary "{\"resourceSpans\":[{\"resource\":{\"attributes\":[$SPAN_RATTRS]},\"scopeSpans\":[{\"scope\":{\"name\":\"agent-hook\",\"version\":\"2.0.0\"},\"spans\":[$SPAN]}]}]}" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Metric (PostToolUse only): build OTLP/JSON payload
# ---------------------------------------------------------------------------
[ "$HOOK" = "PostToolUse" ] && [ -n "$EV_CWD$FP" ] || exit 0

NOW_NS=$(( $(date +%s) * 1000000000 ))
SID_E="$(json_escape "$SID")"
EMAIL_E="$(json_escape "$EMAIL")"

DPS=""
add_dp() { # $1=repo name, $2=branch name
  r_e="$(json_escape "$1")"
  b_e="$(json_escape "$2")"
  dp="{\"attributes\":[{\"key\":\"session_id\",\"value\":{\"stringValue\":\"$SID_E\"}},{\"key\":\"repository_name\",\"value\":{\"stringValue\":\"$r_e\"}},{\"key\":\"branch_name\",\"value\":{\"stringValue\":\"$b_e\"}},{\"key\":\"user_email\",\"value\":{\"stringValue\":\"$EMAIL_E\"}}],\"timeUnixNano\":\"$NOW_NS\",\"asInt\":\"1\"}"
  DPS="${DPS:+$DPS,}$dp"
}

# Dedupe by repo root AND by resolved name+branch (two roots — e.g. a linked
# worktree — can resolve to the same owner/repo; emit one data point per
# name+branch, so worktrees on different branches each report).
ROOTS=""; KEYS=""
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
  branch="$(repo_branch "$root")"
  printf '%s\n' "$KEYS" | grep -Fqx "$name $branch" && continue
  KEYS="$KEYS$name $branch
"
  add_dp "$name" "$branch"
done
[ -n "$DPS" ] || add_dp "unknown" "unknown"

PAYLOAD="{\"resourceMetrics\":[{\"resource\":{\"attributes\":[$RATTRS]},\"scopeMetrics\":[{\"scope\":{\"name\":\"repo-tracker\",\"version\":\"1.0.0\"},\"metrics\":[{\"name\":\"claude_code_session_repo_info\",\"gauge\":{\"dataPoints\":[$DPS]}}]}]}]}"

# ---------------------------------------------------------------------------
# Emit (errors swallowed by design; the hook must never disturb the session)
# ---------------------------------------------------------------------------
curl -s -o /dev/null --max-time 5 -X POST "$EP/v1/metrics" \
  -H 'Content-Type: application/json' \
  -H "Authorization: $AUTH" \
  --data-binary "$PAYLOAD" 2>/dev/null

exit 0
