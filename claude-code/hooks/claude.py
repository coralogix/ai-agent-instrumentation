#!/usr/bin/env python3
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

"""Claude Code PostToolUse hook that tracks repository names per session.

Emits an OTLP gauge metric claude_code_session_repo_info with labels
{session_id, repository_name, user_email}. The gauge value is the cumulative
tool-use count for that repo in the session, enabling proportional cost
splitting across repos. Zero external dependencies — Python 3 stdlib only.
"""

import json
import os
import re
import subprocess
import sys
import time
from urllib.request import Request, urlopen
from urllib.error import URLError

# ---------------------------------------------------------------------------
# Configuration (env vars)
# ---------------------------------------------------------------------------

def _resolve_api_key() -> str:
    """Resolve API key: CX_HOOK_API_KEY > OTEL_EXPORTER_OTLP_HEADERS > empty."""
    key = os.environ.get("CX_HOOK_API_KEY", "")
    if key:
        return key
    # Fallback: extract Bearer token from native OTLP headers so the hook
    # automatically lands on the same Coralogix team as native Claude Code metrics.
    headers = os.environ.get("OTEL_EXPORTER_OTLP_HEADERS", "")
    if "Bearer " in headers:
        return headers.split("Bearer ", 1)[1].strip()
    return ""


def _resolve_endpoint() -> str:
    """Resolve endpoint: CX_HOOK_OTLP_ENDPOINT > OTEL_EXPORTER_OTLP_ENDPOINT > default."""
    endpoint = os.environ.get("CX_HOOK_OTLP_ENDPOINT", "")
    if endpoint:
        return endpoint
    return os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "https://ingress.eu2.coralogix.com")


API_KEY = _resolve_api_key()
OTLP_ENDPOINT = _resolve_endpoint()
APPLICATION_NAME = os.environ.get("CX_HOOK_APPLICATION_NAME", "claude-code")
SUBSYSTEM_NAME = os.environ.get("CX_HOOK_SUBSYSTEM_NAME", "ai-agent")
DEBUG = os.environ.get("CX_HOOK_DEBUG", "") == "1"

STATE_DIR = os.path.join(os.path.expanduser("~"), ".claude-hook-state")

# Tools whose tool_input contains a file_path field
FILE_PATH_TOOLS = {"Read", "Edit", "Write", "NotebookEdit"}
# Tools whose tool_input contains an optional path field (search root)
SEARCH_PATH_TOOLS = {"Glob", "Grep"}


