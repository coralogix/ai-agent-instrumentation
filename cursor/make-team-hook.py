#!/usr/bin/env python3
"""
Build the copy-paste script bodies for Cursor Enterprise *team hooks*, so a
customer can deploy the Coralogix Cursor integration fleet-wide from the Cursor
dashboard alone - no MDM, no per-developer steps.

The idea: a dashboard team hook can only carry a script body (no files, no pip,
no env file, one event per entry). So instead of reimplementing the integration
inside that limit, the body *is* a bootstrap that carries install.sh (or
install.ps1) and hook.py base64-embedded, runs the real installer once in the
background, and stamps a version marker so every later event exits in ~2ms.
The installer writes ~/.cursor/hooks.json, which Cursor watches and reloads
automatically - so all 18 event hooks go live in the same session, no restart.

Usage:
    ./make-team-hook.py \
        --repo   ./cursor                       # checkout of the cursor/ dir
        --api-key        <send-your-data key> \
        --endpoint       https://ingress.eu2.coralogix.com \
        --application    cursor \
        --subsystem      cursor-sessions \
        [--no-mask-prompts] [--out-dir ./out]

Writes:
    out/team-hook.unix.sh    -> paste as the Linux + Macintosh hook body
    out/team-hook.windows.ps1 -> paste as the Windows hook body
"""

import argparse
import base64
import gzip
import pathlib
import sys

VERSION = "2.0.0"

UNIX_TEMPLATE = r"""#!/usr/bin/env bash
# Coralogix telemetry bootstrap for Cursor - v__VERSION__
# Distributed as a Cursor Enterprise team hook (Dashboard > Rules, Commands,
# Hooks > Hooks). Registered on Workspace Open; it installs the full 18-event
# hook set into ~/.cursor/hooks.json on first run and then no-ops.
# It never blocks or breaks the agent: every path prints {} and exits 0.

cat >/dev/null 2>&1
printf '{}\n'

VERSION='__VERSION__'
HOOKS_DIR="$HOME/.cursor/hooks"
STAMP="$HOOKS_DIR/.coralogix-bootstrap-$VERSION"
LOCK="$HOOKS_DIR/.coralogix-bootstrap.lock"

# Already installed at this version: the common path, ~2ms.
[ -f "$STAMP" ] && exit 0

# Someone else's install is in flight (Workspace Open can fire concurrently).
# A stale lock older than 10 minutes is reclaimed.
mkdir -p "$HOOKS_DIR" 2>/dev/null || exit 0
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -z "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then exit 0; fi
  rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
fi

# No interpreter: stay silent rather than nag every session.
if ! command -v python3 >/dev/null 2>&1; then rm -rf "$LOCK"; exit 0; fi

WORK="$(mktemp -d 2>/dev/null)" || { rm -rf "$LOCK"; exit 0; }

# Payloads are gzipped then base64'd to keep the pasted body small. base64 -d is
# not portable across BSD/GNU, and python3 is already required, so decode there.
_decode() { python3 -c 'import base64,gzip,sys;open(sys.argv[1],"wb").write(gzip.decompress(base64.b64decode(sys.stdin.buffer.read())))' "$1"; }

_decode "$WORK/install.sh" <<'CX_INSTALLER_B64'
__INSTALL_B64__
CX_INSTALLER_B64

_decode "$WORK/hook.py" <<'CX_HOOK_B64'
__HOOK_B64__
CX_HOOK_B64

# Detach: the installer pip-installs two packages and must outlive the hook
# timeout. Cursor reloads hooks.json on write, so telemetry starts mid-session.
# setsid is absent on macOS, so the subshell + nohup does the detaching.
( nohup bash -c '
  set -e
  bash "'"$WORK"'/install.sh" \
    --hook-source "'"$WORK"'/hook.py" \
    --api-key     '"'"'__API_KEY__'"'"' \
    --endpoint    '"'"'__ENDPOINT__'"'"' \
    --application '"'"'__APPLICATION__'"'"' \
    --subsystem   '"'"'__SUBSYSTEM__'"'"' \
    __MASK_FLAG__ >/dev/null 2>&1
  rm -f "'"$HOOKS_DIR"'"/.coralogix-bootstrap-*
  : > "'"$STAMP"'"
  rm -rf "'"$WORK"'" "'"$LOCK"'"
' >/dev/null 2>&1 </dev/null & ) &

exit 0
"""

