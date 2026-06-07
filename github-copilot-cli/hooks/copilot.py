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

"""GitHub Copilot CLI hook → Coralogix.

A single hook script, registered on several Copilot lifecycle events and
dispatching by the event it receives on stdin:

  postToolUse           -> copilot_cli_session_repo_info  (OTLP gauge metric)
                           {session_id, repository_name, user_email}
  userPromptSubmitted   -> copilot_cli.user_prompt         (OTLP log)
  agentStop / sessionEnd -> copilot_cli.assistant_message  (OTLP log, per turn)

Prompt/response logs mirror Claude Code's native telemetry structure
(body=copilot_cli.<event>, nested event.name/session.id/user.email attributes,
resource service.name, scope com.github.copilot_cli.events).

Configuration is read from the environment — set it in the hook's `env` block
in ~/.copilot/hooks/coralogix.json (Copilot injects it), so no shell exports or
separate files are needed:

  CX_API_KEY            Coralogix Send-Your-Data API key   (required)
  CX_OTLP_ENDPOINT      Coralogix OTLP ingress base URL    (required)
  CX_APPLICATION_NAME   routing: CX-Application-Name header (optional)
  CX_SUBSYSTEM_NAME     routing: CX-Subsystem-Name header   (optional)
  CX_HOOK_USER_EMAIL    overrides user_email (default: git config user.email)
  CX_HOOK_LOG_PROMPTS   "false" redacts prompt/response text (default: true)

Zero external dependencies — Python 3 stdlib only. Fails silently; never blocks.
"""

import json
import os
import platform
import re
import struct
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen

# ---------------------------------------------------------------------------
# Configuration (from the environment / Copilot hook `env` block)
# ---------------------------------------------------------------------------

API_KEY = os.environ.get("CX_API_KEY", "")
OTLP_ENDPOINT = os.environ.get("CX_OTLP_ENDPOINT", "")
APPLICATION_NAME = os.environ.get("CX_APPLICATION_NAME", "")
SUBSYSTEM_NAME = os.environ.get("CX_SUBSYSTEM_NAME", "")
USER_EMAIL_OVERRIDE = os.environ.get("CX_HOOK_USER_EMAIL", "")
LOG_CONTENT = os.environ.get("CX_HOOK_LOG_PROMPTS", "true").lower() != "false"

SCOPE_NAME = "com.github.copilot_cli.events"
LOG_SERVICE_NAME = "copilot-cli"
METRIC_SERVICE_NAME = "copilot-cli-hook"
STATE_DIR = os.path.expanduser("~/.copilot/hooks/.coralogix-state")
SEVERITY_INFO = 9

# tool-argument keys that may carry a filesystem path (cwd is the anchor)
PATH_KEYS = ("file_path", "path", "filename", "filepath", "target_file", "filePath", "targetFile")

# Backoff for re-reading the transcript: Copilot flushes events.jsonl
# asynchronously, so a turn's assistant.message may not be on disk the instant
# agentStop/sessionEnd fires. The hook is awaited by Copilot, whose event loop
# keeps flushing while we sleep, so a few short retries catch it.
RETRY_DELAYS = (0.3, 0.6, 1.2, 2.0)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _session_id(event: dict) -> str:
    return event.get("sessionId") or event.get("session_id") or ""


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


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z"


# ---------------------------------------------------------------------------
# Minimal protobuf encoder (shared by the metric and log builders)
# ---------------------------------------------------------------------------

def _varint(value: int) -> bytes:
    parts = []
    while value > 0x7F:
        parts.append((value & 0x7F) | 0x80)
        value >>= 7
    parts.append(value & 0x7F)
    return bytes(parts)


def _tag(field_number: int, wire_type: int) -> bytes:
    return _varint((field_number << 3) | wire_type)


def _field_bytes(field_number: int, data: bytes) -> bytes:
    return _tag(field_number, 2) + _varint(len(data)) + data


def _field_varint(field_number: int, value: int) -> bytes:
    return _tag(field_number, 0) + _varint(value)


def _field_fixed64(field_number: int, value: int) -> bytes:
    return _tag(field_number, 1) + struct.pack("<Q", value)


def _encode_string(field_number: int, value: str) -> bytes:
    return _field_bytes(field_number, value.encode("utf-8"))


def _any_string(value: str) -> bytes:
    return _encode_string(1, value)  # AnyValue { string_value = 1 }


def _any_int(value: int) -> bytes:
    return _field_varint(3, value)  # AnyValue { int_value = 3 }


def _kv(key: str, any_value: bytes) -> bytes:
    return _encode_string(1, key) + _field_bytes(2, any_value)  # KeyValue


