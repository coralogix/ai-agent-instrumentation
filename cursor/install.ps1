# cursor-coralogix install script (Windows)
#
# Deploys the Coralogix telemetry hook for Cursor into a single user account.
# Works for a local install and for MDM provisioning (Intune, SCCM, PDQ, etc.).
#
# Targets Windows PowerShell 5.1 (ships with every Windows 10/11) and works
# unchanged on pwsh 7. Requires Python 3.8+ (python, py -3, or python3); the
# absolute path of the interpreter that answers is pinned into the wrapper.
#
# Run with -Help for usage.

param(
    [string]$ApiKey      = '',
    [string]$Endpoint    = '',
    [string]$Application = '',
    [string]$Subsystem   = '',
    [switch]$MaskPrompts,
    [switch]$NoMaskPrompts,
    [switch]$OmitPreToolUse,
    [switch]$OtlpDebug,
    [string]$EnvFile     = '',
    [string]$HookSource  = '',
    [switch]$Uninstall,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
# pwsh 7.4 turns non-zero exit codes into terminating errors under Stop; PS 5.1 doesn't.
# Disable it so $LASTEXITCODE checks below behave the same on both hosts.
$PSNativeCommandUseErrorActionPreference = $false

try {
    # PS 5.1 may default to TLS 1.0; pip and any HTTPS call need TLS 1.2+.
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    Write-Host @'
Usage:
  powershell -ExecutionPolicy Bypass -File install.ps1 -ApiKey <key> -Endpoint <url> -Application <name> -Subsystem <name>
  powershell -ExecutionPolicy Bypass -File install.ps1 -EnvFile .env
  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall

Each option can also be supplied through the environment variable named beside it.
Values from -EnvFile take precedence over both.

  -ApiKey          KEY   CX_API_KEY                      (required)
  -Endpoint        URL   CX_OTLP_ENDPOINT                (required: your region's OTLP ingress)
  -Application     NAME  CX_APPLICATION_NAME             (required; conventional: cursor)
  -Subsystem       NAME  CX_SUBSYSTEM_NAME               (required; conventional: cursor-sessions)
  -MaskPrompts           CURSOR_MASK_PROMPTS             (default: true)
  -NoMaskPrompts         Send full prompt/response text (CURSOR_MASK_PROMPTS=false).
                         Wins if both -MaskPrompts and -NoMaskPrompts are passed.
  -OmitPreToolUse        CURSOR_OMIT_PRE_TOOL_USE_SPANS  (default: false)
  -OtlpDebug             CX_OTLP_DEBUG                   (default: false)
  -EnvFile         PATH  Load the values above from a .env file
  -HookSource      PATH  Path to hook.py (default: extension\resources\hook.py next to this script)
  -Uninstall             Remove the hook
  -Help                  Show this help
'@
}

if ($Help) {
    Show-Usage
    exit 0
}

# ---------------------------------------------------------------------------
# Defaults (overridable via env vars, then parameters, then -EnvFile)
# ---------------------------------------------------------------------------

function Get-Default([string]$EnvName, [string]$Fallback) {
    $v = [Environment]::GetEnvironmentVariable($EnvName)
    if ([string]::IsNullOrEmpty($v)) { return $Fallback }
    return $v
}

$cxApiKey      = Get-Default 'CX_API_KEY' ''
$cxEndpoint    = Get-Default 'CX_OTLP_ENDPOINT' ''
$cxApplication = Get-Default 'CX_APPLICATION_NAME' ''
$cxSubsystem   = Get-Default 'CX_SUBSYSTEM_NAME' ''
$cxMask        = Get-Default 'CURSOR_MASK_PROMPTS' 'true'
$cxOmitPre     = Get-Default 'CURSOR_OMIT_PRE_TOOL_USE_SPANS' 'false'
$cxDebug       = Get-Default 'CX_OTLP_DEBUG' 'false'

if ($ApiKey)      { $cxApiKey = $ApiKey }
if ($Endpoint)    { $cxEndpoint = $Endpoint }
if ($Application) { $cxApplication = $Application }
if ($Subsystem)   { $cxSubsystem = $Subsystem }
if ($MaskPrompts)    { $cxMask = 'true' }
if ($NoMaskPrompts)  { $cxMask = 'false' }  # -NoMaskPrompts wins if both are passed
if ($OmitPreToolUse) { $cxOmitPre = 'true' }
if ($OtlpDebug)      { $cxDebug = 'true' }

# ---------------------------------------------------------------------------
# Load .env file if provided
# ---------------------------------------------------------------------------

# Strips an unquoted trailing comment, surrounding quotes and stray whitespace,
# so a value pasted straight out of the docs ("https://... # see region table")
# still reaches the env file clean. Mirrors clean_env_value in install.sh.
function Get-CleanEnvValue([string]$Value) {
    $v = $Value
    $comment = [regex]::Match($v, '\s#')
    if ($comment.Success) { $v = $v.Substring(0, $comment.Index) }
    $v = $v.Trim()
    if ($v.Length -ge 2 -and (
            ($v.StartsWith('"') -and $v.EndsWith('"')) -or
            ($v.StartsWith("'") -and $v.EndsWith("'")))) {
        $v = $v.Substring(1, $v.Length - 2)
    }
    return $v
}

if ($EnvFile) {
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
        Write-Err "Error: env file not found: $EnvFile"
        exit 1
    }
    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $t.Substring(0, $idx).Trim()
        $value = Get-CleanEnvValue ($t.Substring($idx + 1))
        switch ($key) {
            'CX_API_KEY'                      { $cxApiKey = $value }
            'CX_OTLP_ENDPOINT'                { $cxEndpoint = $value }
            'CX_APPLICATION_NAME'             { $cxApplication = $value }
            'CX_SUBSYSTEM_NAME'               { $cxSubsystem = $value }
            'CURSOR_MASK_PROMPTS'             { $cxMask = $value }
            'CURSOR_OMIT_PRE_TOOL_USE_SPANS'  { $cxOmitPre = $value }
            'CX_OTLP_DEBUG'                   { $cxDebug = $value }
        }
    }
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$UserHome    = $env:USERPROFILE
if (-not $UserHome) { $UserHome = $HOME }
$HooksDir    = Join-Path $UserHome '.cursor\hooks'
$HooksJson   = Join-Path $UserHome '.cursor\hooks.json'
$InstalledPy = Join-Path $HooksDir 'coralogix_hook.py'
$InstalledEnv = Join-Path $HooksDir 'coralogix_hook.env'
$WrapperPs1  = Join-Path $HooksDir 'coralogix_hook.ps1'
$WrapperCmd  = Join-Path $HooksDir 'coralogix_hook.cmd'

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Utf8File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

# ---------------------------------------------------------------------------
# Python interpreter resolution (the wrapper inherits the path resolved here)
# ---------------------------------------------------------------------------

# Each candidate is probed by RUNNING it, not just by looking it up: on stock
# Windows the python.exe on PATH is often the Microsoft Store App Execution Alias,
# which exists, resolves, and then opens the Store instead of running Python.
# The winner is returned as its ABSOLUTE path so the wrapper never repeats this
# lookup in Cursor's bare-bones hook environment.
function Resolve-Python {
    foreach ($candidate in @(@('python'), @('py', '-3'), @('python3'))) {
        $exe = $candidate[0]
        $resolved = Get-Command $exe -ErrorAction SilentlyContinue
        if (-not $resolved) { continue }
        $probeArgs = @()
        if ($candidate.Count -gt 1) { $probeArgs += $candidate[1..($candidate.Count - 1)] }
        $probeArgs += '-c'
        $probeArgs += 'import sys; sys.exit(0)'
        try {
            & $exe $probeArgs 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $path = $resolved.Source
                if (-not $path) { $path = $exe }
                $pre = @()
                if ($candidate.Count -gt 1) { $pre = $candidate[1..($candidate.Count - 1)] }
                return ,(@($path) + $pre)
            }
        } catch {}
    }
    return $null
}

