# ==============================================================================
# Windows Deployment Script: Deploy the Claude Code repo-tracker hook
# Target Path: C:\ProgramData\Coralogix\claude-code\claude.ps1
#
# Run as Administrator (or via your MDM, e.g. Intune, as SYSTEM). Writes the
# PostToolUse hook to a stable machine-wide path so it can be referenced from
# Claude Code's managed/remote settings. The script below is kept byte-for-byte
# in sync with claude-code/hooks/claude.ps1.
#
# No preflight checks needed: the hook requires only Windows PowerShell 5.1,
# which ships with every Windows 10/11 - zero runtime dependencies to verify.
# ==============================================================================

$ErrorActionPreference = 'Stop'

# 1. Define target directory and file path
$TargetDir  = 'C:\ProgramData\Coralogix\claude-code'
$TargetFile = Join-Path $TargetDir 'claude.ps1'

# 2. Ensure target directory exists
New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null

# 3. Write the hook. Single-quoted here-string => no PowerShell interpolation.
$Content = @'
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

# Claude Code PostToolUse hook that tracks repository names per session (Windows).
#
# Emits an OTLP/JSON gauge metric claude_code_session_repo_info with labels
# {session_id, repository_name, user_email} on each tool use. repository_name is
# the checkout's `origin` URL, credentials stripped.
#
# ZERO runtime assumptions: requires only Windows PowerShell 5.1, which ships
# with every Windows 10/11. No node, no python, no binaries to sign. git is
# optional: repo detection degrades to "unknown" without it, and every git call
# is bounded to 5s so a stale mount can never hang the session.
#
# Config is read from the same Claude Code settings files that hold the
# telemetry env block (Claude Code does not reliably pass its `env` block to
# hook subprocesses - see claude-code#20112):
#   OTEL_EXPORTER_OTLP_ENDPOINT   (bare URL)
#   OTEL_EXPORTER_OTLP_HEADERS    ("Authorization=Bearer <KEY>")
#   OTEL_RESOURCE_ATTRIBUTES      ("cx.application.name=x,cx.subsystem.name=y")
# Legacy CX_HOOK_* keys (CX_HOOK_OTLP_ENDPOINT / CX_HOOK_API_KEY /
# CX_HOOK_APPLICATION_NAME / CX_HOOK_SUBSYSTEM_NAME) are read as fallbacks so
# fleets mid-migration keep reporting.
# Optional flags (manual testing): -SettingsFile, -OtlpEndpoint, -OtlpHeaders,
# -ResourceAttributes.

param(
    [string]$SettingsFile = '',
    [string]$OtlpEndpoint = '',
    [string]$OtlpHeaders = '',
    [string]$ResourceAttributes = ''
)

$ErrorActionPreference = 'SilentlyContinue'

try {
    # PS 5.1 may default to TLS 1.0; Coralogix ingress requires TLS 1.2+.
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# JSON-escape a scalar via ConvertTo-Json (returns the value WITH surrounding
# quotes, all control/special chars correctly escaped). The payload structure
# itself is hand-built as a string so single-element arrays are never unwrapped
# to objects — a PS 5.1 ConvertTo-Json quirk that would corrupt the OTLP shape.
function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { $s = '' }
    return ($s | ConvertTo-Json -Compress)
}

function Read-EnvBlock([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $t = [IO.File]::ReadAllText($Path)
        if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
        $j = $t | ConvertFrom-Json
        if ($j -and $j.env) { return $j.env }
    } catch {}
    return $null
}

