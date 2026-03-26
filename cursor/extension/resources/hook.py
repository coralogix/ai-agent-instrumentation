#!/usr/bin/env python3
# cursor-coralogix-hook  v2.0.0
#
# Cursor calls this script for every agent lifecycle event, passing a JSON
# payload on stdin. We convert the event to an OTLP trace span and send it
# to the Coralogix OTLP endpoint via the native OTel SDK.
#
# Required env vars:
#   CX_API_KEY          - Coralogix Send-Your-Data API key
#   CX_OTLP_ENDPOINT    - e.g. https://ingress.eu2.coralogix.com
#   CX_APPLICATION_NAME - e.g. cursor  (default: cursor)
#   CX_SUBSYSTEM_NAME   - e.g. ai-agent (default: ai-agent)

import contextlib
import hashlib
import json
import os
import sys
import time
from pathlib import Path

try:
    import fcntl as _fcntl
    def _lock(f):   _fcntl.flock(f, _fcntl.LOCK_EX)
    def _unlock(f): _fcntl.flock(f, _fcntl.LOCK_UN)
except ImportError:
    try:
        import msvcrt as _msvcrt
        def _lock(f):   _msvcrt.locking(f.fileno(), _msvcrt.LK_LOCK, 1)
        def _unlock(f): _msvcrt.locking(f.fileno(), _msvcrt.LK_UNLCK, 1)
    except ImportError:
        def _lock(_):   pass
        def _unlock(_): pass

try:
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags, Status, StatusCode
except ImportError:
    sys.exit(
        "cursor-coralogix-hook: missing dependency — run:\n"
        "  pip install opentelemetry-sdk opentelemetry-exporter-otlp-proto-http"
    )

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CX_API_KEY          = os.environ.get("CX_API_KEY", "")
CX_OTLP_ENDPOINT    = os.environ.get("CX_OTLP_ENDPOINT", "").rstrip("/")
CX_APPLICATION_NAME = os.environ.get("CX_APPLICATION_NAME", "cursor")
CX_SUBSYSTEM_NAME   = os.environ.get("CX_SUBSYSTEM_NAME", "ai-agent")
MASK_PROMPTS        = os.environ.get("CURSOR_MASK_PROMPTS", "").lower() == "true"
OMIT_PRE_TOOL_USE   = os.environ.get("CURSOR_OMIT_PRE_TOOL_USE_SPANS", "").lower() == "true"
DEBUG               = os.environ.get("CX_OTLP_DEBUG", "").lower() == "true"

_SERVICE_VERSION = "2.0.0"

# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

_STATE_DIR = Path.home() / ".cursor-hook-state"


def _state_file(conv_id):
    h = hashlib.sha256(conv_id.encode()).hexdigest()
    return _STATE_DIR / (h[:16] + ".json")