$Python = Resolve-Python
if (-not $Python) {
    Write-Err "Error: no working Python 3.8+ found (tried python, py -3, python3)."
    Write-Err "A python.exe that only opens the Microsoft Store does not count - install a real"
    Write-Err "interpreter (winget install Python.Python.3.12, or https://www.python.org/downloads/windows/),"
    Write-Err "then re-run this installer."
    exit 1
}
$PyExe = $Python[0]
$PyPre = @()
if ($Python.Count -gt 1) { $PyPre = $Python[1..($Python.Count - 1)] }
$PyDisplay = ($PyExe + ' ' + ($PyPre -join ' ')).Trim()
Write-Host "Python:         $PyDisplay"

# PS 5.1's ConvertTo-Json unwraps single-element arrays into objects and would
# corrupt hooks.json, so all JSON I/O goes through this Python helper instead.
function Invoke-PythonScript([string]$Script, [string[]]$ScriptArgs) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cursor_coralogix_" + [Guid]::NewGuid().ToString('N') + ".py")
    try {
        Write-Utf8File $tmp $Script
        $allArgs = @()
        $allArgs += $PyPre
        $allArgs += $tmp
        $allArgs += $ScriptArgs
        & $PyExe $allArgs | Out-Null
        return $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Embedded Python: hooks.json merge / removal
# ---------------------------------------------------------------------------

$MergeScript = @'
import json, os, sys

HOOK_EVENTS = [
    "sessionStart", "sessionEnd", "beforeSubmitPrompt",
    "preToolUse", "postToolUse", "postToolUseFailure",
    "beforeShellExecution", "afterShellExecution",
    "beforeMCPExecution", "afterMCPExecution",
    "beforeReadFile", "afterFileEdit", "preCompact", "stop",
    "subagentStart", "subagentStop", "afterAgentResponse", "afterAgentThought",
]

hooks_json, wrapper = sys.argv[1], sys.argv[2]
entry = {"command": wrapper, "timeout": 10}

try:
    with open(hooks_json, encoding="utf-8") as f:
        config = json.load(f)
except (OSError, ValueError):
    config = {}

if not isinstance(config, dict):
    config = {}
config.setdefault("version", 1)
if not isinstance(config.get("hooks"), dict):
    config["hooks"] = {}

for event in HOOK_EVENTS:
    current = config["hooks"].get(event)
    current = current if isinstance(current, list) else []
    # Re-running the installer replaces our entry instead of appending a duplicate.
    existing = [e for e in current if not (isinstance(e, dict) and e.get("command") == wrapper)]
    existing.append(entry)
    config["hooks"][event] = existing

os.makedirs(os.path.dirname(hooks_json), exist_ok=True)
with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
'@

$RemoveScript = @'
import json, sys

hooks_json, wrapper = sys.argv[1], sys.argv[2]
try:
    with open(hooks_json, encoding="utf-8") as f:
        config = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(config, dict) or not isinstance(config.get("hooks"), dict):
    sys.exit(0)
hooks = config["hooks"]
for event in list(hooks):
    if not isinstance(hooks[event], list):
        continue
    remaining = [e for e in hooks[event] if not (isinstance(e, dict) and e.get("command") == wrapper)]
    # Drop the event entirely when we were its only hook, so uninstalling
    # leaves hooks.json as it was rather than littered with empty arrays.
    if remaining:
        hooks[event] = remaining
    else:
        del hooks[event]
with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
'@

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if ($Uninstall) {
    Write-Host "Removing Coralogix hook..."

    $removeExit = Invoke-PythonScript $RemoveScript @($HooksJson, $WrapperCmd)
    if ($removeExit -ne 0) {
        Write-Err "Warning: failed to update $HooksJson - remove the coralogix_hook.cmd entries by hand."
    }

    foreach ($f in @($InstalledPy, $InstalledEnv, $WrapperPs1, $WrapperCmd)) {
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            Remove-Item -LiteralPath $f -Force
            Write-Host "Removed: $f"
        }
    }

    Write-Host "Done. Restart Cursor to deactivate telemetry."
    Write-Host "Cached conversation state remains in $UserHome\.cursor-hook-state (safe to delete)."
    exit 0
}

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

