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

# Codex CLI PostToolUse hook that tracks repository names per session (macOS).
#
# Emits an OTLP/JSON gauge metric codex_session_repo_info with labels
# {session_id, repository_name} on each tool use. repository_name is the
# checkout's `origin` URL, credentials stripped. session_id equals the
# conversation.id on Codex's own OTel log events (codex.api_request,
# codex.sse_event, ...), which carry user.email — so user attribution is a
# join, not another label on this metric.
#
# ZERO runtime assumptions: uses only tools that ship with macOS itself —
# /bin/sh, plutil (JSON parsing), awk (TOML parsing), curl (HTTPS), mktemp.
# No node, no python, no binaries to sign. git is optional: repo detection
# degrades to "unknown" without it, and every git call is bounded to 5s so a
# stale mount can never hang the session.
#
# Config comes from the same ~/.codex/config.toml [otel] block this repo's
# codex/config.toml.example installs — one config serves Codex's native
# telemetry and this hook, with no duplicated secrets:
#   [otel.exporter.otlp-http]          endpoint  (the /v1/logs suffix is
#                                       swapped for /v1/metrics)
#   [otel.exporter.otlp-http.headers]  Authorization, CX-Application-Name,
#                                       CX-Subsystem-Name
# CX_* environment variables (CX_OTLP_ENDPOINT / CX_API_KEY /
# CX_APPLICATION_NAME / CX_SUBSYSTEM_NAME — the same names codex/.env.example
# uses) are read as fallbacks for machines that configure Codex differently.
# Optional flags (manual testing): --config-file, --otlp-endpoint,
# --otlp-auth, --application-name, --subsystem-name.

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
trim() { # strip leading/trailing whitespace
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
CFG="$HOME/.codex/config.toml"
F_EP=""; F_AUTH=""; F_APP=""; F_SUB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config-file=*)       CFG="${1#*=}" ;;
    --config-file)         shift; CFG="${1:-}" ;;
    --otlp-endpoint=*)     F_EP="${1#*=}" ;;
    --otlp-endpoint)       shift; F_EP="${1:-}" ;;
    --otlp-auth=*)         F_AUTH="${1#*=}" ;;
    --otlp-auth)           shift; F_AUTH="${1:-}" ;;
    --application-name=*)  F_APP="${1#*=}" ;;
    --application-name)    shift; F_APP="${1:-}" ;;
    --subsystem-name=*)    F_SUB="${1#*=}" ;;
    --subsystem-name)      shift; F_SUB="${1:-}" ;;
  esac
  [ $# -gt 0 ] && shift
done

# ---------------------------------------------------------------------------
# Config resolution: flags > ~/.codex/config.toml > CX_* environment
# ---------------------------------------------------------------------------
# Minimal TOML reader for the documented [otel.exporter.otlp-http] shape:
# tracks the current [section] (quotes in section parts ignored, so
# [otel.exporter."otlp-http"] matches too) and prints the first `key = "value"`
# in it. Quoted values are taken up to the closing quote, which also drops any
# trailing comment. Deliberately not a general TOML parser — anything it cannot
# read falls through to the CX_* environment fallbacks.
toml_get() { # $1=section path  $2=key -> value on stdout (empty if absent)
  [ -f "$CFG" ] || return 0
  awk -v sect="$1" -v key="$2" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      s = $0
      sub(/^[[:space:]]*\[+/, "", s); sub(/\]+.*$/, "", s)
      gsub(/"/, "", s); gsub(/[[:space:]]/, "", s)
      cur = s; next
    }
    cur == sect && /=/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      k = line
      sub(/[[:space:]]*=.*$/, "", k)
      gsub(/^"|"$/, "", k)
      if (k != key) next
      v = line
      sub(/^[^=]*=[[:space:]]*/, "", v)
      if (v ~ /^"/) {
        # Basic string: take up to the closing quote, honouring \" escapes,
        # then unescape. Also drops any trailing comment.
        if (match(v, /^"(\\.|[^"\\])*"/)) {
          v = substr(v, 2, RLENGTH - 2)
          gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v)
        } else { sub(/^"/, "", v); sub(/".*$/, "", v) }
      }
      else if (v ~ /^'\''/) { sub(/^'\''/, "", v); sub(/'\''.*$/, "", v) }
      else { sub(/[[:space:]]*#.*$/, "", v) }
      sub(/[[:space:]]*$/, "", v)
      print v; exit
    }
  ' "$CFG" 2>/dev/null
}