def load_state(conv_id):
    try:
        return json.loads(_state_file(conv_id).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def save_state(conv_id, state):
    f = _state_file(conv_id)
    f.write_text(json.dumps(state))
    f.chmod(0o600)


def delete_state(conv_id):
    try:
        _state_file(conv_id).unlink()
    except FileNotFoundError:
        pass


def prune_old_states():
    cutoff = time.time() - 86400
    try:
        for f in _STATE_DIR.glob("*.json"):
            if f.stat().st_mtime < cutoff:
                f.unlink()
    except Exception:
        pass


@contextlib.contextmanager
def _state_lock(conv_id):
    """Exclusive per-conversation lock for the load-modify-save cycle.

    Cursor spawns a new process for every hook event, so two events for the
    same conversation can race to read-modify-write the same state file.  The
    lock is held only for the in-memory state update; it is released before the
    (slow) network export so concurrent events are not blocked during the HTTP
    call to Coralogix.

    If locking is unavailable (no fcntl/msvcrt) the no-op fallback above means
    we skip protection rather than crash — acceptable because races are rare and
    the worst outcome is a lost timing sample, not data corruption.
    """
    _STATE_DIR.mkdir(mode=0o700, exist_ok=True)
    lock_path = _STATE_DIR / (_state_file(conv_id).stem + ".lock")
    with open(lock_path, "w") as lf:
        try:
            _lock(lf)
            yield
        finally:
            _unlock(lf)


# ---------------------------------------------------------------------------
# Conversation ID
# ---------------------------------------------------------------------------

def conversation_id(event):
    return (event.get("conversation_id") or event.get("session_id") or "").strip()


def session_id(event):
    return (event.get("session_id") or "").strip()


# ---------------------------------------------------------------------------
# State update (tracks per-operation start times for elapsed-ms fallback)
# ---------------------------------------------------------------------------

def update_state(event, state):
    now  = time.time_ns()
    name = event.get("hook_event_name", "")

    if name == "preToolUse":
        state.setdefault("tool_starts", {})[event.get("tool_name", "")] = now
    elif name in ("postToolUse", "postToolUseFailure"):
        state.get("tool_starts", {}).pop(event.get("tool_name", ""), None)
    elif name == "beforeShellExecution":
        state.setdefault("shell_starts", {})[event.get("command", "")] = now
    elif name == "afterShellExecution":
        state.get("shell_starts", {}).pop(event.get("command", ""), None)
    elif name == "beforeMCPExecution":
        key = event.get("tool_name") or "{}:{}".format(event.get("mcp_server", ""), event.get("mcp_tool", ""))
        state.setdefault("mcp_starts", {})[key] = now
    elif name == "afterMCPExecution":
        key = event.get("tool_name") or "{}:{}".format(event.get("mcp_server", ""), event.get("mcp_tool", ""))
        state.get("mcp_starts", {}).pop(key, None)


# ---------------------------------------------------------------------------
# Build span attributes
# ---------------------------------------------------------------------------

def _truncate(s, max_len):
    return s[:max_len] if s else s


def _raw_str(v):
    if isinstance(v, str):
        return v
    return json.dumps(v)


def _elapsed_ms(start_ns):
    return (time.time_ns() - start_ns) // 1_000_000


def build_attributes(event, state):
    attrs = {}

    def add(key, value):
        if value is not None and value != "":
            attrs[key] = str(value)

    def add_int(key, value):
        attrs[key] = int(value)

    name = event.get("hook_event_name", "")

    # Core identity
    add("cursor.conversation_id", conversation_id(event))
    add("cursor.generation_id",   event.get("generation_id"))
    add("cursor.user_email",      event.get("user_email"))
    add("cursor.cursor_version",  event.get("cursor_version"))

    # GenAI semantic conventions
    add("gen_ai.system",        "cursor")
    add("gen_ai.request.model", event.get("model"))

    if name == "beforeSubmitPrompt":
        add("gen_ai.operation.name", "chat")
        prompt = event.get("prompt", "")
        if prompt:
            add("cursor.prompt", "[MASKED]" if MASK_PROMPTS else _truncate(prompt, 4000))

    elif name in ("afterAgentResponse", "afterAgentThought"):
        add("gen_ai.operation.name", "chat")
        text = event.get("text", "")
        if text:
            add("cursor.text", "[MASKED]" if MASK_PROMPTS else _truncate(text, 4000))
        if event.get("duration_ms") is not None:
            add_int("cursor.duration_ms", event["duration_ms"])

    elif name == "preToolUse":
        add("gen_ai.operation.name", "tool_call")
        add("gen_ai.tool.name",      event.get("tool_name"))
        add("cursor.tool_use_id",    event.get("tool_use_id"))
        add("cursor.agent_message",  _truncate(event.get("agent_message", ""), 1000))
        if event.get("tool_input") is not None:
            add("cursor.tool_input", _truncate(_raw_str(event["tool_input"]), 2000))

    elif name == "postToolUse":
        add("gen_ai.operation.name", "tool_call")
        add("gen_ai.tool.name",   event.get("tool_name"))
        add("cursor.tool_use_id", event.get("tool_use_id"))
        if event.get("tool_input") is not None:
            add("cursor.tool_input", _truncate(_raw_str(event["tool_input"]), 2000))
        if event.get("tool_output") is not None:
            add("cursor.tool_output", _truncate(_raw_str(event["tool_output"]), 2000))
        if event.get("duration") is not None:
            add_int("cursor.duration_ms", event["duration"])
        elif state and event.get("tool_name") in state.get("tool_starts", {}):
            add_int("cursor.duration_ms", _elapsed_ms(state["tool_starts"][event["tool_name"]]))

    elif name == "postToolUseFailure":
        add("gen_ai.operation.name", "tool_call")
        add("gen_ai.tool.name",   event.get("tool_name"))
        add("cursor.tool_use_id", event.get("tool_use_id"))
        if event.get("tool_input") is not None:
            add("cursor.tool_input", _truncate(_raw_str(event["tool_input"]), 2000))
        add("cursor.error",        _truncate(event.get("error_message", ""), 1000))
        add("cursor.failure_type", event.get("failure_type"))
        add("error.type",          "tool_failure")
        if event.get("is_interrupt"):
            add("cursor.is_interrupt", "true")
        if event.get("duration") is not None:
            add_int("cursor.duration_ms", event["duration"])
        elif state and event.get("tool_name") in state.get("tool_starts", {}):
            add_int("cursor.duration_ms", _elapsed_ms(state["tool_starts"][event["tool_name"]]))

    elif name == "beforeShellExecution":
        add("gen_ai.operation.name", "shell_execution")
        add("cursor.shell_command",  event.get("command"))
        add("cursor.cwd",            event.get("cwd"))
        if event.get("sandbox"):
            add("cursor.sandbox", "true")

    elif name == "afterShellExecution":
        add("gen_ai.operation.name", "shell_execution")
        add("cursor.shell_command",  event.get("command"))
        add("cursor.cwd",            event.get("cwd"))
        if event.get("exit_code") is not None:
            add_int("cursor.exit_code", event["exit_code"])
            if event["exit_code"] != 0:
                add("error.type", "shell_failure")
        if event.get("sandbox"):
            add("cursor.sandbox", "true")
        if event.get("output"):
            add("cursor.shell_output", _truncate(event["output"], 2000))
        if event.get("duration") is not None:
            add_int("cursor.duration_ms", event["duration"])
        elif state and event.get("command") in state.get("shell_starts", {}):
            add_int("cursor.duration_ms", _elapsed_ms(state["shell_starts"][event["command"]]))

    elif name == "beforeMCPExecution":
        add("gen_ai.operation.name", "mcp_call")
        add("gen_ai.tool.name",      event.get("tool_name"))
        if event.get("tool_input") is not None:
            add("cursor.tool_input", _truncate(_raw_str(event["tool_input"]), 2000))
        add("peer.service", event.get("url") or event.get("mcp_server", ""))

    elif name == "afterMCPExecution":
        add("gen_ai.operation.name", "mcp_call")
        add("gen_ai.tool.name",      event.get("tool_name"))
        if event.get("tool_input") is not None:
            add("cursor.tool_input", _truncate(_raw_str(event["tool_input"]), 2000))
        if event.get("result_json"):
            add("cursor.result_json", _truncate(event["result_json"], 2000))
        add("peer.service", event.get("url") or event.get("mcp_server", ""))
        if event.get("duration") is not None:
            add_int("cursor.duration_ms", event["duration"])
        elif state:
            key = event.get("tool_name") or "{}:{}".format(event.get("mcp_server", ""), event.get("mcp_tool", ""))
            if key in state.get("mcp_starts", {}):
                add_int("cursor.duration_ms", _elapsed_ms(state["mcp_starts"][key]))

    elif name == "beforeReadFile":
        add("cursor.file_path", event.get("file_path"))

    elif name == "afterFileEdit":
        add("cursor.file_path", event.get("file_path"))
        edits = event.get("edits") or []
        if edits:
            add_int("cursor.edit_count", len(edits))

    elif name == "subagentStart":
        add("gen_ai.operation.name",         "subagent_start")
        add("cursor.subagent_id",            event.get("subagent_id"))
        add("cursor.subagent_type",          event.get("subagent_type"))
        add("cursor.task",                   _truncate(event.get("task", ""), 2000))
        add("cursor.parent_conversation_id", event.get("parent_conversation_id"))
        add("cursor.subagent_model",         event.get("subagent_model"))
        add("cursor.git_branch",             event.get("git_branch"))
        if event.get("is_parallel_worker"):
            add("cursor.is_parallel_worker", "true")

    elif name == "subagentStop":
        add("gen_ai.operation.name", "subagent_stop")
        add("cursor.subagent_type",  event.get("subagent_type"))
        add("cursor.status",         event.get("status"))
        add("cursor.task",           _truncate(event.get("task", ""), 2000))
        add("cursor.description",    _truncate(event.get("description", ""), 1000))
        add("cursor.summary",        _truncate(event.get("summary", ""), 2000))
        if event.get("duration_ms") is not None:
            add_int("cursor.duration_ms", event["duration_ms"])
        if event.get("message_count") is not None:
            add_int("cursor.message_count", event["message_count"])
        if event.get("tool_call_count") is not None:
            add_int("cursor.tool_call_count", event["tool_call_count"])
        if event.get("loop_count") is not None:
            add_int("cursor.loop_count", event["loop_count"])
        if event.get("modified_files"):
            add_int("cursor.modified_file_count", len(event["modified_files"]))
        if event.get("status") == "error":
            add("error.type", "subagent_error")

    elif name == "sessionStart":
        add("gen_ai.operation.name", "session_start")
        add("cursor.session_id",     event.get("session_id"))
        add("cursor.composer_mode",  event.get("composer_mode"))
        if event.get("is_background_agent"):
            add("cursor.is_background_agent", "true")

    elif name == "sessionEnd":
        add("gen_ai.operation.name", "session_end")
        add("cursor.session_id",     event.get("session_id"))
        add("cursor.reason",         event.get("reason"))
        add("cursor.final_status",   event.get("final_status"))
        if event.get("is_background_agent"):
            add("cursor.is_background_agent", "true")
        if event.get("duration_ms") is not None:
            add_int("cursor.duration_ms", event["duration_ms"])
        if event.get("error_message"):
            add("cursor.error", _truncate(event["error_message"], 1000))
            add("error.type",   "session_error")

    elif name == "preCompact":
        add("gen_ai.operation.name",  "compact")
        add("cursor.compact_trigger", event.get("trigger"))
        if event.get("context_tokens") is not None:
            add_int("cursor.context_tokens",     event["context_tokens"])
            add_int("gen_ai.usage.input_tokens", event["context_tokens"])
        if event.get("context_window_size") is not None:
            add_int("cursor.context_window_size", event["context_window_size"])
        if event.get("context_usage_percent") is not None:
            add_int("cursor.context_usage_pct", int(event["context_usage_percent"]))
        if event.get("message_count") is not None:
            add_int("cursor.message_count", event["message_count"])
        if event.get("messages_to_compact") is not None:
            add_int("cursor.messages_to_compact", event["messages_to_compact"])
        if event.get("is_first_compaction"):
            add("cursor.is_first_compaction", "true")

    elif name == "stop":
        add("gen_ai.operation.name", "stop")
        add("cursor.status",         event.get("status"))
        if event.get("loop_count") is not None:
            add_int("cursor.loop_count", event["loop_count"])
            if event["loop_count"] > 20:
                add("cursor.agent_runaway", "true")
        if state and state.get("start_time_ns"):
            add_int("cursor.session_duration_ms", _elapsed_ms(state["start_time_ns"]))

    return attrs


# ---------------------------------------------------------------------------
# Export via OTel SDK
# ---------------------------------------------------------------------------

def emit_span(event, state):
    """Build and synchronously export a single span. Returns the SpanContext.

    Never raises — export errors are logged (DEBUG) or silently dropped so that
    a Coralogix outage cannot break Cursor's normal workflow.
    """
    if not CX_API_KEY or not CX_OTLP_ENDPOINT:
        return None

    hook_name = event.get("hook_event_name", "")

    try:
        return _emit_span_inner(event, hook_name, state)
    except Exception as exc:
        if DEBUG:
            print("cursor-coralogix-hook: export error: {}".format(exc), file=sys.stderr)
        return None


def _emit_span_inner(event, hook_name, state):
    resource = Resource.create({
        "service.name":       "cursor-agent",
        "service.version":    _SERVICE_VERSION,
        "telemetry.sdk.name": "cursor-coralogix-hook",
    })

    exporter = OTLPSpanExporter(
        endpoint=CX_OTLP_ENDPOINT + "/v1/traces",
        headers={
            "Authorization":       "Bearer " + CX_API_KEY,
            "CX-Application-Name": CX_APPLICATION_NAME,
            "CX-Subsystem-Name":   CX_SUBSYSTEM_NAME,
        },
    )

    provider = TracerProvider(resource=resource)
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    tracer = provider.get_tracer("cursor-coralogix", _SERVICE_VERSION)

    # For existing conversations, inject the root span as parent so all spans
    # share the same trace and hang off the first span.
    ctx = None
    if state and state.get("trace_id") and state.get("root_span_id"):
        parent_ctx = SpanContext(
            trace_id=int(state["trace_id"], 16),
            span_id=int(state["root_span_id"], 16),
            is_remote=True,
            trace_flags=TraceFlags(0x01),
        )
        ctx = trace.set_span_in_context(NonRecordingSpan(parent_ctx))

    attrs    = build_attributes(event, state)
    is_error = "error.type" in attrs

    span = tracer.start_span("cursor." + hook_name, context=ctx, kind=trace.SpanKind.SERVER)
    try:
        span.set_attributes(attrs)
        if is_error:
            span.set_status(Status(StatusCode.ERROR))
    finally:
        span.end()  # SimpleSpanProcessor exports synchronously here

    sc = span.get_span_context()
    if DEBUG:
        print(
            "cursor-coralogix-hook: exported span event={} trace_id={} span_id={}".format(
                hook_name,
                format(sc.trace_id, "032x"),
                format(sc.span_id, "016x"),
            ),
            file=sys.stderr,
        )

    return sc


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    raw = sys.stdin.buffer.read().strip()
    if not raw:
        print("{}")
        return

    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        print("{}")
        return

    conv_id         = conversation_id(event)
    hook_name       = event.get("hook_event_name", "")
    state           = None
    save_after_emit = False  # True for the first event of a new conversation

    if conv_id:
        sess_id = session_id(event)
        with _state_lock(conv_id):
            state = load_state(conv_id)
            if state is None:
                # New conversation — if a sessionStart already ran under session_id,
                # adopt its trace context so sessionStart becomes the root span.
                inherited = {}
                if sess_id and sess_id != conv_id:
                    session_state = load_state(sess_id)
                    if session_state and session_state.get("trace_id"):
                        inherited = {
                            "trace_id":     session_state["trace_id"],
                            "root_span_id": session_state["root_span_id"],
                        }
                state = {"start_time_ns": time.time_ns(), **inherited}
                save_after_emit = not inherited and hook_name != "stop"
            update_state(event, state)
            if not save_after_emit:
                if hook_name == "sessionEnd":
                    delete_state(conv_id)
                else:
                    save_state(conv_id, state)

    if hook_name in ("stop", "sessionEnd"):
        prune_old_states()

    if not (OMIT_PRE_TOOL_USE and hook_name == "preToolUse"):
        sc = emit_span(event, state)

        if save_after_emit and conv_id:
            state["trace_id"]     = format(sc.trace_id, "032x") if sc else ""
            state["root_span_id"] = format(sc.span_id, "016x") if sc else ""
            with _state_lock(conv_id):
                save_state(conv_id, state)
    elif save_after_emit and conv_id:
        # First event was skipped (OMIT_PRE_TOOL_USE); save state without trace_id.
        with _state_lock(conv_id):
            save_state(conv_id, state)

    print("{}")


if __name__ == "__main__":
    main()