if (-not $cxApiKey) {
    Write-Err "Error: -ApiKey or CX_API_KEY is required."
    exit 1
}

if (-not $cxEndpoint) {
    Write-Err "Error: -Endpoint or CX_OTLP_ENDPOINT is required (your region's OTLP ingress, e.g. https://ingress.<domain>)."
    exit 1
}

if (-not $cxApplication) {
    Write-Err "Error: -Application or CX_APPLICATION_NAME is required (conventional: cursor)."
    exit 1
}

if (-not $cxSubsystem) {
    Write-Err "Error: -Subsystem or CX_SUBSYSTEM_NAME is required (conventional: cursor-sessions)."
    exit 1
}

# Reject anything that would put the API key on the wire in cleartext. http:// is
# allowed only for a collector on this machine. Kept in step with the same check
# in install.sh and hook.py.
if ($cxEndpoint -notmatch '^https://\S+$' -and
    $cxEndpoint -notmatch '^http://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(/|$)') {
    Write-Err "Error: invalid -Endpoint: $cxEndpoint"
    Write-Err "It must start with https:// (or http://localhost, http://127.0.0.1, http://[::1] for a local collector) and contain no spaces."
    exit 1
}

if (-not $HookSource) {
    $HookSource = Join-Path $ScriptDir 'extension\resources\hook.py'
}

