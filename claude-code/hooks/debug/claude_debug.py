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

"""DEBUG version of the Claude Code repo-tracker PostToolUse hook.

This is a diagnostic twin of ``claude.py``. It performs the exact same work —
parse the event, resolve repos, build the OTLP protobuf, POST it to Coralogix —
but instead of silently swallowing every error and returning, it logs every
single decision point and, most importantly, the FULL HTTP response (status
code + body) returned by the Coralogix ingress endpoint.

Output goes to BOTH the console (stdout) and a debug log file so the developer
can copy/paste everything back in one shot.

Log file location (first match wins):
    1. $CX_HOOK_DEBUG_LOG   (env var, full path)
    2. <system temp dir>/claude_hook_debug.log

Run standalone (no stdin) to exercise the full network path with a dummy event:
    CX_HOOK_API_KEY=<send-your-data-key> \\
    CX_HOOK_OTLP_ENDPOINT=https://ingress.us2.coralogix.com \\
    python3 claude_debug.py

NOTE: This file carries NO secrets. The API key is read only from the
CX_HOOK_API_KEY env var (or an OTLP Bearer header). TLS verification can be
temporarily disabled to diagnose a corporate TLS-intercepting proxy by setting
CX_HOOK_DEBUG_DISABLE_TLS=1 — never do that in the production hook.

Zero external dependencies — Python 3 stdlib only.
"""

from __future__ import annotations

import datetime
import json
import logging
import os
import platform
import re
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import traceback
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# ---------------------------------------------------------------------------
# Logging setup — console (stdout) + file
# ---------------------------------------------------------------------------

LOG_PATH = os.environ.get("CX_HOOK_DEBUG_LOG") or os.path.join(
    tempfile.gettempdir(), "claude_hook_debug.log"
)

logger = logging.getLogger("cx_hook_debug")
logger.setLevel(logging.DEBUG)

_fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

# Log to stdout (not stderr) so PowerShell's 2>&1 redirection doesn't promote
# normal log lines to terminating errors under $ErrorActionPreference='Stop'.
_console = logging.StreamHandler(sys.stdout)
_console.setFormatter(_fmt)
logger.addHandler(_console)

try:
    _file = logging.FileHandler(LOG_PATH, mode="w", encoding="utf-8")
    _file.setFormatter(_fmt)
    logger.addHandler(_file)
    _FILE_OK = True
except OSError as exc:  # pragma: no cover - defensive
    _FILE_OK = False
    logger.error("Could NOT open debug log file %s: %s", LOG_PATH, exc)


def section(title: str) -> None:
    logger.info("=" * 72)
    logger.info(title)
    logger.info("=" * 72)


def mask_secret(value: str) -> str:
    """Show length + first/last 4 chars so we can sanity-check the key
    without leaking it into the log the user pastes back."""
    if not value:
        return "<EMPTY>"
    if len(value) <= 8:
        return f"<len={len(value)}, value hidden>"
    return f"<len={len(value)}, starts='{value[:4]}', ends='{value[-4:]}'>"


# ---------------------------------------------------------------------------
# Configuration resolution (mirrors claude.py, but logs each source)
# ---------------------------------------------------------------------------

def _parse_resource_attributes() -> dict:
    raw = os.environ.get("OTEL_RESOURCE_ATTRIBUTES", "")
    attrs = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if "=" in pair:
            key, value = pair.split("=", 1)
            attrs[key.strip()] = value.strip()
    return attrs


# ---------------------------------------------------------------------------
# Convenience defaults — used only when the corresponding env var is NOT set.
# This lets the script run standalone on Windows, where Claude Code does not
# propagate the settings `env` block into hook subprocesses (GitHub #20112).
#
# IMPORTANT: NO secret is hardcoded here. The API key is intentionally empty —
# provide it via the CX_HOOK_API_KEY env var (or an OTLP Bearer header).
# ---------------------------------------------------------------------------
DEFAULT_API_KEY = ""
DEFAULT_OTLP_ENDPOINT = "https://ingress.us2.coralogix.com"
DEFAULT_APPLICATION_NAME = "claude-code"
DEFAULT_SUBSYSTEM_NAME = "claude-code-sessions"

# When True, skip TLS certificate verification. Use this ONLY to prove the
# metric reaches Coralogix from behind a corporate TLS-intercepting proxy
# (Zscaler/Netskope) whose CA cert Python rejects. Controlled by the env var so
# no insecure default is committed. NEVER enable this in the production hook —
# fix trust via SSL_CERT_FILE / a corporate CA bundle instead.
DISABLE_TLS_VERIFY = os.environ.get("CX_HOOK_DEBUG_DISABLE_TLS") == "1"


