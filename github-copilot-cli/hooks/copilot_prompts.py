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

"""GitHub Copilot CLI hook that ships prompts and responses to Coralogix.

Copilot CLI emits no telemetry of its own, so this hook reconstructs the
conversation from its lifecycle hooks and exports it as OTLP log records,
mirroring the structure of Claude Code's native telemetry:

  body        copilot_cli.<event.name>
  attributes  event.name, event.timestamp, session.id, user.email, ...
  resource    service.name=copilot-cli, host.arch, os.type, os.version
  scope       com.github.copilot_cli.events

Two events are handled (register this hook on both):
  * userPromptSubmitted -> copilot_cli.user_prompt      (the prompt text)
  * agentStop           -> copilot_cli.assistant_message (responses for the
                           just-finished turn, read from the session
                           transcript referenced by transcriptPath)

Prompt/response text is included by default; set CX_HOOK_LOG_PROMPTS=false to
emit only metadata (lengths), mirroring Claude Code's OTEL_LOG_USER_PROMPTS
gate. Zero external dependencies — Python 3 stdlib only.
"""

import json
import os
import platform
import struct
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

API_KEY = os.environ.get("CX_API_KEY", "")
OTLP_ENDPOINT = os.environ.get("CX_OTLP_ENDPOINT", "")
APPLICATION_NAME = os.environ.get("CX_APPLICATION_NAME", "")
SUBSYSTEM_NAME = os.environ.get("CX_SUBSYSTEM_NAME", "")
USER_EMAIL_OVERRIDE = os.environ.get("CX_HOOK_USER_EMAIL", "")
# Include prompt/response text by default (this hook exists to capture it);
# set to false to redact content and keep only lengths/metadata.
LOG_CONTENT = os.environ.get("CX_HOOK_LOG_PROMPTS", "true").lower() != "false"

SCOPE_NAME = "com.github.copilot_cli.events"
SERVICE_NAME = "copilot-cli"
STATE_DIR = os.path.expanduser("~/.copilot/hooks/.coralogix-state")
SEVERITY_INFO = 9


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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
# Minimal protobuf encoder (OTLP logs)
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
    # AnyValue { string_value = 1 }
    return _encode_string(1, value)


def _any_int(value: int) -> bytes:
    # AnyValue { int_value = 3 }
    return _field_varint(3, value)


def _kv(key: str, any_value: bytes) -> bytes:
    # KeyValue { key = 1, value (AnyValue) = 2 }
    return _encode_string(1, key) + _field_bytes(2, any_value)


def _kv_str(key: str, value: str) -> bytes:
    return _kv(key, _any_string(value))


def _kv_int(key: str, value: int) -> bytes:
    return _kv(key, _any_int(value))


def build_log_record(body: str, attributes: list[bytes], ts_ns: int) -> bytes:
    # LogRecord: time(1, fixed64), severity_number(2, varint),
    # severity_text(3), body(5, AnyValue), attributes(6), observed(11, fixed64)
    rec = _field_fixed64(1, ts_ns)
    rec += _field_varint(2, SEVERITY_INFO)
    rec += _encode_string(3, "INFO")
    rec += _field_bytes(5, _any_string(body))
    for attr in attributes:
        rec += _field_bytes(6, attr)
    rec += _field_fixed64(11, ts_ns)
    return rec


def build_logs_payload(records: list[bytes]) -> bytes:
    # ScopeLogs: scope(1, InstrumentationScope{name=1}), log_records(2)
    scope = _encode_string(1, SCOPE_NAME)
    scope_logs = _field_bytes(1, scope)
    for rec in records:
        scope_logs += _field_bytes(2, rec)

    # Resource: attributes(1)
    resource = _field_bytes(1, _kv_str("service.name", SERVICE_NAME))
    resource += _field_bytes(1, _kv_str("host.arch", platform.machine()))
    resource += _field_bytes(1, _kv_str("os.type", platform.system().lower()))
    resource += _field_bytes(1, _kv_str("os.version", platform.release()))
    if APPLICATION_NAME:
        resource += _field_bytes(1, _kv_str("cx.application.name", APPLICATION_NAME))
    if SUBSYSTEM_NAME:
        resource += _field_bytes(1, _kv_str("cx.subsystem.name", SUBSYSTEM_NAME))

    # ResourceLogs: resource(1), scope_logs(2)
    resource_logs = _field_bytes(1, resource) + _field_bytes(2, scope_logs)
    # LogsData: resource_logs(1)
    return _field_bytes(1, resource_logs)


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