EP="$F_EP"
[ -n "$EP" ] || EP="$(toml_get otel.exporter.otlp-http endpoint)"
[ -n "$EP" ] || EP="$CX_OTLP_ENDPOINT"

AUTH="$F_AUTH"
[ -n "$AUTH" ] || AUTH="$(toml_get otel.exporter.otlp-http.headers Authorization)"
[ -n "$AUTH" ] || { [ -n "$CX_API_KEY" ] && AUTH="Bearer $CX_API_KEY"; }

[ -n "$EP" ] && [ -n "$AUTH" ] || exit 0

# Application/subsystem are stamped only when explicitly configured; otherwise
# routing falls to the API key's admin-panel configuration.
APP="$F_APP"
[ -n "$APP" ] || APP="$(toml_get otel.exporter.otlp-http.headers CX-Application-Name)"
[ -n "$APP" ] || APP="$CX_APPLICATION_NAME"
SUB="$F_SUB"
[ -n "$SUB" ] || SUB="$(toml_get otel.exporter.otlp-http.headers CX-Subsystem-Name)"
[ -n "$SUB" ] || SUB="$CX_SUBSYSTEM_NAME"

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
# Codex shell tools carry only {command}; file tools may carry a path — probe
# the common keys and fall back to cwd alone when absent.
FP="$(get_ev tool_input.file_path)"
[ -n "$FP" ] || FP="$(get_ev tool_input.path)"
[ -n "$EV_CWD$FP" ] || exit 0
# For the PR counter only — see track_counts. Both may be empty or huge; they
# are grepped, never executed or shipped anywhere.
EV_CMD="$(get_ev tool_input.command)"
EV_RESP="$(get_ev tool_response)"

# ---------------------------------------------------------------------------
# Repo detection (git optional; avoid the /usr/bin/git CLT stub, which pops a
# GUI install dialog on Macs without Command Line Tools). Every git call is
# bounded to 5s via a watchdog so a hung fs/mount degrades instead of stalling.
# ---------------------------------------------------------------------------
GIT_OK=0
GIT_PATH="$(command -v git 2>/dev/null)"
if [ -n "$GIT_PATH" ]; then
  if [ "$GIT_PATH" = "/usr/bin/git" ]; then
    xcode-select -p >/dev/null 2>&1 && GIT_OK=1
  else
    GIT_OK=1
  fi
fi

git_bounded() { # git args...; echoes stdout; returns git rc; SIGTERM'd after 5s
  _o="$(mktemp "${TMPDIR:-/tmp}/cx-git.XXXXXX")" || return 1
  git "$@" >"$_o" 2>/dev/null & _gp=$!
  # The watchdog must NOT inherit our stdout: callers run this function inside
  # a command substitution, and an inherited pipe write-end would keep the
  # caller's read blocked for the full 5s even after git returns instantly
  # (killing the wrapper subshell does not kill its sleep).
  ( sleep 5; kill -TERM "$_gp" 2>/dev/null ) >/dev/null 2>&1 & _gw=$!
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
  # Never label a token; an '@' after the authority belongs to the path, and
  # userinfo may itself contain '@' — cut at the authority's LAST one.
  case "$REPO_NAME" in
    *://*@*)
      _scheme="${REPO_NAME%%://*}"
      _rest="${REPO_NAME#*://}"
      _auth="${_rest%%/*}"
      case "$_auth" in
        *@*) REPO_NAME="$_scheme://${_auth##*@}${_rest#"$_auth"}" ;;
      esac ;;
  esac
}

repo_branch() { # $1=repo root -> branch name ("HEAD" when detached)
  # symbolic-ref (not rev-parse) so a fresh repo with no commits still resolves.
  # A failed or timed-out call is discarded whole, never a partial name.
  _b="$(git_bounded -C "$1" symbolic-ref --short -q HEAD)" || _b=""
  printf '%s' "${_b:-HEAD}"
}