def _kv_str(key: str, value: str) -> bytes:
    return _kv(key, _any_string(value))


def _kv_int(key: str, value: int) -> bytes:
    return _kv(key, _any_int(value))


def _post(signal_path: str, payload: bytes) -> None:
    url = f"{OTLP_ENDPOINT.rstrip('/')}{signal_path}"
    headers = {
        "Content-Type": "application/x-protobuf",
        "Authorization": f"Bearer {API_KEY}",
    }
    if APPLICATION_NAME:
        headers["CX-Application-Name"] = APPLICATION_NAME
    if SUBSYSTEM_NAME:
        headers["CX-Subsystem-Name"] = SUBSYSTEM_NAME
    req = Request(url, data=payload, headers=headers, method="POST")
    try:
        with urlopen(req, timeout=5) as resp:
            resp.read()
    except (URLError, OSError):
        pass


def _resource_attrs(extra: list[bytes]) -> bytes:
    res = b"".join(_field_bytes(1, kv) for kv in extra)
    if APPLICATION_NAME:
        res += _field_bytes(1, _kv_str("cx.application.name", APPLICATION_NAME))
    if SUBSYSTEM_NAME:
        res += _field_bytes(1, _kv_str("cx.subsystem.name", SUBSYSTEM_NAME))
    return res


# ===========================================================================
# postToolUse -> repository metric
# ===========================================================================

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


def repo_paths(event: dict) -> list[str]:
    paths = []
    cwd = event.get("cwd")
    if cwd:
        paths.append(cwd)
    tool_args = event.get("toolArgs")
    if tool_args is None:
        tool_args = event.get("tool_input")
    if isinstance(tool_args, str):
        try:
            tool_args = json.loads(tool_args)
        except json.JSONDecodeError:
            tool_args = None
    if isinstance(tool_args, dict):
        for key in PATH_KEYS:
            value = tool_args.get(key)
            if isinstance(value, str) and value:
                paths.append(value)
    return paths


def resolve_repos(paths: list[str]) -> set[str]:
    repos, seen = set(), set()
    for path in paths:
        root = find_repo_root(path)
        if not root or root in seen:
            continue
        seen.add(root)
        name = get_repo_name(root)
        if name:
            repos.add(name)
    return repos


def build_metric(session_id: str, repo_name: str, user_email: str) -> bytes:
    now_ns = int(time.time() * 1_000_000_000)
    dp = b""
    for key, val in [("session_id", session_id), ("repository_name", repo_name), ("user_email", user_email)]:
        dp += _field_bytes(7, _kv_str(key, val))
    dp += _field_fixed64(3, now_ns)
    dp += _field_fixed64(6, 1)
    gauge = _field_bytes(1, dp)
    metric = _encode_string(1, "copilot_cli_session_repo_info") + _field_bytes(5, gauge)
    scope = _encode_string(1, "repo-tracker") + _encode_string(2, "1.0.0")
    scope_metrics = _field_bytes(1, scope) + _field_bytes(2, metric)
    resource = _resource_attrs([_kv_str("service.name", METRIC_SERVICE_NAME)])
    resource_metrics = _field_bytes(1, resource) + _field_bytes(2, scope_metrics)
    return _field_bytes(1, resource_metrics)


def handle_repo(event: dict) -> None:
    session_id = _session_id(event)
    if not session_id:
        return
    paths = repo_paths(event)
    if not paths:
        return
    repos = resolve_repos(paths) or {"unknown"}
    user_email = resolve_user_email()
    for repo in sorted(repos):
        _post("/v1/metrics", build_metric(session_id, repo, user_email))


# ===========================================================================
# userPromptSubmitted / agentStop / sessionEnd -> logs
# ===========================================================================

def build_log_record(body: str, attributes: list[bytes], ts_ns: int) -> bytes:
    rec = _field_fixed64(1, ts_ns)
    rec += _field_varint(2, SEVERITY_INFO)
    rec += _encode_string(3, "INFO")
    rec += _field_bytes(5, _any_string(body))
    for attr in attributes:
        rec += _field_bytes(6, attr)
    rec += _field_fixed64(11, ts_ns)
    return rec


def build_logs(records: list[bytes]) -> bytes:
    scope_logs = _field_bytes(1, _encode_string(1, SCOPE_NAME))
    for rec in records:
        scope_logs += _field_bytes(2, rec)
    resource = _resource_attrs([
        _kv_str("service.name", LOG_SERVICE_NAME),
        _kv_str("host.arch", platform.machine()),
        _kv_str("os.type", platform.system().lower()),
        _kv_str("os.version", platform.release()),
    ])
    resource_logs = _field_bytes(1, resource) + _field_bytes(2, scope_logs)
    return _field_bytes(1, resource_logs)


