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

# Codex PostToolUse hook that tracks repository names per session (Windows).
#
# Emits an OTLP/JSON gauge metric codex_session_repo_info with labels
# {session_id, repository_name, user_email} on each tool use. session_id is the
# Codex thread id (joins with conversation.id on Codex OTel log events);
# repository_name is the checkout's `origin` URL, credentials stripped.
#
# ZERO runtime assumptions: requires only Windows PowerShell 5.1, which ships
# with every Windows 10/11. No node, no python, no binaries to sign. git is
# optional: repo detection degrades to "unknown" without it, and every git call
# is bounded to 5s so a stale mount can never hang the session.
#
# Config is read from the same Codex TOML files that hold the [otel] blocks,
# reusing the metrics exporter's endpoint and headers — no separate hook
# credentials:
#   [otel.metrics_exporter.otlp-http]          endpoint
#   [otel.metrics_exporter.otlp-http.headers]  "Authorization",
#                                              "CX-Application-Name",
#                                              "CX-Subsystem-Name"
# File precedence (first non-empty value per key): -ConfigFile, then
# $env:CODEX_HOME\config.toml (default %USERPROFILE%\.codex), then the
# machine-wide %ProgramData%\OpenAI\Codex\config.toml — the same order Codex
# itself resolves them on Windows (user config overrides system defaults).
#
# user_email is decoded from the ChatGPT id_token in $CODEX_HOME\auth.json;
# it stays empty for API-key sign-in (Codex hook events carry no email field).
# Optional flags (manual testing): -ConfigFile, -AuthFile, -OtlpEndpoint,
# -Authorization.

param(
    [string]$ConfigFile = '',
    [string]$AuthFile = '',
    [string]$OtlpEndpoint = '',
    [string]$Authorization = ''
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

# Minimal TOML lookup: first `key = "value"` under an exact [section] header.
# Handles quoted and bare keys, basic ("...") and literal ('...') strings —
# the shapes the documented Coralogix template uses.
function Get-TomlValue([string]$Path, [string]$Section, [string]$Key) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $inSection = $false
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            $t = $line.Trim()
            if ($t -match '^\[+([^\]]*)\]+') {
                $inSection = ($Matches[1].Trim() -eq $Section)
                continue
            }
            if (-not $inSection) { continue }
            $eq = $t.IndexOf('=')
            if ($eq -lt 1) { continue }
            $k = $t.Substring(0, $eq).Trim().Trim('"')
            if ($k -ne $Key) { continue }
            $v = $t.Substring($eq + 1).Trim()
            if ($v.StartsWith('"')) {
                $end = $v.IndexOf('"', 1)
                if ($end -gt 0) { return $v.Substring(1, $end - 1) }
            } elseif ($v.StartsWith("'")) {
                $end = $v.IndexOf("'", 1)
                if ($end -gt 0) { return $v.Substring(1, $end - 1) }
            } else {
                return ($v -split '#', 2)[0].Trim()
            }
        }
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
    # --- Config resolution (user config overrides machine-wide on Windows) ----
    $codexHome = $env:CODEX_HOME
    if (-not $codexHome -and $env:USERPROFILE) { $codexHome = (Join-Path $env:USERPROFILE '.codex') }

    $candidates = @()
    if ($ConfigFile) { $candidates += $ConfigFile }
    if ($codexHome)  { $candidates += (Join-Path $codexHome 'config.toml') }
    if ($env:ProgramData) { $candidates += (Join-Path $env:ProgramData 'OpenAI\Codex\config.toml') }

    $msec = 'otel.metrics_exporter.otlp-http'
    function Get-CfgValue([string]$Section, [string]$Key) {
        foreach ($f in $candidates) {
            $v = Get-TomlValue $f $Section $Key
            if ($v) { return $v }
        }
        return $null
    }

    $endpoint = if ($OtlpEndpoint)  { $OtlpEndpoint }  else { Get-CfgValue $msec 'endpoint' }
    $auth     = if ($Authorization) { $Authorization } else { Get-CfgValue "$msec.headers" 'Authorization' }
    $app = Get-CfgValue "$msec.headers" 'CX-Application-Name'
    $sub = Get-CfgValue "$msec.headers" 'CX-Subsystem-Name'

    if (-not $endpoint -or -not $auth) { exit 0 }

    # --- Event (PostToolUse JSON on stdin) ------------------------------------
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    $ev = $raw | ConvertFrom-Json
    if (-not $ev -or -not $ev.session_id) { exit 0 }
    $sid = [string]$ev.session_id
    $cwd = [string]$ev.cwd
    $wd = ''
    if ($ev.tool_input -and $ev.tool_input.workdir) { $wd = [string]$ev.tool_input.workdir }
    if ($wd -and $cwd -and -not [IO.Path]::IsPathRooted($wd)) {
        $wd = Join-Path $cwd $wd  # relative workdir is cwd-relative
    }
    if (-not $cwd -and -not $wd) { exit 0 }

    # user_email: decode the id_token JWT payload from auth.json (ChatGPT
    # sign-in); silently empty for API-key auth or unreadable files.
    $email = ''
    try {
        $authJson = if ($AuthFile) { $AuthFile } elseif ($codexHome) { Join-Path $codexHome 'auth.json' } else { '' }
        if ($authJson -and (Test-Path -LiteralPath $authJson)) {
            $aj = [IO.File]::ReadAllText($authJson)
            if ($aj.Length -gt 0 -and $aj[0] -eq [char]0xFEFF) { $aj = $aj.Substring(1) }
            $a = $aj | ConvertFrom-Json
            if ($a.tokens -and $a.tokens.id_token) {
                $seg = ([string]$a.tokens.id_token -split '\.')[1]
                if ($seg) {
                    $seg = $seg.Replace('-', '+').Replace('_', '/')
                    switch ($seg.Length % 4) { 2 { $seg += '==' } 3 { $seg += '=' } }
                    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seg)) | ConvertFrom-Json
                    if ($claims.email) { $email = [string]$claims.email }
                }
            }
        }
    } catch {}

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
    foreach ($p in @($cwd, $wd)) {
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
    $rattrs = '{"key":"service.name","value":{"stringValue":"codex-hook"}}'
    if ($app) { $rattrs += ',{"key":"cx.application.name","value":{"stringValue":' + (ConvertTo-JsonString $app) + '}}' }
    if ($sub) { $rattrs += ',{"key":"cx.subsystem.name","value":{"stringValue":' + (ConvertTo-JsonString $sub) + '}}' }

    $payload = '{"resourceMetrics":[{"resource":{"attributes":[' + $rattrs + ']},' +
        '"scopeMetrics":[{"scope":{"name":"repo-tracker","version":"1.0.0"},' +
        '"metrics":[{"name":"codex_session_repo_info","gauge":{"dataPoints":[' +
        ($dps -join ',') + ']}}]}]}]}'

    # --- Emit (errors swallowed; the hook must never disturb the session) ------
    # The configured endpoint is the metrics exporter's URL, which already ends
    # in /v1/metrics in the documented template; append the path when given a
    # bare ingress host.
    $ep = $endpoint.TrimEnd('/')
    if ($ep -notmatch '^https?://') { $ep = "https://$ep" }
    if ($ep -notmatch '/v1/metrics$') { $ep = "$ep/v1/metrics" }

    Invoke-WebRequest -Uri $ep -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
        -ContentType 'application/json' `
        -Headers @{ Authorization = $auth } `
        -TimeoutSec 5 -UseBasicParsing | Out-Null
} catch {}

exit 0
