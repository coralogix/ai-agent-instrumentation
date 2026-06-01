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
{session_id, repository_name, user_email} on each tool use. Aggregation
into per-session cumulative counts is performed downstream.
Zero external dependencies — Python 3 stdlib only.
"""

import json
import os
import re
import struct
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def _resolve_api_key() -> str:
    key = os.environ.get("CX_HOOK_API_KEY", "")
    if key:
        return key
    headers = os.environ.get("OTEL_EXPORTER_OTLP_HEADERS", "")
    if "Bearer " in headers:
        return headers.split("Bearer ", 1)[1].strip()
    return ""


def _resolve_endpoint() -> str:
    endpoint = os.environ.get("CX_HOOK_OTLP_ENDPOINT", "")
    if endpoint:
        return endpoint
    return os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "https://ingress.eu2.coralogix.com")


API_KEY = _resolve_api_key()
OTLP_ENDPOINT = _resolve_endpoint()
APPLICATION_NAME = os.environ.get("CX_HOOK_APPLICATION_NAME", "claude-code")
SUBSYSTEM_NAME = os.environ.get("CX_HOOK_SUBSYSTEM_NAME", "ai-agent")

FILE_PATH_TOOLS = {"Read", "Edit", "Write", "NotebookEdit"}
SEARCH_PATH_TOOLS = {"Glob", "Grep"}


# ---------------------------------------------------------------------------
# Repo detection
# ---------------------------------------------------------------------------

def find_repo_root(path: str) -> str | None:
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
    try:
        result = subprocess.run(
            ["git", "-C", repo_root, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            url = result.stdout.strip()
            match = re.search(r"[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
            if match:
                return match.group(1)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return os.path.basename(repo_root)


def extract_paths(event: dict) -> list[str]:
    paths = []
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
# Minimal protobuf encoder
# ---------------------------------------------------------------------------

def _varint(value: int) -> bytes:
    parts = []
    while value > 0x7F:
        parts.append((value & 0x7F) | 0x80)
        value >>= 7
    parts.append(value & 0x7F)
    return bytes(parts)


def _field_bytes(field_number: int, data: bytes) -> bytes:
    tag = _varint((field_number << 3) | 2)
    return tag + _varint(len(data)) + data


def _field_fixed64(field_number: int, value: int) -> bytes:
    tag = _varint((field_number << 3) | 1)
    return tag + struct.pack("<Q", value)


def _encode_string(field_number: int, value: str) -> bytes:
    return _field_bytes(field_number, value.encode("utf-8"))


def _encode_kv(key: str, string_value: str) -> bytes:
    any_value = _encode_string(1, string_value)
    return _encode_string(1, key) + _field_bytes(2, any_value)


def build_otlp_protobuf(session_id: str, repo_name: str, user_email: str) -> bytes:
    now_ns = int(time.time() * 1_000_000_000)

    dp = b""
    for key, val in [("session_id", session_id), ("repository_name", repo_name), ("user_email", user_email)]:
        dp += _field_bytes(7, _encode_kv(key, val))
    dp += _field_fixed64(3, now_ns)
    dp += _field_fixed64(6, 1)

    gauge = _field_bytes(1, dp)

    metric = _encode_string(1, "claude_code_session_repo_info")
    metric += _field_bytes(5, gauge)

    scope = _encode_string(1, "repo-tracker") + _encode_string(2, "1.0.0")
    scope_metrics = _field_bytes(1, scope) + _field_bytes(2, metric)

    resource = b""
    for key, val in [("service.name", "claude-code-hook"),
                     ("cx.application.name", APPLICATION_NAME),
                     ("cx.subsystem.name", SUBSYSTEM_NAME)]:
        resource += _field_bytes(1, _encode_kv(key, val))

    resource_metrics = _field_bytes(1, resource) + _field_bytes(2, scope_metrics)
    return _field_bytes(1, resource_metrics)


# ---------------------------------------------------------------------------
# OTLP metric emission
# ---------------------------------------------------------------------------

def emit_metric(session_id: str, repo_name: str, user_email: str) -> None:
    data = build_otlp_protobuf(session_id, repo_name, user_email)
    url = f"{OTLP_ENDPOINT.rstrip('/')}/v1/metrics"

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
            resp.read()
    except (URLError, OSError):
        pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    if not API_KEY:
        return

    event = json.load(sys.stdin)
    session_id = event.get("session_id")
    if not session_id:
        return

    paths = extract_paths(event)
    if not paths:
        return

    repos = resolve_repos(paths) or {"unknown"}
    user_email = event.get("user_email", "")

    for repo in sorted(repos):
        emit_metric(session_id, repo, user_email)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