# ---------------------------------------------------------------------------
# Commit / line / PR counting (per session x repo, cumulative)
#
# Commits are VERIFIED against git, never parsed out of command text: the hook
# keeps the last HEAD it saw for this (session, repo) in a state file, and when
# HEAD has advanced LINEARLY since (merge-base --is-ancestor), the new commits
# authored by this machine's own git identity are added to the running total.
# Lines added/removed are the numstat sums over exactly those commits (binary
# files and merge commits contribute 0), so they share every rule below.
# The state file also keeps the SHA of every commit counted, so no commit is
# counted twice: a linear advance back onto already-seen commits (switching
# back to a branch, resetting away and back) adds nothing. A non-linear move
# (a switch to a diverged branch, a rebase, an amend) only re-baselines; a
# pull counts nothing of other people's work thanks to the author filter. A
# commit made as the session's very last action has no later tool call to be
# seen from and is missed - understated, never invented.
#
# PRs count only on proof: the tool command contains `gh pr create` AND the
# tool response carries the pull-request URL gh prints on success.
#
# Totals are emitted EVERY time, zeros included: the series' presence is what
# tells a reader "this session was measured and had none" apart from "the
# session ran an older hook that could not count".
# ---------------------------------------------------------------------------
STATE_DIR="${TMPDIR:-/tmp}/cx-codex-repo-tracker"
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null
# Opportunistic cleanup; sessions do not outlive days of inactivity.
find "$STATE_DIR" -type f -mtime +2 -delete 2>/dev/null

COMMITS=0; PRS=0; ADDED=0; REMOVED=0

as_count() { case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }

track_counts() { # $1=repo root; uses SID, EV_CMD, EV_RESP; sets COMMITS, PRS, ADDED, REMOVED
  _key="$(printf '%s|%s' "$SID" "$1" | tr -c 'A-Za-z0-9' '_' | cut -c1-200)"
  _sf="$STATE_DIR/$_key"
  _head="$(git_bounded -C "$1" rev-parse HEAD)" || _head=""
  _prev=""; _seen=""; _fresh=""; COMMITS=0; PRS=0; ADDED=0; REMOVED=0
  if [ -f "$_sf" ]; then
    _prev="$(sed -n '1p' "$_sf" 2>/dev/null)"
    # A non-number (a hand-edited or corrupt file) would abort the $((...))
    # below and the hook would exit non-zero, so each counter falls back to 0.
    COMMITS="$(as_count "$(sed -n '2p' "$_sf" 2>/dev/null)")"
    PRS="$(as_count "$(sed -n '3p' "$_sf" 2>/dev/null)")"
    # Lines 4-5 are absent in a state file a 1.1 hook wrote mid-session.
    ADDED="$(as_count "$(sed -n '4p' "$_sf" 2>/dev/null)")"
    REMOVED="$(as_count "$(sed -n '5p' "$_sf" 2>/dev/null)")"
    # Lines 6+ are the SHAs of every commit already counted, one per line.
    _seen="$(sed -n '6,$p' "$_sf" 2>/dev/null)"
  fi

  if [ -n "$_head" ] && [ -n "$_prev" ] && [ "$_head" != "$_prev" ] &&
     git_bounded -C "$1" merge-base --is-ancestor "$_prev" "$_head" >/dev/null; then
    _author="$(git_bounded -C "$1" config user.email)"
    # One log call yields the commits AND their numstat, so both share one
    # author filter and one timeout. log.mailmap=false matches --author against
    # the raw author: through .mailmap it would match an identity other than
    # user.email.
    if [ -n "$_author" ]; then
      _log="$(git_bounded -C "$1" -c log.mailmap=false log --no-color --numstat --format='C %H' --author="$_author" "$_prev..$_head")" || _log=""
    else
      _log="$(git_bounded -C "$1" -c log.mailmap=false log --no-color --numstat --format='C %H' "$_prev..$_head")" || _log=""
    fi
    # awk reads the counted SHAs, a "=" separator, then the log. A commit already
    # counted is skipped with its numstat rows, so returning to an old HEAD (a
    # branch switch back, a reset and re-reset) never counts a commit twice.
    # numstat rows are "added<TAB>removed<TAB>path"; a binary file prints "-"
    # for both and is skipped. Only the sums and new SHAs leave awk, never a
    # path. A timed-out log is dropped whole rather than counted partially.
    _res="$( { printf '%s\n' "$_seen" =; printf '%s\n' "$_log"; } | awk -F '\t' '
      !inlog { if ($0 == "=") inlog = 1; else if ($0 != "") seen[$0] = 1; next }
      /^C [0-9a-f]+$/ {
        sha = substr($0, 3); take = !(sha in seen)
        if (take) { n++; seen[sha] = 1; fresh = fresh "\n" sha }
        next
      }
      take && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { a += $1; r += $2 }
      END { printf "%d %.0f %.0f%s\n", n, a, r, fresh }')"
    _sums="$(printf '%s\n' "$_res" | sed -n '1p')"
    _new="${_sums%% *}"; _add="${_sums#* }"; _del="${_add#* }"; _add="${_add%% *}"
    case "$_new$_add$_del" in
      *[!0-9]*) ;;
      ?*)
        _fresh="$(printf '%s\n' "$_res" | sed -n '2,$p')"
        COMMITS=$((COMMITS + _new))
        ADDED=$((ADDED + _add)); REMOVED=$((REMOVED + _del)) ;;
    esac
  fi

  case "$EV_CMD" in
    *"gh pr create"*)
      case "$EV_RESP" in
        */pull/[0-9]*) PRS=$((PRS + 1)) ;;
      esac ;;
  esac

  { printf '%s\n' "${_head:-$_prev}"; printf '%s\n' "$COMMITS"; printf '%s\n' "$PRS"
    printf '%s\n' "$ADDED"; printf '%s\n' "$REMOVED"
    [ -n "$_seen" ] && printf '%s\n' "$_seen"
    [ -z "$_fresh" ] || printf '%s\n' "$_fresh"; } > "$_sf.tmp" 2>/dev/null &&
    mv -f "$_sf.tmp" "$_sf" 2>/dev/null
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
      gsub(/[[:cntrl:]]/, "", s)
      printf "%s", s
    }'
}