def emit_logs(records: list[bytes]) -> None:
    if records:
        _post("/v1/logs", build_logs(records))


def handle_user_prompt(event: dict, user_email: str) -> list[bytes]:
    prompt = event.get("prompt") or event.get("userPrompt") or ""
    if not prompt:
        return []
    attrs = [
        _kv_str("event.name", "user_prompt"),
        _kv_str("event.timestamp", iso_now()),
        _kv_str("session.id", _session_id(event)),
        _kv_int("prompt_length", len(prompt)),
    ]
    if user_email:
        attrs.append(_kv_str("user.email", user_email))
    if LOG_CONTENT:
        # NB: prompt_text, not prompt — Claude Code emits a nested prompt.id, so
        # the shared log index maps `prompt` as an object and rejects a string.
        attrs.append(_kv_str("prompt_text", prompt))
    return [build_log_record("copilot_cli.user_prompt", attrs, int(time.time() * 1e9))]


def _transcript_path(event: dict, session_id: str) -> str | None:
    path = event.get("transcriptPath") or event.get("transcript_path")
    if path and os.path.isfile(path):
        return path
    fallback = os.path.expanduser(f"~/.copilot/session-state/{session_id}/events.jsonl")
    return fallback if os.path.isfile(fallback) else None


def _emitted_path(session_id: str) -> str:
    return os.path.join(STATE_DIR, f"{session_id}.ids")


def _load_emitted(session_id: str) -> set:
    try:
        with open(_emitted_path(session_id)) as f:
            return {line.strip() for line in f if line.strip()}
    except FileNotFoundError:
        return set()


def _append_emitted(session_id: str, ids: list[str]) -> None:
    if not ids:
        return
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(_emitted_path(session_id), "a") as f:
        for i in ids:
            f.write(i + "\n")


def _scan_transcript(path: str, session_id: str, emitted: set, user_email: str):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return [], []
    records, new_ids = [], []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") != "assistant.message":
            continue
        data = obj.get("data") or {}
        content = data.get("content") or ""
        if not content:  # pure tool-call messages carry no text
            continue
        msg_id = str(data.get("messageId") or "")
        if msg_id and (msg_id in emitted or msg_id in new_ids):
            continue
        if msg_id:
            new_ids.append(msg_id)
        attrs = [
            _kv_str("event.name", "assistant_message"),
            _kv_str("event.timestamp", obj.get("timestamp") or iso_now()),
            _kv_str("session.id", session_id),
            _kv_int("content_length", len(content)),
        ]
        if data.get("model"):
            attrs.append(_kv_str("model", str(data["model"])))
        if isinstance(data.get("outputTokens"), int):
            attrs.append(_kv_int("output_tokens", data["outputTokens"]))
        if data.get("turnId"):
            attrs.append(_kv_str("turn_id", str(data["turnId"])))
        if data.get("messageId"):
            attrs.append(_kv_str("message_id", str(data["messageId"])))
        if user_email:
            attrs.append(_kv_str("user.email", user_email))
        if LOG_CONTENT:
            attrs.append(_kv_str("content", content))
        records.append(build_log_record("copilot_cli.assistant_message", attrs, int(time.time() * 1e9)))
    return records, new_ids


def handle_transcript(event: dict, user_email: str) -> list[bytes]:
    session_id = _session_id(event)
    if not session_id:
        return []
    path = _transcript_path(event, session_id)
    if not path:
        return []
    emitted = _load_emitted(session_id)
    records, new_ids = [], []
    for attempt in range(len(RETRY_DELAYS) + 1):
        records, new_ids = _scan_transcript(path, session_id, emitted, user_email)
        if records or attempt == len(RETRY_DELAYS):
            break
        time.sleep(RETRY_DELAYS[attempt])
    _append_emitted(session_id, new_ids)
    return records


# ---------------------------------------------------------------------------
# Main — dispatch by the event received on stdin
# ---------------------------------------------------------------------------

def run() -> None:
    if not API_KEY or not OTLP_ENDPOINT:
        return
    event = json.load(sys.stdin)

    if event.get("prompt") or event.get("userPrompt"):
        emit_logs(handle_user_prompt(event, resolve_user_email()))
    elif (
        event.get("transcriptPath")
        or event.get("transcript_path")
        or event.get("stopReason")
        or event.get("reason")
    ):
        emit_logs(handle_transcript(event, resolve_user_email()))
    elif event.get("toolName") or event.get("tool_name"):
        handle_repo(event)


if __name__ == "__main__":
    try:
        run()
    except Exception:
        sys.exit(0)