# Run git with a 5s bound so a hung fs/mount degrades instead of stalling the
# session. $GitArgs are fixed literal tokens (no spaces); only $Dir is dynamic
# and it is quoted ('"' is illegal in Windows paths, so quoting is safe).
function Invoke-GitBounded([string]$Dir, [string[]]$GitArgs) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $psi.Arguments = "-C `"$Dir`" " + ($GitArgs -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        if ($p.WaitForExit(5000)) {
            if ($p.ExitCode -eq 0) { return ([string]$outTask.Result).Trim() }
        } else {
            try { $p.Kill() } catch {}
        }
    } catch {}
    return $null
}

try {
    # --- Config resolution (same precedence as the macOS hook) ---------------
    $candidates = @()
    if ($SettingsFile) { $candidates += $SettingsFile }
    $candidates += 'C:\Program Files\ClaudeCode\managed-settings.json'
    $userHome = $env:USERPROFILE
    if ($userHome) {
        $candidates += (Join-Path $userHome '.claude\remote-settings.json')
        $candidates += (Join-Path $userHome '.claude\settings.json')
    }

    # Merge env blocks; higher-precedence (earlier) files win. Skip empty values
    # so a blank placeholder in a higher file does not block fallback to a lower
    # file that has the real value.
    $merged = @{}
    foreach ($f in $candidates) {
        $e = Read-EnvBlock $f
        if ($e) {
            foreach ($p in $e.PSObject.Properties) {
                $val = [string]$p.Value
                if ($val -ne '' -and -not $merged.ContainsKey($p.Name)) { $merged[$p.Name] = $val }
            }
        }
    }

    $endpoint = if ($OtlpEndpoint) { $OtlpEndpoint } else { $merged['OTEL_EXPORTER_OTLP_ENDPOINT'] }
    $headers  = if ($OtlpHeaders)  { $OtlpHeaders }  else { $merged['OTEL_EXPORTER_OTLP_HEADERS'] }
    $resAttrs = if ($ResourceAttributes) { $ResourceAttributes } else { $merged['OTEL_RESOURCE_ATTRIBUTES'] }

    # Authorization value: match the exact 'Authorization' pair (after trimming),
    # so X-Authorization / Proxy-Authorization are ignored; take the first.
    $auth = ''
    if ($headers) {
        foreach ($pair in ($headers -split ',')) {
            $t = $pair.Trim()
            if ($t -like 'Authorization=*') { $auth = $t.Substring('Authorization='.Length).Trim(); break }
        }
    }

    # Application/subsystem stamped only when explicitly configured.
    $app = ''; $sub = ''
    if ($resAttrs) {
        foreach ($pair in ($resAttrs -split ',')) {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2) {
                $k = $kv[0].Trim(); $v = $kv[1].Trim()
                if ($k -eq 'cx.application.name') { $app = $v }
                if ($k -eq 'cx.subsystem.name')   { $sub = $v }
            }
        }
    }

    # Legacy CX_HOOK_* fallbacks (mid-migration fleets).
    if (-not $endpoint) { $endpoint = $merged['CX_HOOK_OTLP_ENDPOINT'] }
    if (-not $auth) { $k = $merged['CX_HOOK_API_KEY']; if ($k) { $auth = "Bearer $k" } }
    if (-not $app) { $app = [string]$merged['CX_HOOK_APPLICATION_NAME'] }
    if (-not $sub) { $sub = [string]$merged['CX_HOOK_SUBSYSTEM_NAME'] }

    if (-not $endpoint -or -not $auth) { exit 0 }

    # --- Event (PostToolUse JSON on stdin) ------------------------------------
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    $ev = $raw | ConvertFrom-Json
    if (-not $ev -or -not $ev.session_id) { exit 0 }
    $sid = [string]$ev.session_id
    $cwd = [string]$ev.cwd
    $tool = [string]$ev.tool_name
    $fp = ''
    if (@('Read','Edit','Write','NotebookEdit') -contains $tool) {
        if ($ev.tool_input -and $ev.tool_input.file_path) { $fp = [string]$ev.tool_input.file_path }
    } elseif (@('Glob','Grep') -contains $tool) {
        if ($ev.tool_input -and $ev.tool_input.path) { $fp = [string]$ev.tool_input.path }
    }
    $email = ''
    if ($ev.user_email) { $email = [string]$ev.user_email }
    if (-not $cwd -and -not $fp) { exit 0 }

    # --- Repo detection (git optional) ----------------------------------------
    $gitOk = $false
    try { if (Get-Command git -ErrorAction SilentlyContinue) { $gitOk = $true } } catch {}

    function Get-RepoRoot([string]$Dir) {
        if (-not $gitOk) { return $null }
        $out = Invoke-GitBounded $Dir @('rev-parse', '--show-toplevel')
        if ($out) { return $out }
        return $null
    }

    function Get-RepoName([string]$Root) {
        $url = Invoke-GitBounded $Root @('remote', 'get-url', 'origin')
        $u = if ($url) { ([string]$url).Trim() } else { Split-Path -Leaf $Root }
        # Never label a token; an '@' after the authority belongs to the path.
        $schemeEnd = $u.IndexOf('://')
        if ($schemeEnd -ge 0) {
            $rest = $u.Substring($schemeEnd + 3)
            $pathStart = $rest.IndexOf('/')
            $authority = if ($pathStart -ge 0) { $rest.Substring(0, $pathStart) } else { $rest }
            $at = $authority.IndexOf('@')
            if ($at -ge 0) { $u = $u.Substring(0, $schemeEnd + 3) + $rest.Substring($at + 1) }
        }
        return $u
    }

    $nowNs = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() * 1000000000).ToString()

    function New-DataPoint([string]$name) {
        '{"attributes":[' +
          '{"key":"session_id","value":{"stringValue":' + (ConvertTo-JsonString $sid) + '}},' +
          '{"key":"repository_name","value":{"stringValue":' + (ConvertTo-JsonString $name) + '}},' +
          '{"key":"user_email","value":{"stringValue":' + (ConvertTo-JsonString $email) + '}}' +
          '],"timeUnixNano":"' + $nowNs + '","asInt":"1"}'
    }

    # Dedupe by repo root AND by resolved name (a linked worktree resolves to a
    # different root but the same origin URL; emit one data point per name).
    $dps = @()
    $seenRoots = @(); $seenNames = @()
    foreach ($p in @($cwd, $fp)) {
        if (-not $p) { continue }
        $d = $p
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            $d = Split-Path -Parent $p
        }
        if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        $root = Get-RepoRoot $d
        if (-not $root -or $seenRoots -contains $root) { continue }
        $seenRoots += $root
        $name = Get-RepoName $root
        if (-not $name -or $seenNames -contains $name) { continue }
        $seenNames += $name
        $dps += (New-DataPoint $name)
    }
    if ($dps.Count -eq 0) { $dps += (New-DataPoint 'unknown') }

    # --- Build OTLP/JSON payload (hand-built string; guaranteed array shape) ---
    $rattrs = '{"key":"service.name","value":{"stringValue":"claude-code-hook"}}'
    if ($app) { $rattrs += ',{"key":"cx.application.name","value":{"stringValue":' + (ConvertTo-JsonString $app) + '}}' }
    if ($sub) { $rattrs += ',{"key":"cx.subsystem.name","value":{"stringValue":' + (ConvertTo-JsonString $sub) + '}}' }

    $payload = '{"resourceMetrics":[{"resource":{"attributes":[' + $rattrs + ']},' +
        '"scopeMetrics":[{"scope":{"name":"repo-tracker","version":"1.0.0"},' +
        '"metrics":[{"name":"claude_code_session_repo_info","gauge":{"dataPoints":[' +
        ($dps -join ',') + ']}}]}]}]}'

    # --- Emit (errors swallowed; the hook must never disturb the session) ------
    $ep = $endpoint.TrimEnd('/')
    if ($ep -notmatch '^https?://') { $ep = "https://$ep" }

    Invoke-WebRequest -Uri "$ep/v1/metrics" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
        -ContentType 'application/json' `
        -Headers @{ Authorization = $auth } `
        -TimeoutSec 5 -UseBasicParsing | Out-Null
} catch {}

exit 0
'@

# 4. Write as UTF-8 WITHOUT BOM (Set-Content -Encoding utf8 on Windows
#    PowerShell 5.1 would prepend a BOM).
[System.IO.File]::WriteAllText($TargetFile, $Content, (New-Object System.Text.UTF8Encoding $false))

Write-Host "Deployed Claude Code repo-tracker hook to $TargetFile"
exit 0