PS_TEMPLATE = r"""# Coralogix telemetry bootstrap for Cursor - v__VERSION__
# Windows twin of the Unix team hook. Register as a second hook entry on
# Workspace Open with Operating Systems = Windows only.
# Never blocks or breaks the agent: every path emits {} and exits 0.

try { [Console]::In.ReadToEnd() | Out-Null } catch {}
'{}'

$ErrorActionPreference = 'SilentlyContinue'
$Version  = '__VERSION__'
$HooksDir = Join-Path $env:USERPROFILE '.cursor\hooks'
$Stamp    = Join-Path $HooksDir ".coralogix-bootstrap-$Version"
$Lock     = Join-Path $HooksDir '.coralogix-bootstrap.lock'

if (Test-Path -LiteralPath $Stamp) { exit 0 }

New-Item -ItemType Directory -Force -Path $HooksDir | Out-Null
try { $null = New-Item -ItemType Directory -Path $Lock -ErrorAction Stop }
catch {
  $age = (Get-Date) - (Get-Item -LiteralPath $Lock).CreationTime
  if ($age.TotalMinutes -lt 10) { exit 0 }
  Remove-Item -Recurse -Force -LiteralPath $Lock
  $null = New-Item -ItemType Directory -Path $Lock
}

$py = @('python','py','python3') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $py) { Remove-Item -Recurse -Force $Lock; exit 0 }

$work = Join-Path $env:TEMP ("cx-cursor-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Expand-Payload([string]$b64, [string]$dest) {
  $in  = New-Object IO.MemoryStream(,[Convert]::FromBase64String($b64))
  $gz  = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
  $out = [IO.File]::Create($dest)
  $gz.CopyTo($out); $out.Close(); $gz.Close(); $in.Close()
}
Expand-Payload '__INSTALL_B64_ONELINE__' "$work\install.ps1"
Expand-Payload '__HOOK_B64_ONELINE__'    "$work\hook.py"

# Detached so pip does not run against the hook timeout.
$cmd = "powershell -ExecutionPolicy Bypass -NoProfile -File `"$work\install.ps1`" " +
       "-HookSource `"$work\hook.py`" -ApiKey '__API_KEY__' -Endpoint '__ENDPOINT__' " +
       "-Application '__APPLICATION__' -Subsystem '__SUBSYSTEM__' __MASK_FLAG_PS__; " +
       "Remove-Item `"$HooksDir\.coralogix-bootstrap-*`" -Force; " +
       "New-Item -ItemType File -Force -Path `"$Stamp`" | Out-Null; " +
       "Remove-Item -Recurse -Force `"$work`",`"$Lock`""
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-Command',$cmd | Out-Null

exit 0
"""


def pack(data: bytes) -> str:
    # mtime=0 so regenerating from the same sources yields a byte-identical body,
    # which keeps dashboard diffs meaningful.
    return base64.b64encode(gzip.compress(data, mtime=0)).decode()


def b64_wrapped(data: bytes, width: int = 120) -> str:
    s = pack(data)
    return "\n".join(s[i:i + width] for i in range(0, len(s), width))


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--repo", default=".", help="path to the repo's cursor/ directory")
    p.add_argument("--api-key", required=True)
    p.add_argument("--endpoint", required=True)
    p.add_argument("--application", default="cursor")
    p.add_argument("--subsystem", default="cursor-sessions")
    p.add_argument("--no-mask-prompts", action="store_true")
    p.add_argument("--out-dir", default="out")
    a = p.parse_args()

    repo = pathlib.Path(a.repo)
    sources = {
        "install.sh": repo / "install.sh",
        "install.ps1": repo / "install.ps1",
        "hook.py": repo / "extension" / "resources" / "hook.py",
    }
    for name, path in sources.items():
        if not path.is_file():
            print(f"error: {name} not found at {path}", file=sys.stderr)
            return 1

    hook_b64 = sources["hook.py"].read_bytes()
    subs_common = {
        "__VERSION__": VERSION,
        "__API_KEY__": a.api_key,
        "__ENDPOINT__": a.endpoint,
        "__APPLICATION__": a.application,
        "__SUBSYSTEM__": a.subsystem,
    }

    unix = UNIX_TEMPLATE
    unix = unix.replace("__INSTALL_B64__", b64_wrapped(sources["install.sh"].read_bytes()))
    unix = unix.replace("__HOOK_B64__", b64_wrapped(hook_b64))
    unix = unix.replace("__MASK_FLAG__", "--no-mask-prompts" if a.no_mask_prompts else "--mask-prompts")

    win = PS_TEMPLATE
    win = win.replace("__INSTALL_B64_ONELINE__", pack(sources["install.ps1"].read_bytes()))
    win = win.replace("__HOOK_B64_ONELINE__", pack(hook_b64))
    win = win.replace("__MASK_FLAG_PS__", "-NoMaskPrompts" if a.no_mask_prompts else "-MaskPrompts")

    for k, v in subs_common.items():
        unix = unix.replace(k, v)
        win = win.replace(k, v)

    out = pathlib.Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "team-hook.unix.sh").write_text(unix)
    (out / "team-hook.windows.ps1").write_text(win)

    print(f"wrote {out/'team-hook.unix.sh'}      {len(unix):,} chars")
    print(f"wrote {out/'team-hook.windows.ps1'}  {len(win):,} chars")
    print("\nPaste each into Dashboard > Rules, Commands, Hooks > Hooks > Add:")
    print("  Hook Step         Workspace Open")
    print("  Operating Systems Linux + Macintosh  (unix body) / Windows (ps1 body)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