def debug(msg: str) -> None:
    if DEBUG:
        print(f"[repo-tracker] {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Repo detection
# ---------------------------------------------------------------------------

def find_repo_root(path: str) -> str | None:
    """Use git to find the repository root for a given path."""
    directory = path if os.path.isdir(path) else os.path.dirname(path)
    if not directory or not os.path.isdir(directory):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def get_repo_name(repo_root: str) -> str:
    """Extract owner/repo from the git remote URL, or fall back to basename."""
    try:
        result = subprocess.run(
            ["git", "-C", repo_root, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            url = result.stdout.strip()
            # Handles both SSH (git@host:owner/repo.git) and HTTPS (https://host/owner/repo.git)
            match = re.search(r"[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
            if match:
                return match.group(1)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    # Fallback: directory basename
    return os.path.basename(repo_root)


def extract_paths(event: dict) -> list[str]:
    """Extract file/directory paths from the hook event to check for repos."""
    paths = []

    # cwd is always present
    cwd = event.get("cwd")
    if cwd:
        paths.append(cwd)

    tool_name = event.get("tool_name", "")
    tool_input = event.get("tool_input") or {}

    if tool_name in FILE_PATH_TOOLS:
        fp = tool_input.get("file_path")
        if fp:
            paths.append(fp)
    elif tool_name in SEARCH_PATH_TOOLS:
        sp = tool_input.get("path")
        if sp:
            paths.append(sp)

    return paths


def resolve_repos(paths: list[str]) -> set[str]:
    """Resolve a list of file/dir paths to a set of repo names."""
    repos = set()
    seen_roots = set()

    for path in paths:
        root = find_repo_root(path)
        if not root or root in seen_roots:
            continue
        seen_roots.add(root)
        name = get_repo_name(root)
        if name:
            repos.add(name)

    return repos


# ---------------------------------------------------------------------------
# Session state (deduplication)
# ---------------------------------------------------------------------------

def load_repo_counts(session_id: str) -> dict[str, int]:
    """Load the repo → tool-use-count mapping for this session."""
    state_file = os.path.join(STATE_DIR, f"{session_id}.repos")
    try:
        with open(state_file) as f:
            data = json.load(f)
            if isinstance(data, dict):
                return data
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    # Migrate from legacy line-per-repo format
    try:
        with open(state_file) as f:
            lines = [line.strip() for line in f if line.strip()]
            if lines:
                return {repo: 1 for repo in lines}
    except FileNotFoundError:
        pass
    return {}


def save_repo_counts(session_id: str, counts: dict[str, int]) -> None:
    """Write the full repo → count mapping atomically."""
    os.makedirs(STATE_DIR, exist_ok=True)
    state_file = os.path.join(STATE_DIR, f"{session_id}.repos")
    with open(state_file, "w") as f:
        json.dump(counts, f)


def maybe_prune_state() -> None:
    """Probabilistic cleanup: ~1% chance per invocation, remove files older than 24h."""
    import random
    if random.randint(1, 100) != 1:
        return
    try:
        cutoff = time.time() - 86400
        for name in os.listdir(STATE_DIR):
            filepath = os.path.join(STATE_DIR, name)
            if os.path.isfile(filepath) and os.path.getmtime(filepath) < cutoff:
                os.remove(filepath)
                debug(f"Pruned stale state file: {name}")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Minimal protobuf encoder (no external dependencies)
#
# Protobuf wire format: each field is (field_number << 3 | wire_type) as varint,
# followed by the value. We only need wire types 0 (varint), 1 (fixed64), and
# 2 (length-delimited).
# ---------------------------------------------------------------------------

import struct


def _varint(value: int) -> bytes:
    """Encode an unsigned integer as a protobuf varint."""
    parts = []
    while value > 0x7F:
        parts.append((value & 0x7F) | 0x80)
        value >>= 7
    parts.append(value & 0x7F)
    return bytes(parts)


def _field_bytes(field_number: int, data: bytes) -> bytes:
    """Encode a length-delimited protobuf field (wire type 2)."""
    tag = _varint((field_number << 3) | 2)
    return tag + _varint(len(data)) + data


def _field_varint(field_number: int, value: int) -> bytes:
    """Encode a varint protobuf field (wire type 0)."""
    tag = _varint((field_number << 3) | 0)
    return tag + _varint(value)


def _field_fixed64(field_number: int, value: int) -> bytes:
    """Encode a fixed64 protobuf field (wire type 1)."""
    tag = _varint((field_number << 3) | 1)
    return tag + struct.pack("<Q", value)


def _encode_string(field_number: int, value: str) -> bytes:
    """Encode a string protobuf field."""
    return _field_bytes(field_number, value.encode("utf-8"))


def _encode_kv(key: str, string_value: str) -> bytes:
    """Encode an opentelemetry.proto.common.v1.KeyValue."""
    # KeyValue: field 1 = key (string), field 2 = AnyValue
    # AnyValue: field 1 = string_value
    any_value = _encode_string(1, string_value)
    return _encode_string(1, key) + _field_bytes(2, any_value)


def build_otlp_protobuf(
    session_id: str, repo_name: str, user_email: str, count: int = 1,
) -> bytes:
    """Build an ExportMetricsServiceRequest protobuf for a single gauge data point."""
    now_ns = int(time.time() * 1_000_000_000)

    # --- NumberDataPoint (field 7 = attributes, field 3 = time_unix_nano, field 6 = as_int) ---
    dp = b""
    for key, val in [("session_id", session_id), ("repository_name", repo_name), ("user_email", user_email)]:
        dp += _field_bytes(7, _encode_kv(key, val))    # attributes
    dp += _field_fixed64(3, now_ns)                     # time_unix_nano
    dp += _field_fixed64(6, count)                      # as_int = tool-use count

    # --- Gauge (field 1 = data_points) ---
    gauge = _field_bytes(1, dp)

    # --- Metric (field 1 = name, field 5 = gauge) ---
    metric = _encode_string(1, "claude_code_session_repo_info")
    metric += _field_bytes(5, gauge)

    # --- InstrumentationScope (field 1 = name, field 2 = version) ---
    scope = _encode_string(1, "repo-tracker") + _encode_string(2, "1.0.0")

    # --- ScopeMetrics (field 1 = scope, field 2 = metrics) ---
    scope_metrics = _field_bytes(1, scope) + _field_bytes(2, metric)

    # --- Resource (field 1 = attributes) ---
    resource = b""
    for key, val in [("service.name", "claude-code-hook"),
                     ("cx.application.name", APPLICATION_NAME),
                     ("cx.subsystem.name", SUBSYSTEM_NAME)]:
        resource += _field_bytes(1, _encode_kv(key, val))

    # --- ResourceMetrics (field 1 = resource, field 2 = scope_metrics) ---
    resource_metrics = _field_bytes(1, resource) + _field_bytes(2, scope_metrics)

    # --- ExportMetricsServiceRequest (field 1 = resource_metrics) ---
    return _field_bytes(1, resource_metrics)


# ---------------------------------------------------------------------------
# OTLP metric emission
# ---------------------------------------------------------------------------

def emit_metric(session_id: str, repo_name: str, user_email: str, count: int = 1) -> None:
    """POST the OTLP protobuf gauge metric to the Coralogix endpoint."""
    data = build_otlp_protobuf(session_id, repo_name, user_email, count)
    url = f"{OTLP_ENDPOINT.rstrip('/')}/v1/metrics"

    debug(f"POST {url} ({len(data)} bytes protobuf)")
    debug(f"  session_id={session_id} repository_name={repo_name} user_email={user_email} count={count}")

    req = Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/x-protobuf",
            "Authorization": f"Bearer {API_KEY}",
        },
        method="POST",
    )
    try:
        with urlopen(req, timeout=5) as resp:
            debug(f"Response: {resp.status}")
    except (URLError, OSError) as e:
        debug(f"Export failed (non-blocking): {e}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    _dbg = lambda msg: print(f"[repo-tracker-DBG] {msg}", file=sys.stderr)

    _dbg(f"Hook invoked. API_KEY={'set' if API_KEY else 'EMPTY'}, ENDPOINT={OTLP_ENDPOINT}")
    debug(f"Hook invoked. API_KEY={'set' if API_KEY else 'EMPTY'}, ENDPOINT={OTLP_ENDPOINT}")

    # Guard: no API key → nothing to do
    if not API_KEY:
        _dbg("CX_HOOK_API_KEY not set, exiting")
        debug("CX_HOOK_API_KEY not set, exiting")
        return

    event = json.load(sys.stdin)
    session_id = event.get("session_id")
    _dbg(f"Event: tool={event.get('tool_name')}, session={session_id}, cwd={event.get('cwd')}")
    debug(f"Event received: tool_name={event.get('tool_name')}, session_id={session_id}, cwd={event.get('cwd')}")
    if not session_id:
        _dbg("No session_id in event, exiting")
        debug("No session_id in event, exiting")
        return

    # Extract paths and resolve repos
    paths = extract_paths(event)
    _dbg(f"Paths: {paths}")
    debug(f"Extracted paths: {paths}")
    if not paths:
        _dbg("No paths to check, exiting")
        debug("No paths to check, exiting")
        return

    repos = resolve_repos(paths)
    _dbg(f"Repos: {repos}")
    debug(f"Resolved repos: {repos}")
    if not repos:
        _dbg("No git repos found, using 'unknown'")
        debug("No git repos found, using 'unknown'")
        repos = {"unknown"}

    # Load cumulative tool-use counts and increment for repos touched this invocation
    counts = load_repo_counts(session_id)
    for repo in repos:
        counts[repo] = counts.get(repo, 0) + 1
    _dbg(f"Counts: {counts}")
    debug(f"Updated counts: {counts}")

    # Always re-emit for ALL known repos (keeps the gauge alive in Prometheus —
    # a gauge emitted once via OTLP push becomes stale after ~5 min).
    # The gauge value = cumulative tool-use count, used as a weight for cost splitting.
    user_email = event.get("user_email", "")
    for repo in sorted(counts):
        _dbg(f"Emitting: repo={repo}, count={counts[repo]}, user={user_email}")
        debug(f"Emit: repo={repo}, count={counts[repo]}, user_email={user_email}, session={session_id}")
        emit_metric(session_id, repo, user_email, counts[repo])

    save_repo_counts(session_id, counts)
    _dbg("Done.")
    debug("State saved. Done.")

    # Occasional state cleanup
    maybe_prune_state()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        if DEBUG:
            print(f"[repo-tracker] Fatal error: {e}", file=sys.stderr)
        sys.exit(0)  # Never block Claude Code