def _resolve_api_key() -> tuple[str, str]:
    """Returns (key, source) so we can see WHERE the key came from."""
    key = os.environ.get("CX_HOOK_API_KEY", "")
    if key:
        return key, "CX_HOOK_API_KEY"
    headers = os.environ.get("OTEL_EXPORTER_OTLP_HEADERS", "")
    if "Bearer " in headers:
        return headers.split("Bearer ", 1)[1].strip(), "OTEL_EXPORTER_OTLP_HEADERS"
    return DEFAULT_API_KEY, "DEFAULT (empty — set CX_HOOK_API_KEY)"


def _resolve_endpoint() -> tuple[str, str]:
    val = os.environ.get("CX_HOOK_OTLP_ENDPOINT")
    if val:
        return val, "CX_HOOK_OTLP_ENDPOINT"
    val = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if val:
        return val, "OTEL_EXPORTER_OTLP_ENDPOINT"
    return DEFAULT_OTLP_ENDPOINT, "DEFAULT (hardcoded)"


FILE_PATH_TOOLS = {"Read", "Edit", "Write", "NotebookEdit"}
SEARCH_PATH_TOOLS = {"Glob", "Grep"}


# ---------------------------------------------------------------------------
# Repo detection (mirrors claude.py, with logging)
# ---------------------------------------------------------------------------

