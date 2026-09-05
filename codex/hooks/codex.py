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

"""Codex CLI PostToolUse hook that tracks repository names per session.

Emits an OTLP gauge metric codex_cli_session_repo_info with labels
{session_id, repository_name, user_email} on each tool use. Aggregation
into per-session cumulative counts is performed downstream.

Codex pipes the hook event JSON to stdin and runs the command with the
session cwd as its working directory. The session_id here matches the
conversation.id carried by Codex's native OTLP telemetry, so the two can
be joined downstream on that key.

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
#
# Reuses the same CX_* credentials the Codex OTel config already sources from
# .env, so the repo metric lands on the same Coralogix team/app/subsystem as
# Codex's native telemetry. Exits silently if endpoint or key are unset.
# ---------------------------------------------------------------------------

API_KEY = os.environ.get("CX_API_KEY", "")
OTLP_ENDPOINT = os.environ.get("CX_OTLP_ENDPOINT", "")
APPLICATION_NAME = os.environ.get("CX_APPLICATION_NAME", "")
SUBSYSTEM_NAME = os.environ.get("CX_SUBSYSTEM_NAME", "")

# Codex does not carry the user identity in the hook payload; allow an explicit
# override and otherwise fall back to the local git identity.
USER_EMAIL_OVERRIDE = os.environ.get("CX_HOOK_USER_EMAIL", "")

# tool_input keys that may carry a filesystem path across Codex's tool set
# (Bash, apply_patch, MCP tools). cwd is always present and is the anchor.
PATH_KEYS = ("file_path", "path", "filename", "filepath", "target_file")


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


def resolve_user_email() -> str:
    if USER_EMAIL_OVERRIDE:
        return USER_EMAIL_OVERRIDE
    try:
        result = subprocess.run(
            ["git", "config", "user.email"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return ""


def extract_paths(event: dict) -> list[str]:
    paths = []
    cwd = event.get("cwd")
    if cwd:
        paths.append(cwd)

    tool_input = event.get("tool_input") or {}
    if isinstance(tool_input, dict):
        for key in PATH_KEYS:
            value = tool_input.get(key)
            if isinstance(value, str) and value:
                paths.append(value)

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

    metric = _encode_string(1, "codex_cli_session_repo_info")
    metric += _field_bytes(5, gauge)

    scope = _encode_string(1, "repo-tracker") + _encode_string(2, "1.0.0")
    scope_metrics = _field_bytes(1, scope) + _field_bytes(2, metric)

    resource = _field_bytes(1, _encode_kv("service.name", "codex-cli-hook"))
    if APPLICATION_NAME:
        resource += _field_bytes(1, _encode_kv("cx.application.name", APPLICATION_NAME))
    if SUBSYSTEM_NAME:
        resource += _field_bytes(1, _encode_kv("cx.subsystem.name", SUBSYSTEM_NAME))

    resource_metrics = _field_bytes(1, resource) + _field_bytes(2, scope_metrics)
    return _field_bytes(1, resource_metrics)


# ---------------------------------------------------------------------------
# OTLP metric emission
# ---------------------------------------------------------------------------

def emit_metric(session_id: str, repo_name: str, user_email: str) -> None:
    data = build_otlp_protobuf(session_id, repo_name, user_email)
    url = f"{OTLP_ENDPOINT.rstrip('/')}/v1/metrics"

    headers = {
        "Content-Type": "application/x-protobuf",
        "Authorization": f"Bearer {API_KEY}",
    }
    if APPLICATION_NAME:
        headers["CX-Application-Name"] = APPLICATION_NAME
    if SUBSYSTEM_NAME:
        headers["CX-Subsystem-Name"] = SUBSYSTEM_NAME

    req = Request(url, data=data, headers=headers, method="POST")
    try:
        with urlopen(req, timeout=5) as resp:
            resp.read()
    except (URLError, OSError):
        pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    if not API_KEY or not OTLP_ENDPOINT:
        return

    event = json.load(sys.stdin)
    session_id = event.get("session_id")
    if not session_id:
        return

    paths = extract_paths(event)
    if not paths:
        return

    repos = resolve_repos(paths) or {"unknown"}
    user_email = resolve_user_email()

    for repo in sorted(repos):
        emit_metric(session_id, repo, user_email)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