if (-not (Test-Path -LiteralPath $HookSource -PathType Leaf)) {
    Write-Err "Error: hook.py not found at $HookSource"
    Write-Err "Use -HookSource <path> to specify the location."
    exit 1
}
$HookSource = (Resolve-Path -LiteralPath $HookSource).ProviderPath

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

Write-Host "Installing Coralogix hook for Cursor..."

# 1. Create hooks directory
New-Item -ItemType Directory -Force -Path $HooksDir | Out-Null

# 2. Write env file (credentials)
$EnvContent = @(
    "CX_API_KEY=$cxApiKey",
    "CX_OTLP_ENDPOINT=$cxEndpoint",
    "CX_APPLICATION_NAME=$cxApplication",
    "CX_SUBSYSTEM_NAME=$cxSubsystem",
    "CURSOR_MASK_PROMPTS=$cxMask",
    "CURSOR_OMIT_PRE_TOOL_USE_SPANS=$cxOmitPre",
    "CX_OTLP_DEBUG=$cxDebug"
) -join "`r`n"
Write-Utf8File $InstalledEnv ($EnvContent + "`r`n")

# NTFS chmod-600 equivalent via icacls: strip inheritance and grant only the
# profile owner and the invoking account (an MDM runs this as SYSTEM against
# another user's profile). SIDs avoid localized account names, and icacls
# replaces the DACL atomically - PS 5.1's RemoveAccessRule throws on the
# inherited rules this file starts with.
try {
    $sids = @()
    try {
        $sids += (Get-Acl -LiteralPath $UserHome).GetOwner(
            [System.Security.Principal.SecurityIdentifier]).Value
    } catch {}
    $sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $grantArgs = @()
    foreach ($sid in ($sids | Where-Object { $_ } | Select-Object -Unique)) {
        $grantArgs += @('/grant:r', ('*' + $sid + ':F'))
    }
    icacls $InstalledEnv /inheritance:r @grantArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls exited with $LASTEXITCODE" }
} catch {
    Write-Warning "Could not restrict permissions on $InstalledEnv - it contains your API key."
    Write-Warning "  Reason: $($_.Exception.Message)"
}
Write-Host "Env written:    $InstalledEnv"

# 3. Copy hook.py
Copy-Item -LiteralPath $HookSource -Destination $InstalledPy -Force
Write-Host "Hook installed: $InstalledPy"