def git_available() -> str:
    try:
        result = subprocess.run(
            ["git", "--version"], capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return f"git returned exit code {result.returncode}: {result.stderr.strip()}"
    except FileNotFoundError:
        return "<git NOT FOUND on PATH>"
    except subprocess.TimeoutExpired:
        return "<git --version timed out>"
    except Exception as exc:  # pragma: no cover
        return f"<git check error: {exc!r}>"


def find_repo_root(path: str):
    directory = path if os.path.isdir(path) else os.path.dirname(path)
    if not directory or not os.path.isdir(directory):
        logger.debug("find_repo_root: '%s' -> directory '%s' is not valid", path, directory)
        return None
    try:
        result = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            root = result.stdout.strip()
            logger.debug("find_repo_root: '%s' -> repo root '%s'", path, root)
            return root
        logger.debug("find_repo_root: '%s' -> git rc=%s stderr=%s",
                     path, result.returncode, result.stderr.strip())
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        logger.debug("find_repo_root: '%s' -> %r", path, exc)
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
                logger.debug("get_repo_name: origin='%s' -> '%s'", url, match.group(1))
                return match.group(1)
            logger.debug("get_repo_name: origin='%s' did not match pattern", url)
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        logger.debug("get_repo_name: %r", exc)
    fallback = os.path.basename(repo_root)
    logger.debug("get_repo_name: falling back to basename '%s'", fallback)
    return fallback


def extract_paths(event: dict) -> list:
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


def resolve_repos(paths: list) -> set:
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
# Minimal protobuf encoder (identical to claude.py)
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


def build_otlp_protobuf(session_id, repo_name, user_email,
                        application_name, subsystem_name) -> bytes:
    now_ns = int(time.time() * 1_000_000_000)
    dp = b""
    for key, val in [("session_id", session_id),
                     ("repository_name", repo_name),
                     ("user_email", user_email)]:
        dp += _field_bytes(7, _encode_kv(key, val))
    dp += _field_fixed64(3, now_ns)
    dp += _field_fixed64(6, 1)
    gauge = _field_bytes(1, dp)
    metric = _encode_string(1, "claude_code_session_repo_info")
    metric += _field_bytes(5, gauge)
    scope = _encode_string(1, "repo-tracker") + _encode_string(2, "1.0.0")
    scope_metrics = _field_bytes(1, scope) + _field_bytes(2, metric)
    resource = _field_bytes(1, _encode_kv("service.name", "claude-code-hook"))
    if application_name:
        resource += _field_bytes(1, _encode_kv("cx.application.name", application_name))
    if subsystem_name:
        resource += _field_bytes(1, _encode_kv("cx.subsystem.name", subsystem_name))
    resource_metrics = _field_bytes(1, resource) + _field_bytes(2, scope_metrics)
    return _field_bytes(1, resource_metrics)


# ---------------------------------------------------------------------------
# OTLP emission WITH full response capture
# ---------------------------------------------------------------------------

def emit_metric(endpoint, api_key, session_id, repo_name, user_email,
                application_name, subsystem_name) -> None:
    data = build_otlp_protobuf(session_id, repo_name, user_email,
                               application_name, subsystem_name)
    url = f"{endpoint.rstrip('/')}/v1/metrics"

    logger.info("Emitting metric for repo='%s' session='%s' user='%s'",
                repo_name, session_id, user_email)
    logger.info("POST URL          : %s", url)
    logger.info("Payload size      : %d bytes", len(data))
    logger.debug("Payload hex (first 120 bytes): %s", data[:120].hex())

    # DNS / host reachability check ------------------------------------------
    host = url.split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0]
    try:
        infos = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
        addrs = sorted({i[4][0] for i in infos})
        logger.info("DNS resolve %-30s -> %s", host, ", ".join(addrs))
    except OSError as exc:
        logger.error("DNS resolution FAILED for host '%s': %r", host, exc)

    req = Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/x-protobuf",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )

    # Optionally bypass TLS verification to get past a corporate
    # TLS-intercepting proxy whose CA cert Python's OpenSSL rejects.
    ctx = ssl.create_default_context()
    if DISABLE_TLS_VERIFY:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        logger.warning("TLS verification DISABLED (insecure, via "
                       "CX_HOOK_DEBUG_DISABLE_TLS=1) — proving the egress path "
                       "only. Do NOT do this in the production hook.")

    start = time.time()
    try:
        with urlopen(req, timeout=10, context=ctx) as resp:
            body = resp.read()
            elapsed = (time.time() - start) * 1000
            logger.info("HTTP RESPONSE     : %s %s (%.0f ms)",
                        resp.status, resp.reason, elapsed)
            logger.info("Response headers  : %s", dict(resp.headers))
            logger.info("Response body     : %r", body[:2000])
            if resp.status == 200:
                logger.info("✓ SUCCESS — Coralogix ingress ACCEPTED the metric (HTTP 200).")
                logger.info("  If the metric still does not appear in Metrics Explorer, "
                            "the issue is downstream: API-key app/subsystem routing, "
                            "TCO/metrics filtering, or the metric name/labels query.")
    except HTTPError as exc:
        elapsed = (time.time() - start) * 1000
        body = b""
        try:
            body = exc.read()
        except Exception:
            pass
        logger.error("HTTP ERROR        : %s %s (%.0f ms)", exc.code, exc.reason, elapsed)
        logger.error("Error headers     : %s", dict(exc.headers or {}))
        logger.error("Error body        : %r", body[:2000])
        if exc.code in (401, 403):
            logger.error("  -> 401/403 = AUTH problem. The API key is wrong, not a "
                         "'Send-Your-Data' key, or lacks metrics ingestion permission.")
        elif exc.code == 404:
            logger.error("  -> 404 = wrong endpoint/path. Endpoint must be the ingress "
                         "host (e.g. https://ingress.eu1.coralogix.com) and the code "
                         "appends /v1/metrics.")
        elif exc.code == 400:
            logger.error("  -> 400 = malformed OTLP protobuf payload (see error body).")
    except URLError as exc:
        elapsed = (time.time() - start) * 1000
        reason = exc.reason
        logger.error("URL ERROR         : %r (%.0f ms)", reason, elapsed)
        if isinstance(reason, ssl.SSLError):
            logger.error("  -> TLS/SSL failure. Likely a corporate TLS-intercepting "
                         "proxy or missing CA certs. Check HTTPS_PROXY and system certs.")
        elif isinstance(reason, socket.timeout):
            logger.error("  -> Connection timed out. Firewall/proxy may be blocking "
                         "egress to the Coralogix ingress host on port 443.")
        else:
            logger.error("  -> Network-level failure reaching the endpoint.")
    except Exception as exc:  # pragma: no cover
        logger.error("UNEXPECTED ERROR during emit: %r", exc)
        logger.error(traceback.format_exc())


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    section("CLAUDE CODE HOOK — DEBUG RUN")
    logger.info("UTC time          : %s",
                datetime.datetime.now(datetime.timezone.utc).isoformat())
    logger.info("Debug log file    : %s (writable=%s)", LOG_PATH, _FILE_OK)
    logger.info("Python executable : %s", sys.executable)
    logger.info("Python version    : %s", sys.version.replace("\n", " "))
    logger.info("Platform          : %s", platform.platform())
    logger.info("CWD               : %s", os.getcwd())
    logger.info("git               : %s", git_available())

    # --- Environment ------------------------------------------------------
    section("ENVIRONMENT VARIABLES")
    api_key, key_src = _resolve_api_key()
    endpoint, ep_src = _resolve_endpoint()
    resource_attrs = _parse_resource_attributes()
    application_name = (
        os.environ.get("CX_HOOK_APPLICATION_NAME")
        or resource_attrs.get("cx.application.name")
        or DEFAULT_APPLICATION_NAME
    )
    subsystem_name = (
        os.environ.get("CX_HOOK_SUBSYSTEM_NAME")
        or resource_attrs.get("cx.subsystem.name")
        or DEFAULT_SUBSYSTEM_NAME
    )

    logger.info("CX_HOOK_API_KEY            present=%s", bool(os.environ.get("CX_HOOK_API_KEY")))
    logger.info("CX_HOOK_OTLP_ENDPOINT     = %s", os.environ.get("CX_HOOK_OTLP_ENDPOINT", "<unset>"))
    logger.info("CX_HOOK_APPLICATION_NAME  = %s", os.environ.get("CX_HOOK_APPLICATION_NAME", "<unset>"))
    logger.info("CX_HOOK_SUBSYSTEM_NAME    = %s", os.environ.get("CX_HOOK_SUBSYSTEM_NAME", "<unset>"))
    logger.info("OTEL_EXPORTER_OTLP_ENDPOINT = %s", os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "<unset>"))
    logger.info("OTEL_EXPORTER_OTLP_HEADERS  present=%s", bool(os.environ.get("OTEL_EXPORTER_OTLP_HEADERS")))
    logger.info("OTEL_RESOURCE_ATTRIBUTES  = %s", os.environ.get("OTEL_RESOURCE_ATTRIBUTES", "<unset>"))
    logger.info("HTTP_PROXY  = %s", os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy") or "<unset>")
    logger.info("HTTPS_PROXY = %s", os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or "<unset>")
    logger.info("NO_PROXY    = %s", os.environ.get("NO_PROXY") or os.environ.get("no_proxy") or "<unset>")

    logger.info("-" * 72)
    logger.info("RESOLVED api_key      : %s  (source: %s)", mask_secret(api_key), key_src)
    logger.info("RESOLVED endpoint     : %s  (source: %s)", endpoint or "<EMPTY>", ep_src)
    logger.info("RESOLVED application  : %s", application_name or "<EMPTY — relies on API-key routing>")
    logger.info("RESOLVED subsystem    : %s", subsystem_name or "<EMPTY — relies on API-key routing>")

    # --- Guard rails (the prod hook returns silently here) ----------------
    if not api_key:
        logger.error("ABORT: API key is EMPTY. The production hook would silently exit "
                     "here. Set CX_HOOK_API_KEY for the hook subprocess (Claude Code "
                     "strips OTEL_* from hook env).")
    if not endpoint:
        logger.error("ABORT: endpoint is EMPTY. The production hook would silently exit "
                     "here. Set CX_HOOK_OTLP_ENDPOINT.")

    # --- Input event ------------------------------------------------------
    section("INPUT EVENT (stdin)")
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    logger.info("Raw stdin (%d bytes): %s", len(raw), raw if len(raw) < 4000 else raw[:4000] + "...<truncated>")
    if not raw.strip():
        logger.info("stdin EMPTY — using a hardcoded dummy event so the script "
                    "runs standalone (just `python claude_debug.py`).")
        raw = json.dumps({
            "session_id": "debug-session-001",
            "tool_name": "Read",
            "tool_input": {"file_path": os.getcwd()},
            "cwd": os.getcwd(),
            "user_email": "debug-test@coralogix.com",
        })
        logger.info("Dummy event       : %s", raw)
    try:
        event = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.error("ABORT: stdin is not valid JSON: %s", exc)
        _flush_and_report()
        return

    session_id = event.get("session_id")
    logger.info("session_id        : %s", session_id)
    if not session_id:
        logger.error("NOTE: no 'session_id' in event. The production hook would exit here. "
                     "Using 'debug-no-session' so we can still test the network path.")
        session_id = "debug-no-session"

    user_email = event.get("user_email", "")
    logger.info("user_email        : %s", user_email or "<empty>")

    # --- Path / repo resolution ------------------------------------------
    section("PATH & REPO RESOLUTION")
    paths = extract_paths(event)
    logger.info("Extracted paths   : %s", paths)
    if not paths:
        logger.warning("No paths extracted. The production hook would exit here. "
                       "(Event needs 'cwd', or a file_path/path for the tool.)")
    repos = resolve_repos(paths)
    logger.info("Resolved repos    : %s", sorted(repos) if repos else "<none>")
    if not repos:
        repos = {"unknown"}
        logger.info("Falling back to repo set: {'unknown'}")

    # --- Emit -------------------------------------------------------------
    section("OTLP EMISSION")
    if not api_key or not endpoint:
        logger.error("Skipping emit because api_key and/or endpoint is missing (see ABORT above).")
    else:
        for repo in sorted(repos):
            emit_metric(endpoint, api_key, session_id, repo, user_email,
                        application_name, subsystem_name)

    _flush_and_report()


def _flush_and_report() -> None:
    section("DEBUG RUN COMPLETE")
    logger.info("Full log written to: %s", LOG_PATH)
    logger.info("Copy the console output above OR the contents of that file back "
                "to your engineer to diagnose.")
    for h in logger.handlers:
        try:
            h.flush()
        except Exception:
            pass


if __name__ == "__main__":
    # Unlike the production hook, we DO surface unexpected errors here.
    try:
        main()
    except Exception:
        logger.error("FATAL — unhandled exception in debug hook:")
        logger.error(traceback.format_exc())
        sys.exit(1)