# ---------------------------------------------------------------------------
# Build OTLP/JSON payload
# ---------------------------------------------------------------------------
NOW_NS=$(( $(date +%s) * 1000000000 ))
SID_E="$(json_escape "$SID")"

DPS=""; BRANCH_DPS=""; COMMIT_DPS=""; PR_DPS=""; ADDED_DPS=""; REMOVED_DPS=""
count_dp() { # $1=repo name  $2=count -> echoes one datapoint
  printf '%s' "{\"attributes\":[{\"key\":\"session_id\",\"value\":{\"stringValue\":\"$SID_E\"}},{\"key\":\"repository_name\",\"value\":{\"stringValue\":\"$(json_escape "$1")\"}}],\"timeUnixNano\":\"$NOW_NS\",\"asInt\":\"$2\"}"
}
add_dp() { # $1=repo name
  DPS="${DPS:+$DPS,}$(count_dp "$1" 1)"
}
add_branch_dp() { # $1=repo name  $2=branch name
  BRANCH_DPS="${BRANCH_DPS:+$BRANCH_DPS,}{\"attributes\":[{\"key\":\"session_id\",\"value\":{\"stringValue\":\"$SID_E\"}},{\"key\":\"repository_name\",\"value\":{\"stringValue\":\"$(json_escape "$1")\"}},{\"key\":\"branch_name\",\"value\":{\"stringValue\":\"$(json_escape "$2")\"}}],\"timeUnixNano\":\"$NOW_NS\",\"asInt\":\"1\"}"
}
add_count_dps() { # $1=repo name; uses COMMITS/PRS/ADDED/REMOVED from track_counts
  COMMIT_DPS="${COMMIT_DPS:+$COMMIT_DPS,}$(count_dp "$1" "$COMMITS")"
  PR_DPS="${PR_DPS:+$PR_DPS,}$(count_dp "$1" "$PRS")"
  ADDED_DPS="${ADDED_DPS:+$ADDED_DPS,}$(count_dp "$1" "$ADDED")"
  REMOVED_DPS="${REMOVED_DPS:+$REMOVED_DPS,}$(count_dp "$1" "$REMOVED")"
}

# Dedupe by repo root AND by resolved name (two roots — e.g. a linked worktree —
# share one origin URL; emit one data point per name). Branches dedupe by
# name+branch instead, so worktrees of one repo on different branches each
# report theirs.
ROOTS=""; NAMES=""; KEYS=""
for p in "$EV_CWD" "$FP"; do
  [ -n "$p" ] || continue
  d="$p"
  [ -d "$d" ] || d="$(dirname "$p" 2>/dev/null)"
  [ -n "$d" ] && [ -d "$d" ] || continue
  root="$(repo_root "$d")" || continue
  [ -n "$root" ] || continue
  printf '%s\n' "$ROOTS" | grep -Fqx -- "$root" && continue
  ROOTS="$ROOTS$root