# 4. Write the PowerShell wrapper (loads the env file, then runs hook.py)
$WrapperPs1Content = @'
# Auto-generated by the cursor-coralogix install script - do not edit manually

$ErrorActionPreference = 'SilentlyContinue'

try {
    $envFile = Join-Path $PSScriptRoot 'coralogix_hook.env'
    # Allowlist: the env file only ever holds these; refusing anything else
    # closes off a PYTHONPATH-style injection surface if it's tampered with.
    $allowedKeys = @('CX_API_KEY', 'CX_OTLP_ENDPOINT', 'CX_APPLICATION_NAME', 'CX_SUBSYSTEM_NAME', 'CURSOR_MASK_PROMPTS', 'CURSOR_OMIT_PRE_TOOL_USE_SPANS', 'CX_OTLP_DEBUG')
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#')) { continue }
            $idx = $t.IndexOf('=')
            if ($idx -lt 1) { continue }
            $k = $t.Substring(0, $idx).Trim()
            $v = $t.Substring($idx + 1).Trim()
            if ($allowedKeys -notcontains $k) { continue }
            [Environment]::SetEnvironmentVariable($k, $v, 'Process')
        }
    }

    # Pinned by the installer to the interpreter it verified, by absolute path:
    # re-resolving 'python' here could pick up the Microsoft Store alias, which
    # would open the Store instead of sending telemetry.
    $python = '__PY_BIN__'
    $pyArgs = @(__PY_ARGS__)
    # Interpreter went missing since install: exit quietly. A hook must never
    # break the Cursor session.
    if (-not (Test-Path -LiteralPath $python)) { exit 0 }

    $hook = Join-Path $PSScriptRoot 'coralogix_hook.py'
    & $python ($pyArgs + @($hook))
    exit $LASTEXITCODE
} catch {
    exit 0
}
'@
# Single quotes are doubled: PowerShell's escape inside a single-quoted literal,
# for the rare user profile path that contains an apostrophe.
$PyArgsLiteral = (($PyPre | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', ')
$WrapperPs1Content = $WrapperPs1Content.Replace('__PY_BIN__', $PyExe.Replace("'", "''")).Replace('__PY_ARGS__', $PyArgsLiteral)
Write-Utf8File $WrapperPs1 $WrapperPs1Content
Write-Host "Wrapper:        $WrapperPs1"

# 5. Write the .cmd shim registered in hooks.json - Cursor on Windows needs a
#    .cmd entry point to reliably launch PowerShell with stdin attached.
$WrapperCmdContent = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0coralogix_hook.ps1" %*
'@
Write-Utf8File $WrapperCmd (($WrapperCmdContent -replace "`r?`n", "`r`n") + "`r`n")
Write-Host "Shim:           $WrapperCmd"

# 6. Merge hooks.json
$mergeExit = Invoke-PythonScript $MergeScript @($HooksJson, $WrapperCmd)
if ($mergeExit -ne 0) {
    Write-Err "Error: failed to update $HooksJson"
    exit 1
}
Write-Host "hooks.json:     $HooksJson"

# 7. Install Python dependencies
Write-Host "Installing Python dependencies..."
$pipArgs = @()
$pipArgs += $PyPre
$pipArgs += @('-m', 'pip', 'install', '--quiet', '--user', '--no-warn-script-location',
              'opentelemetry-sdk', 'opentelemetry-exporter-otlp-proto-http')
try { & $PyExe $pipArgs } catch { $global:LASTEXITCODE = 1 }
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Python dependencies could not be installed automatically."
    Write-Warning "Install them manually, then restart Cursor:"
    Write-Warning "  $PyExe -m pip install --user opentelemetry-sdk opentelemetry-exporter-otlp-proto-http"
} else {
    Write-Host "Python dependencies installed."
}

Write-Host ""
Write-Host "Done. Restart Cursor to activate telemetry."
Write-Host "  Application : $cxApplication"
Write-Host "  Subsystem   : $cxSubsystem"
Write-Host "  Endpoint    : $cxEndpoint"
