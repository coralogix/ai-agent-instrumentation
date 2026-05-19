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

Emits an OTLP gauge metric (claude_code_session_repo_info = 1) with labels
{session_id, repository_name, user_email} for each unique repo detected
during a Claude Code session. Zero external dependencies — Python 3 stdlib only.
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

API_KEY = os.environ.get("CX_HOOK_API_KEY", "")
OTLP_ENDPOINT = os.environ.get(
    "CX_HOOK_OTLP_ENDPOINT", "https://ingress.eu2.coralogix.com"
)
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

def load_emitted_repos(session_id: str) -> set[str]:
    """Load the set of repos already emitted for this session."""
    state_file = os.path.join(STATE_DIR, f"{session_id}.repos")
    try:
        with open(state_file) as f:
            return set(line.strip() for line in f if line.strip())
    except FileNotFoundError:
        return set()


def save_repo(session_id: str, repo: str) -> None:
    """Append a repo name to the session state file."""
    os.makedirs(STATE_DIR, exist_ok=True)
    state_file = os.path.join(STATE_DIR, f"{session_id}.repos")
    with open(state_file, "a") as f:
        f.write(repo + "\n")


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
# OTLP metric emission
# ---------------------------------------------------------------------------

def build_otlp_payload(
    session_id: str, repo_name: str, user_email: str,
) -> dict:
    """Build the OTLP JSON payload for a gauge metric data point."""
    now_ns = str(int(time.time() * 1_000_000_000))
    return {
        "resourceMetrics": [{
            "resource": {
                "attributes": [
                    {"key": "service.name", "value": {"stringValue": "claude-code-hook"}},
                    {"key": "cx.application.name", "value": {"stringValue": APPLICATION_NAME}},
                    {"key": "cx.subsystem.name", "value": {"stringValue": SUBSYSTEM_NAME}},
                ],
            },
            "scopeMetrics": [{
                "scope": {"name": "repo-tracker", "version": "1.0.0"},
                "metrics": [{
                    "name": "claude_code_session_repo_info",
                    "gauge": {
                        "dataPoints": [{
                            "asInt": "1",
                            "timeUnixNano": now_ns,
                            "attributes": [
                                {"key": "session_id", "value": {"stringValue": session_id}},
                                {"key": "repository_name", "value": {"stringValue": repo_name}},
                                {"key": "user_email", "value": {"stringValue": user_email}},
                            ],
                        }],
                    },
                }],
            }],
        }],
    }


def emit_metric(session_id: str, repo_name: str, user_email: str) -> None:
    """POST the OTLP JSON gauge metric to the Coralogix endpoint."""
    payload = build_otlp_payload(session_id, repo_name, user_email)
    data = json.dumps(payload).encode("utf-8")
    url = f"{OTLP_ENDPOINT.rstrip('/')}/v1/metrics"

    debug(f"POST {url}")
    debug(f"Payload: {json.dumps(payload, indent=2)}")

    req = Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
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
    # Guard: no API key → nothing to do
    if not API_KEY:
        debug("CX_HOOK_API_KEY not set, exiting")
        return

    event = json.load(sys.stdin)
    session_id = event.get("session_id")
    if not session_id:
        debug("No session_id in event, exiting")
        return

    # Extract paths and resolve repos
    paths = extract_paths(event)
    if not paths:
        debug("No paths to check, exiting")
        return

    repos = resolve_repos(paths)
    if not repos:
        debug("No git repos found, exiting")
        return

    # Deduplicate against session state
    emitted = load_emitted_repos(session_id)
    new_repos = repos - emitted
    if not new_repos:
        debug(f"All repos already emitted for session {session_id}: {repos}")
        return

    # Emit metric for each new repo
    user_email = event.get("user_email", "")
    for repo in sorted(new_repos):
        debug(f"New repo detected: {repo} (session={session_id})")
        emit_metric(session_id, repo, user_email)
        save_repo(session_id, repo)

    # Occasional state cleanup
    maybe_prune_state()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        if DEBUG:
            print(f"[repo-tracker] Fatal error: {e}", file=sys.stderr)
        sys.exit(0)  # Never block Claude Code
