# ==============================================================================
# Intune Deployment Script: Deploy the Cursor Coralogix hook (per-user)
# Target Path: %USERPROFILE%\.cursor\hooks (written by install.ps1)
#
# MUST be assigned as a Win32 app in USER context, not SYSTEM. Unlike the
# Claude Code hook (machine-wide, under C:\ProgramData, runs as SYSTEM), the
# Cursor hook is per-user: it must land in the signed-in user's profile and
# register in that user's %USERPROFILE%\.cursor\hooks.json. A SYSTEM-context
# run would write into the wrong profile (or none), so this script checks
# for SYSTEM and refuses to proceed rather than silently doing the wrong
# thing.
#
# ------------------------------------------------------------------------
# Packaging (Win32 app via the Microsoft Win32 Content Prep Tool)
# ------------------------------------------------------------------------
#   1. Lay out a source folder containing the full cursor/ directory:
#        cursor\install.ps1
#        cursor\extension\resources\hook.py
#        cursor\mdm\deploy-intune.ps1   (this file)
#   2. Package it:
#        IntuneWinAppUtil.exe -c <source-folder> -s mdm\deploy-intune.ps1 -o <output-folder>
#   3. In Intune > Apps > Windows > Add > Windows app (Win32):
#        Install command:
#          powershell.exe -NoProfile -ExecutionPolicy Bypass -File deploy-intune.ps1 -ApiKey <key> -Endpoint <url>
#        Uninstall command:
#          powershell.exe -NoProfile -ExecutionPolicy Bypass -File deploy-intune.ps1 -Uninstall
#        Install behavior: User (Program Settings tab) - NOT System. This is
#        the setting that matters; a System-context run fails fast below
#        instead of silently installing into the wrong place.
#        Detection rule: File exists
#          Path: %USERPROFILE%\.cursor\hooks
#          File: coralogix_hook.cmd
#   4. Assign to a user group (not a device group) so it installs per-user.
#
# Prefer injecting -ApiKey from Intune's own secret handling (a script that
# pulls from your vault, or a per-user secure variable) rather than
# hardcoding it in the install command - the plain install command is
# visible to anyone with app read access in the Intune console.
#
# Requires Python 3.8+ on the user's PATH - same requirement as install.ps1.
# Idempotent - safe to re-run on every Intune re-evaluation cycle.
# ==============================================================================

param(
    [string]$ApiKey      = '',
    [string]$Endpoint    = '',
    [string]$Application = '',
    [string]$Subsystem   = '',
    [switch]$MaskPrompts,
    [switch]$OmitPreToolUse,
    [switch]$OtlpDebug,
    [string]$EnvFile     = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

# ---------------------------------------------------------------------------
# Refuse to run as SYSTEM (S-1-5-18): the hook must land in a real user's
# profile, and SYSTEM has no meaningful %USERPROFILE%\.cursor to install into.
# ---------------------------------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($currentIdentity.User.Value -eq 'S-1-5-18') {
    Write-Err "Error: this script is running as SYSTEM (S-1-5-18)."
    Write-Err "The Cursor hook is per-user and must be deployed via a Win32 app assigned in USER context, not SYSTEM."
    Write-Err "In Intune: Apps > <this app> > Properties > Install behavior = User."
    exit 1
}

# ---------------------------------------------------------------------------
# Delegate to install.ps1, one directory up (cursor\install.ps1 next to
# cursor\mdm\deploy-intune.ps1). install.ps1 itself validates the API key
# and endpoint (both required - no region default), resolves Python, and is
# idempotent, so no need to duplicate that logic here.
# ---------------------------------------------------------------------------
$InstallScript = Join-Path $PSScriptRoot '..\install.ps1'
if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
    Write-Err "Error: install.ps1 not found at $InstallScript"
    Write-Err "Package the full cursor\ directory (not just cursor\mdm\) - see header for layout."
    exit 1
}

$installArgs = @()
if ($Uninstall) {
    $installArgs += '-Uninstall'
} else {
    if ($ApiKey)         { $installArgs += @('-ApiKey', $ApiKey) }
    if ($Endpoint)       { $installArgs += @('-Endpoint', $Endpoint) }
    if ($Application)    { $installArgs += @('-Application', $Application) }
    if ($Subsystem)      { $installArgs += @('-Subsystem', $Subsystem) }
    if ($MaskPrompts)    { $installArgs += '-MaskPrompts' }
    if ($OmitPreToolUse) { $installArgs += '-OmitPreToolUse' }
    if ($OtlpDebug)      { $installArgs += '-OtlpDebug' }
    if ($EnvFile)        { $installArgs += @('-EnvFile', $EnvFile) }
}

& $InstallScript @installArgs
exit $LASTEXITCODE