"
  repo_name "$root"
  [ -n "$REPO_NAME" ] || continue
  branch="$(repo_branch "$root")"
  if ! printf '%s\n' "$KEYS" | grep -Fqx -- "$REPO_NAME $branch"; then
    KEYS="$KEYS$REPO_NAME $branch
"
    add_branch_dp "$REPO_NAME" "$branch"
  fi
  printf '%s\n' "$NAMES" | grep -Fqx -- "$REPO_NAME" && continue
  NAMES="$NAMES$REPO_NAME
"
  add_dp "$REPO_NAME"
  # Commit/line/PR totals only for the repo the command RAN in - a file-path root
  # names where an edit landed, not where git state moved.
  [ "$p" = "$EV_CWD" ] && { track_counts "$root"; add_count_dps "$REPO_NAME"; }
done
[ -n "$DPS" ] || { add_dp "unknown"; add_branch_dp "unknown" "unknown"; }

RATTRS="{\"key\":\"service.name\",\"value\":{\"stringValue\":\"codex-hook\"}}"

METRICS="{\"name\":\"codex_session_repo_info\",\"gauge\":{\"dataPoints\":[$DPS]}}"
METRICS="$METRICS,{\"name\":\"codex_session_branch_info\",\"gauge\":{\"dataPoints\":[$BRANCH_DPS]}}"
[ -n "$COMMIT_DPS" ] && METRICS="$METRICS,{\"name\":\"codex_session_commits\",\"gauge\":{\"dataPoints\":[$COMMIT_DPS]}}"
[ -n "$PR_DPS" ] && METRICS="$METRICS,{\"name\":\"codex_session_prs_opened\",\"gauge\":{\"dataPoints\":[$PR_DPS]}}"
[ -n "$ADDED_DPS" ] && METRICS="$METRICS,{\"name\":\"codex_session_lines_added\",\"gauge\":{\"dataPoints\":[$ADDED_DPS]}}"
[ -n "$REMOVED_DPS" ] && METRICS="$METRICS,{\"name\":\"codex_session_lines_removed\",\"gauge\":{\"dataPoints\":[$REMOVED_DPS]}}"

PAYLOAD="{\"resourceMetrics\":[{\"resource\":{\"attributes\":[$RATTRS]},\"scopeMetrics\":[{\"scope\":{\"name\":\"repo-tracker\",\"version\":\"1.3.0\"},\"metrics\":[$METRICS]}]}]}"

# ---------------------------------------------------------------------------
# Emit (errors swallowed by design; the hook must never disturb the session).
# The config.toml endpoint ends in the signal path Codex exports to (/v1/logs);
# strip any /v1/<signal> suffix down to the ingress base, then post to
# /v1/metrics. Application/subsystem ride as CX-* headers — the same routing
# mechanism the [otel] block itself uses.
# ---------------------------------------------------------------------------
case "$EP" in
  http://*|https://*) ;;
  *) EP="https://$EP" ;;
esac
EP="${EP%/}"
case "$EP" in
  */v1/logs)    EP="${EP%/v1/logs}" ;;
  */v1/traces)  EP="${EP%/v1/traces}" ;;
  */v1/metrics) EP="${EP%/v1/metrics}" ;;
esac

# Headers go through a private temp file (-H @file, curl >= 7.55 — macOS ships
# newer), keeping the API key off the process argv where ps/EDR would see it.
# Header values are folded to one line first: a CR/LF smuggled into a config
# value must not become a header of its own.
HDRS="$(mktemp "${TMPDIR:-/tmp}/cx-hdr.XXXXXX")" || exit 0
trap 'rm -f "$EV" "$HDRS"' EXIT
chmod 600 "$HDRS" 2>/dev/null
one_line() { printf '%s' "$1" | tr -d '\r\n'; }
{
  printf 'Content-Type: application/json\n'
  printf 'Authorization: %s\n' "$(one_line "$AUTH")"
  [ -n "$APP" ] && printf 'CX-Application-Name: %s\n' "$(one_line "$APP")"
  [ -n "$SUB" ] && printf 'CX-Subsystem-Name: %s\n' "$(one_line "$SUB")"
} > "$HDRS" 2>/dev/null

curl -s -o /dev/null --max-time 5 -X POST "$EP/v1/metrics" \
  -H @"$HDRS" \
  --data-binary "$PAYLOAD" 2>/dev/null

exit 0
