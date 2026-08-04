# cursor-coralogix MDM install script (Windows)
#
# Deploys the Coralogix telemetry hook for Cursor to a single user account.
# Designed to be run by an MDM (Intune, SCCM, PDQ, etc.) during provisioning.
#
# Targets Windows PowerShell 5.1 (ships with every Windows 10/11) and works
# unchanged on pwsh 7.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1 -ApiKey <key> [options]
#   powershell -ExecutionPolicy Bypass -File install.ps1 -EnvFile .env
#
# All parameters can also be set via environment variables.
#
# Options:
#   -ApiKey          KEY   CX_API_KEY          (required unless -EnvFile is used)
#   -Endpoint        URL   CX_OTLP_ENDPOINT    (required: your region's OTLP ingress)
#   -Application     NAME  CX_APPLICATION_NAME (default: cursor)
#   -Subsystem       NAME  CX_SUBSYSTEM_NAME   (default: cursor-sessions)
#   -MaskPrompts           CURSOR_MASK_PROMPTS (default: true)
#   -NoMaskPrompts         Send full prompt/response text (sets CURSOR_MASK_PROMPTS=false)
#                          Wins if both -MaskPrompts and -NoMaskPrompts are passed.
#   -OmitPreToolUse        CURSOR_OMIT_PRE_TOOL_USE_SPANS (default: false)
#   -OtlpDebug             CX_OTLP_DEBUG       (default: false)
#   -EnvFile         PATH  Load credentials from a .env file (local use)
#   -HookSource      PATH  Path to hook.py     (default: .\extension\resources\hook.py)
#   -Uninstall             Remove the hook
#
# Requires Python 3.8+ on PATH (python, py -3, or python3).

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
    [switch]$Uninstall
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
$cxApplication = Get-Default 'CX_APPLICATION_NAME' 'cursor'
$cxSubsystem   = Get-Default 'CX_SUBSYSTEM_NAME' 'cursor-sessions'
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
        $value = $t.Substring($idx + 1).Trim()
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
# Python interpreter resolution (installer-side; the wrapper resolves its own)
# ---------------------------------------------------------------------------

function Resolve-Python {
    foreach ($candidate in @(@('python'), @('py', '-3'), @('python3'))) {
        $exe = $candidate[0]
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        $probeArgs = @()
        if ($candidate.Count -gt 1) { $probeArgs += $candidate[1..($candidate.Count - 1)] }
        $probeArgs += '-c'
        $probeArgs += 'import sys; sys.exit(0)'
        try {
            & $exe $probeArgs 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return ,$candidate }
        } catch {}
    }
    return $null
}

$Python = Resolve-Python
if (-not $Python) {
    Write-Err "Error: Python 3.8+ not found on PATH (tried python, py -3, python3)."
    exit 1
}
$PyExe = $Python[0]
$PyPre = @()
if ($Python.Count -gt 1) { $PyPre = $Python[1..($Python.Count - 1)] }

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
except (FileNotFoundError, ValueError):
    config = {}

config.setdefault("version", 1)
config.setdefault("hooks", {})

for event in HOOK_EVENTS:
    existing = [e for e in config["hooks"].get(event, []) if e.get("command") != wrapper]
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
except (FileNotFoundError, ValueError):
    sys.exit(0)
hooks = config.get("hooks", {})
for event in list(hooks.keys()):
    hooks[event] = [e for e in hooks[event] if e.get("command") != wrapper]
with open(hooks_json, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
'@

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if ($Uninstall) {
    Write-Host "Removing Coralogix hook..."

    Invoke-PythonScript $RemoveScript @($HooksJson, $WrapperCmd) | Out-Null

    foreach ($f in @($InstalledPy, $InstalledEnv, $WrapperPs1, $WrapperCmd)) {
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            Remove-Item -LiteralPath $f -Force
            Write-Host "Removed: $f"
        }
    }

    Write-Host "Done. Restart Cursor to deactivate telemetry."
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

# Reject non-https endpoints, except local OTLP collectors (http://localhost / 127.0.0.1).
if ($cxEndpoint -notmatch '^https://' -and $cxEndpoint -notmatch '^http://(localhost|127\.0\.0\.1)') {
    Write-Err "Error: -Endpoint must start with https:// (or http://localhost / http://127.0.0.1 for a local collector)."
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

# NTFS chmod-600 equivalent: drop inherited rules, grant only the profile owner
# and the invoking account - an MDM runs this as SYSTEM against another user's profile.
try {
    $grantees = @()
    try { $grantees += (Get-Acl -LiteralPath $UserHome).Owner } catch {}
    $grantees += [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $InstalledEnv
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
    foreach ($who in ($grantees | Where-Object { $_ } | Select-Object -Unique)) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule `
            -ArgumentList $who, 'FullControl', 'None', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $InstalledEnv -AclObject $acl
} catch {
    Write-Warning "Could not restrict permissions on $InstalledEnv - it contains your API key."
}
Write-Host "Env written:    $InstalledEnv"

# 3. Copy hook.py
Copy-Item -LiteralPath $HookSource -Destination $InstalledPy -Force
Write-Host "Hook installed: $InstalledPy"

# 4. Write the PowerShell wrapper (loads the env file, then runs hook.py)
$WrapperPs1Content = @'
# Auto-generated by cursor-coralogix MDM install script - do not edit manually

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

    $python = $null
    $pyArgs = @()
    foreach ($candidate in @(@('python'), @('py', '-3'), @('python3'))) {
        if (Get-Command $candidate[0] -ErrorAction SilentlyContinue) {
            $python = $candidate[0]
            if ($candidate.Count -gt 1) { $pyArgs = $candidate[1..($candidate.Count - 1)] }
            break
        }
    }
    # No interpreter: exit quietly. A hook must never break the Cursor session.
    if (-not $python) { exit 0 }

    $hook = Join-Path $PSScriptRoot 'coralogix_hook.py'
    & $python ($pyArgs + @($hook))
    exit $LASTEXITCODE
} catch {
    exit 0
}
'@
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
$pipArgs += @('-m', 'pip', 'install', '--quiet', '--user',
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
