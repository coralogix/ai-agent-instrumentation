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

# Claude Code hook that reports session telemetry to Coralogix (Windows).
#
# Sends one OTLP/JSON span per hook event (SessionStart, UserPromptSubmit,
# PostToolUse, PostToolUseFailure, CwdChanged, DirectoryAdded, SessionEnd) to
# /v1/traces. On PostToolUse it also emits the OTLP/JSON gauge metric
# claude_code_session_repo_info with labels {session_id, repository_name,
# branch_name, user_email} to /v1/metrics.
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

    # --- Event (hook JSON on stdin) -------------------------------------------
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    $ev = $raw | ConvertFrom-Json
    if (-not $ev -or -not $ev.session_id) { exit 0 }
    # Empty event name = older Claude Code builds that only fired PostToolUse.
    $evName = [string]$ev.hook_event_name
    if (-not $evName) { $evName = 'PostToolUse' }
    if (@('SessionStart','UserPromptSubmit','PostToolUse','PostToolUseFailure','CwdChanged','DirectoryAdded','SessionEnd') -notcontains $evName) { exit 0 }
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
    $sendMetric = ($evName -eq 'PostToolUse' -and ($cwd -or $fp))

    # --- Repo detection (git optional) ----------------------------------------
    $gitOk = $false
    try { if (Get-Command git -ErrorAction SilentlyContinue) { $gitOk = $true } } catch {}

    function Get-RepoRoot([string]$Dir) {
        if (-not $gitOk) { return $null }
        $out = Invoke-GitBounded $Dir @('rev-parse', '--show-toplevel')
        if ($out) { return $out }
        return $null
    }

    # An https remote can hold a token (https://user:token@host/...): never send it.
    function Get-OriginUrl([string]$Root) {
        $url = Invoke-GitBounded $Root @('remote', 'get-url', 'origin')
        if ($url) { return (([string]$url).Trim() -replace '^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@', '$1') }
        return $null
    }

    function Get-RepoName([string]$Root) {
        $url = Get-OriginUrl $Root
        if ($url) {
            $u = ([string]$url).Trim().TrimEnd('/')
            if ($u.EndsWith('.git')) { $u = $u.Substring(0, $u.Length - 4) }
            # @(...) forces an array so a single segment is not unwrapped to a
            # scalar string (whose [-1] would index the last character).
            $parts = @(($u -replace ':', '/') -split '/' | Where-Object { $_ -ne '' })
            if ($parts.Count -ge 2) { return ($parts[-2] + '/' + $parts[-1]) }
            if ($parts.Count -eq 1) { return $parts[0] }
        }
        return (Split-Path -Leaf $Root)
    }

    function Get-RepoBranch([string]$Root) {
        # symbolic-ref (not rev-parse) so a fresh repo with no commits still
        # resolves; detached HEAD reports "HEAD".
        $b = Invoke-GitBounded $Root @('symbolic-ref', '--short', '-q', 'HEAD')
        if ($b) { return ([string]$b).Trim() }
        return 'HEAD'
    }

    $rattrs = '{"key":"service.name","value":{"stringValue":"claude-code-hook"}}'
    if ($app) { $rattrs += ',{"key":"cx.application.name","value":{"stringValue":' + (ConvertTo-JsonString $app) + '}}' }
    if ($sub) { $rattrs += ',{"key":"cx.subsystem.name","value":{"stringValue":' + (ConvertTo-JsonString $sub) + '}}' }
    # roi-service keeps only the hook spans with this source type (the Kafka header of the span).
    $spanRattrs = $rattrs + ',{"key":"cx.integration.source.type","value":{"stringValue":"anthropic-claude-code"}}'

    $ep = $endpoint.TrimEnd('/')
    if ($ep -notmatch '^https?://') { $ep = "https://$ep" }

    # --- Span: one per hook event ---------------------------------------------
    # Hand-built OTLP KeyValue list; empty/null values are omitted. Never add
    # prompt text, tool input/output, paths or transcript content here.
    $spanAttrs = New-Object System.Collections.ArrayList
    function Add-SpanAttr([string]$Key, [string]$Type, $Value) {
        if ($null -eq $Value -or [string]$Value -eq '') { return }
        if ($Type -eq 'bool') { $v = '{"boolValue":' + $(if ([bool]$Value) { 'true' } else { 'false' }) + '}' }
        elseif ($Type -eq 'int') { $v = '{"intValue":"' + [string]$Value + '"}' }
        else { $v = '{"stringValue":' + (ConvertTo-JsonString ([string]$Value)) + '}' }
        [void]$spanAttrs.Add('{"key":"' + $Key + '","value":' + $v + '}')
    }

    Add-SpanAttr 'agent_name' 'string' 'claude-code'
    Add-SpanAttr 'hook_event' 'string' $evName
    Add-SpanAttr 'session_id' 'string' $sid
    Add-SpanAttr 'user_email' 'string' $email
    Add-SpanAttr 'prompt_id' 'string' $ev.prompt_id
    Add-SpanAttr 'permission_mode' 'string' $ev.permission_mode
    Add-SpanAttr 'agent_id' 'string' $ev.agent_id
    Add-SpanAttr 'agent_type' 'string' $ev.agent_type

    # Target directory: the path the event is about; falls back to its parent,
    # then to cwd, when the path no longer exists. Only the tools the ROI service
    # reads as file tools: another tool with a file_path (an MCP tool) keeps cwd.
    $targetPath = ''
    if ($evName -eq 'CwdChanged') { $targetPath = [string]$ev.new_cwd }
    elseif ($evName -eq 'DirectoryAdded') { $targetPath = [string]$ev.directory }
    elseif ((@('Read','Edit','MultiEdit','Write') -contains $tool) -and $ev.tool_input -and $ev.tool_input.file_path) { $targetPath = [string]$ev.tool_input.file_path }
    $spanDir = ''
    foreach ($p in @($targetPath, $cwd)) {
        if (-not $p) { continue }
        $d = $p
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { $d = Split-Path -Parent $p }
        if ($d -and (Test-Path -LiteralPath $d -PathType Container)) { $spanDir = $d; break }
    }
    $spanRoot = $null
    if ($spanDir) { $spanRoot = Get-RepoRoot $spanDir }
    if ($spanRoot) {
        Add-SpanAttr 'vcs_repository_url_full' 'string' (Get-OriginUrl $spanRoot)
        Add-SpanAttr 'vcs_repository_name' 'string' (Get-RepoName $spanRoot)
        Add-SpanAttr 'vcs_ref_head_name' 'string' (Get-RepoBranch $spanRoot)
        Add-SpanAttr 'vcs_ref_head_revision' 'string' (Invoke-GitBounded $spanRoot @('rev-parse', 'HEAD'))
    }

    switch ($evName) {
        'SessionStart' {
            Add-SpanAttr 'session_source' 'string' $ev.source
            Add-SpanAttr 'model' 'string' $ev.model
        }
        'UserPromptSubmit' {
            Add-SpanAttr 'user_prompt_length' 'int' ([string]$ev.prompt).Length
        }
        'PostToolUse' {
            Add-SpanAttr 'tool_use_id' 'string' $ev.tool_use_id
            Add-SpanAttr 'gen_ai.tool_call_id' 'string' $ev.tool_use_id
            Add-SpanAttr 'tool_name' 'string' $ev.tool_name
            Add-SpanAttr 'tool_success' 'bool' $true
        }
        'PostToolUseFailure' {
            Add-SpanAttr 'tool_use_id' 'string' $ev.tool_use_id
            Add-SpanAttr 'gen_ai.tool_call_id' 'string' $ev.tool_use_id
            Add-SpanAttr 'tool_name' 'string' $ev.tool_name
            Add-SpanAttr 'tool_success' 'bool' $false
            Add-SpanAttr 'tool_interrupted' 'bool' $ev.is_interrupt
        }
        'SessionEnd' {
            Add-SpanAttr 'session_end_reason' 'string' $ev.reason
        }
    }

    # traceId = first 32 hex chars of SHA-256(session_id): every event of a
    # session lands in the same trace.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $traceId = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 32)
    $spanBytes = New-Object byte[] 8
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($spanBytes)
    $spanId = ($spanBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    # ns since epoch from ticks (100ns units); [long] holds it until year 2262.
    $endNs = ([DateTime]::UtcNow.Ticks - 621355968000000000) * 100
    $startNs = $endNs
    $dur = $ev.duration_ms
    if (($dur -is [int] -or $dur -is [long]) -and $dur -ge 0) { $startNs = $endNs - ([long]$dur * 1000000) }

    $spanPayload = '{"resourceSpans":[{"resource":{"attributes":[' + $spanRattrs + ']},' +
        '"scopeSpans":[{"scope":{"name":"agent-hook","version":"2.0.0"},' +
        '"spans":[{"traceId":"' + $traceId + '","spanId":"' + $spanId + '",' +
        '"name":"agent_hook.' + $evName + '","kind":1,' +
        '"startTimeUnixNano":"' + $startNs + '","endTimeUnixNano":"' + $endNs + '",' +
        '"attributes":[' + ($spanAttrs -join ',') + ']}]}]}]}'

    # --- Emit (errors swallowed; the hook must never disturb the session) ------
    try {
        Invoke-WebRequest -Uri "$ep/v1/traces" -Method Post `
            -Body ([Text.Encoding]::UTF8.GetBytes($spanPayload)) `
            -ContentType 'application/json' `
            -Headers @{ Authorization = $auth } `
            -TimeoutSec 5 -UseBasicParsing | Out-Null
    } catch {}

    # --- Metric: PostToolUse only ---------------------------------------------
    if ($sendMetric) {
        $nowNs = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() * 1000000000).ToString()

        function New-DataPoint([string]$name, [string]$branch) {
            '{"attributes":[' +
              '{"key":"session_id","value":{"stringValue":' + (ConvertTo-JsonString $sid) + '}},' +
              '{"key":"repository_name","value":{"stringValue":' + (ConvertTo-JsonString $name) + '}},' +
              '{"key":"branch_name","value":{"stringValue":' + (ConvertTo-JsonString $branch) + '}},' +
              '{"key":"user_email","value":{"stringValue":' + (ConvertTo-JsonString $email) + '}}' +
              '],"timeUnixNano":"' + $nowNs + '","asInt":"1"}'
        }

        # Dedupe by repo root AND by resolved name+branch (a linked worktree resolves
        # to a different root but the same owner/repo; emit one data point per
        # name+branch, so worktrees on different branches each report).
        $dps = @()
        $seenRoots = @(); $seenKeys = @()
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
            if (-not $name) { continue }
            $branch = Get-RepoBranch $root
            if ($seenKeys -contains "$name $branch") { continue }
            $seenKeys += "$name $branch"
            $dps += (New-DataPoint $name $branch)
        }
        if ($dps.Count -eq 0) { $dps += (New-DataPoint 'unknown' 'unknown') }

        $payload = '{"resourceMetrics":[{"resource":{"attributes":[' + $rattrs + ']},' +
            '"scopeMetrics":[{"scope":{"name":"repo-tracker","version":"1.0.0"},' +
            '"metrics":[{"name":"claude_code_session_repo_info","gauge":{"dataPoints":[' +
            ($dps -join ',') + ']}}]}]}]}'

        Invoke-WebRequest -Uri "$ep/v1/metrics" -Method Post `
            -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
            -ContentType 'application/json' `
            -Headers @{ Authorization = $auth } `
            -TimeoutSec 5 -UseBasicParsing | Out-Null
    }
} catch {}

exit 0
'@

# 4. Write as UTF-8 WITHOUT BOM (Set-Content -Encoding utf8 on Windows
#    PowerShell 5.1 would prepend a BOM).
[System.IO.File]::WriteAllText($TargetFile, $Content, (New-Object System.Text.UTF8Encoding $false))

Write-Host "Deployed Claude Code repo-tracker hook to $TargetFile"
exit 0