def emit_logs(records: list[bytes]) -> None:
    if not records:
        return
    data = build_logs_payload(records)
    url = f"{OTLP_ENDPOINT.rstrip('/')}/v1/logs"
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
# Event handling
# ---------------------------------------------------------------------------

def _session_id(event: dict) -> str:
    return event.get("sessionId") or event.get("session_id") or ""


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
        # NB: not "prompt" — Claude Code emits a nested prompt.id, so the log
        # index maps `prompt` as an object; a flat string there is rejected.
        attrs.append(_kv_str("prompt_text", prompt))
    return [build_log_record("copilot_cli.user_prompt", attrs, int(time.time() * 1e9))]


def _transcript_path(event: dict, session_id: str) -> str | None:
    path = event.get("transcriptPath") or event.get("transcript_path")
    if path and os.path.isfile(path):
        return path
    # Fall back to the session-state events log.
    fallback = os.path.expanduser(
        f"~/.copilot/session-state/{session_id}/events.jsonl"
    )
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


# Backoff schedule (seconds) for re-reading the transcript: Copilot flushes
# events.jsonl asynchronously, so a turn's assistant.message may not be on disk
# the instant agentStop/sessionEnd fires. The hook is awaited by Copilot, whose
# event loop keeps flushing while we sleep, so a few short retries usually catch
# the message. We stop as soon as something new appears.
_RETRY_DELAYS = (0.3, 0.6, 1.2, 2.0)


def _scan_transcript(path: str, session_id: str, emitted: set, user_email: str):
    """Read the transcript once; return (records, new_ids) for unemitted
    content-bearing assistant.message entries."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            all_lines = f.readlines()
    except OSError:
        return [], []

    records, new_ids = [], []
    for line in all_lines:
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
        records.append(
            build_log_record("copilot_cli.assistant_message", attrs, int(time.time() * 1e9))
        )
    return records, new_ids


def handle_transcript(event: dict, user_email: str) -> list[bytes]:
    """Emit assistant responses from the session transcript.

    Fires on agentStop and sessionEnd. Re-reads the whole transcript and
    deduplicates by messageId (persisted per session). Because events.jsonl is
    flushed asynchronously, we retry the read with backoff until a new message
    shows up (or the schedule is exhausted).
    """
    session_id = _session_id(event)
    if not session_id:
        return []
    path = _transcript_path(event, session_id)
    if not path:
        return []

    emitted = _load_emitted(session_id)
    records, new_ids = [], []
    for attempt in range(len(_RETRY_DELAYS) + 1):
        records, new_ids = _scan_transcript(path, session_id, emitted, user_email)
        if records or attempt == len(_RETRY_DELAYS):
            break
        time.sleep(_RETRY_DELAYS[attempt])

    _append_emitted(session_id, new_ids)
    return records


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run() -> None:
    if not API_KEY or not OTLP_ENDPOINT:
        return

    event = json.load(sys.stdin)
    user_email = resolve_user_email()

    # Dispatch by the fields present (camelCase or snake_case payloads).
    # agentStop carries stopReason+transcriptPath; sessionEnd carries reason
    # (no transcriptPath -> we fall back to the session-state events.jsonl).
    if event.get("prompt") or event.get("userPrompt"):
        records = handle_user_prompt(event, user_email)
    elif (
        event.get("transcriptPath")
        or event.get("transcript_path")
        or event.get("stopReason")
        or event.get("reason")
        or event.get("hook_event_name") in ("Stop", "agentStop", "SessionEnd", "sessionEnd")
        or event.get("hookEventName") in ("Stop", "agentStop", "SessionEnd", "sessionEnd")
    ):
        records = handle_transcript(event, user_email)
    else:
        records = []

    emit_logs(records)


if __name__ == "__main__":
    try:
        run()
    except Exception:
        sys.exit(0)
