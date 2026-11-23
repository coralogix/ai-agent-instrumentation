# ==============================================================================
# Windows Deployment Script: Deploy the Claude Code session-spans hook
# Target Path: C:\ProgramData\Coralogix\claude-code\claude.ps1
#
# Run as Administrator (or via your MDM, e.g. Intune, as SYSTEM). Writes the
# session-spans hook to a stable machine-wide path so it can be referenced from
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

# Claude Code hook (Windows): one span per session event, so AI Center can link
# each session to the git branches it works on.
#
# Sends one OTLP/JSON span "agent_hook.<event>" to /v1/traces on SessionStart,
# UserPromptSubmit, CwdChanged, SessionEnd, and PostToolUse of Edit, MultiEdit,
# Write and NotebookEdit. Other events and tools are ignored. The span holds the
# session id, the event name, the tool name of an edit, and the host URL,
# owner/repo and branch of the repository's origin. It never holds prompts,
# tool input or output, local paths or credentials.
#
# The hook reads the event, stamps its time and starts a hidden PowerShell
# sender (this script with -Send) that runs git and the POST, so the session
# never waits, and the send survives the SessionEnd budget and the end of
# `claude -p`.
#
# Requires only Windows PowerShell 5.1, which ships with Windows 10/11.
# git is optional: without it the span has no vcs_* attributes.
#
# Config is read in Claude Code's managed-source order (the server-managed
# cache, the policy registry value HKLM\SOFTWARE\Policies\ClaudeCode\Settings,
# managed-settings.json), then the user settings, because Claude Code does not
# reliably pass its `env` block to hooks (claude-code#20112):
#   OTEL_EXPORTER_OTLP_ENDPOINT   (bare URL)
#   OTEL_EXPORTER_OTLP_HEADERS    ("Authorization=Bearer <KEY>")
#   OTEL_RESOURCE_ATTRIBUTES      ("cx.application.name=x,cx.subsystem.name=y")
# Legacy CX_HOOK_* keys (CX_HOOK_OTLP_ENDPOINT / CX_HOOK_API_KEY /
# CX_HOOK_APPLICATION_NAME / CX_HOOK_SUBSYSTEM_NAME) are read as fallbacks.
# Optional flags (manual testing): -SettingsFile, -OtlpEndpoint, -OtlpHeaders,
# -ResourceAttributes.
# A failed send writes its time and HTTP status (never the key) to
# %USERPROFILE%\.claude\coralogix-hook-last-error.txt.

param(
    [string]$SettingsFile = '',
    [string]$OtlpEndpoint = '',
    [string]$OtlpHeaders = '',
    [string]$ResourceAttributes = '',
    [switch]$Send
)

$ErrorActionPreference = 'SilentlyContinue'

$FieldsVariable = 'CX_HOOK_SPAN_FIELDS'
$PolicyKey = 'SOFTWARE\Policies\ClaudeCode'

try {
    # PS 5.1 may default to TLS 1.0; Coralogix ingress requires TLS 1.2+.
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# JSON-escape a scalar via ConvertTo-Json (returns the value WITH surrounding
# quotes, all control/special chars correctly escaped). The payload structure
# itself is hand-built as a string so single-element arrays are never unwrapped
# to objects, a PS 5.1 ConvertTo-Json quirk that would corrupt the OTLP shape.
function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { $s = '' }
    return ($s | ConvertTo-Json -Compress)
}

# Quote one argument for a Windows command line (CommandLineToArgvW rules), so
# a path ending in a backslash or holding a quote reaches the child intact.
function ConvertTo-ProcessArgument([string]$s) {
    if ($null -eq $s) { $s = '' }
    return '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function ConvertFrom-EnvBlock([string]$Text) {
    try {
        if (-not $Text) { return $null }
        if ($Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
        $j = $Text | ConvertFrom-Json
        if ($j -and $j.env) { return $j.env }
    } catch {}
    return $null
}

function Read-EnvBlock([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        return (ConvertFrom-EnvBlock ([IO.File]::ReadAllText($Path)))
    } catch {}
    return $null
}

# The Windows MDM policy: registry value Settings, the managed-settings.json
# text. The 64-bit view, which Claude Code reads, even from a 32-bit PowerShell.
function Read-PolicyEnvBlock {
    try {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $hklm.OpenSubKey($PolicyKey)
        if ($key) {
            $t = $key.GetValue('Settings')
            $key.Close()
            if ($t -is [string]) { return (ConvertFrom-EnvBlock $t) }
        }
    } catch {}
    return $null
}

# Every env key from the first settings source that defines it, in Claude Code's
# managed-source order, so a defined empty value turns the key off as it does
# for Claude Code.
function Get-MergedEnv {
    $blocks = New-Object System.Collections.ArrayList
    if ($SettingsFile) { [void]$blocks.Add((Read-EnvBlock $SettingsFile)) }
    $userHome = $env:USERPROFILE
    if ($userHome) { [void]$blocks.Add((Read-EnvBlock (Join-Path $userHome '.claude\remote-settings.json'))) }
    [void]$blocks.Add((Read-PolicyEnvBlock))
    [void]$blocks.Add((Read-EnvBlock 'C:\Program Files\ClaudeCode\managed-settings.json'))
    if ($userHome) { [void]$blocks.Add((Read-EnvBlock (Join-Path $userHome '.claude\settings.json'))) }
    $merged = @{}
    foreach ($e in $blocks) {
        if (-not $e) { continue }
        foreach ($p in $e.PSObject.Properties) {
            if (-not $merged.ContainsKey($p.Name)) { $merged[$p.Name] = [string]$p.Value }
        }
    }
    return $merged
}

# Run git with a 5s bound so a hung fs/mount degrades instead of stalling. No
# GIT_* variable reaches git: an inherited GIT_DIR would point `git -C` at
# another repository. Returns trimmed stdout on exit code 0, else ''.
function Invoke-GitBounded([string]$Dir, [string[]]$GitArgs) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $psi.Arguments = '-C ' + (ConvertTo-ProcessArgument $Dir) + ' ' + ($GitArgs -join ' ')
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($k in @($psi.EnvironmentVariables.Keys)) {
            if ($k -like 'GIT_*') { $psi.EnvironmentVariables.Remove($k) }
        }
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit(5000)) {
            if ($p.ExitCode -eq 0) { return ([string]$outTask.Result).Trim() }
        } else {
            try { $p.Kill() } catch {}
        }
    } catch {}
    return ''
}

# owner/repo, as GitHub events name it, so hook and PR rows join.
function Get-RepositoryName([string]$Path) {
    $p = $Path.Trim('/')
    if ($p.EndsWith('.git', [StringComparison]::Ordinal)) { $p = $p.Substring(0, $p.Length - 4) }
    $parts = $p.Split([char]'/')
    if ($parts.Count -ge 2) { return ($parts[$parts.Count - 2] + '/' + $parts[$parts.Count - 1]) }
    return $p
}

# Origin URL without user info, query or fragment, and owner/repo. $null for an
# origin on this machine: /path, C:\path, file://, or a remote helper address
# such as hg::/path.
function Get-Remote([string]$Url) {
    if (-not $Url) { return $null }
    if ($Url.Contains('://')) {
        $scheme = ''; $rest = $Url
        $m = [regex]::Match($Url, '^([A-Za-z][A-Za-z0-9+.-]*):')
        if ($m.Success) { $scheme = $m.Groups[1].Value.ToLowerInvariant(); $rest = $Url.Substring($m.Length) }
        $netloc = ''
        if ($rest.StartsWith('//')) {
            $rest = $rest.Substring(2)
            $i = $rest.IndexOfAny([char[]]'/?#')
            if ($i -lt 0) { $netloc = $rest; $rest = '' }
            else { $netloc = $rest.Substring(0, $i); $rest = $rest.Substring($i) }
        }
        if ($netloc.Contains('[') -ne $netloc.Contains(']')) { return $null }
        $path = ($rest -split '[?#]', 2)[0]
        $hostPart = $netloc.Substring($netloc.LastIndexOf('@') + 1)
        if ($scheme -eq 'file' -or -not $hostPart) { return $null }
        return @(($scheme + '://' + $hostPart + $path), (Get-RepositoryName $path))
    }
    $colon = $Url.IndexOf(':')
    if ($colon -lt 0) { return $null }
    $prefix = $Url.Substring(0, $colon)
    $path = $Url.Substring($colon + 1)
    $hostPart = $prefix.Substring($prefix.LastIndexOf('@') + 1)
    if ($path.StartsWith(':') -or $prefix.Contains('/') -or $prefix.Contains('\') -or $hostPart.Length -lt 2) { return $null }
    return @(('ssh://' + $hostPart + '/' + $path.TrimStart('/')), (Get-RepositoryName $path))
}

function Write-LastError([string]$Message) {
    try {
        if (-not $env:USERPROFILE) { return }
        $dir = Join-Path $env:USERPROFILE '.claude'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
        $line = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) + ' ' + $Message + "`n"
        [IO.File]::WriteAllText((Join-Path $dir 'coralogix-hook-last-error.txt'), $line, (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

try {
    # --- Config resolution (same precedence as the macOS hook) ---------------
    $merged = Get-MergedEnv

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

    # Off until an endpoint and a key are configured.
    if (-not $endpoint -or -not $auth) { exit 0 }

    if (-not $Send) {
        # --- Event (hook JSON on stdin): only what the span needs leaves -------
        $stdin = [Console]::OpenStandardInput()
        $buffer = New-Object System.IO.MemoryStream
        $stdin.CopyTo($buffer)
        $raw = [Text.Encoding]::UTF8.GetString($buffer.ToArray())
        if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
        $ev = $raw | ConvertFrom-Json
        if (-not $ev) { exit 0 }
        $sid = [string]$ev.session_id
        $evName = [string]$ev.hook_event_name
        if (-not $sid -or -not $evName) { exit 0 }

        $tool = ''; $file = ''
        if (@('SessionStart', 'UserPromptSubmit', 'CwdChanged', 'SessionEnd') -ccontains $evName) {
        } elseif ($evName -ceq 'PostToolUse') {
            # The edit goes to the branch of the edited file, which can differ from the cwd's.
            $tool = [string]$ev.tool_name
            if (@('Edit', 'MultiEdit', 'Write') -ccontains $tool) {
                if ($ev.tool_input) { $file = [string]$ev.tool_input.file_path }
            } elseif ($tool -ceq 'NotebookEdit') {
                if ($ev.tool_input) { $file = [string]$ev.tool_input.notebook_path }
            } else { exit 0 }
        } else { exit 0 }

        # The event time: the sender can spend seconds in git. ns since epoch
        # from ticks (100ns units); [long] holds it until year 2262.
        $timeNs = ([DateTime]::UtcNow.Ticks - 621355968000000000) * 100

        $dir = ''
        if ($file) { try { $dir = [string][IO.Path]::GetDirectoryName($file) } catch {} }
        if (-not $dir) { $dir = [string]$ev.new_cwd }
        if (-not $dir) { $dir = [string]$ev.cwd }

        # A span inside a turn joins the turn's trace; the other spans of a
        # session share one trace. Claude Code sets TRACEPARENT to the turn's
        # span only during a turn with its tracing on; otherwise it is inherited
        # from the shell and names another trace.
        $traceId = ''; $parentId = ''
        if (@('SessionStart', 'SessionEnd') -cnotcontains $evName) {
            $tracing = $false
            foreach ($flag in @('CLAUDE_CODE_ENHANCED_TELEMETRY_BETA', 'ENABLE_ENHANCED_TELEMETRY_BETA')) {
                $v = [Environment]::GetEnvironmentVariable($flag)
                if (-not $v) { $v = $merged[$flag] }
                if (@('1', 'true', 'yes', 'on') -contains ([string]$v).Trim().ToLowerInvariant()) { $tracing = $true }
            }
            $tm = [regex]::Match([string]$env:TRACEPARENT, '^[0-9a-f]{2}-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}\z')
            if ($tracing -and $tm.Success) {
                $turnTrace = $tm.Groups[1].Value; $turnSpan = $tm.Groups[2].Value
                if ($turnTrace.Trim('0') -and $turnSpan.Trim('0')) { $traceId = $turnTrace; $parentId = $turnSpan }
            }
        }
        if (-not $traceId) {
            # First 32 hex chars of SHA-256(session_id).
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $traceId = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 32)
        }

        $fields = '{"session_id":' + (ConvertTo-JsonString $sid) +
            ',"hook_event":' + (ConvertTo-JsonString $evName) +
            ',"tool_name":' + (ConvertTo-JsonString $tool) +
            ',"directory":' + (ConvertTo-JsonString $dir) +
            ',"time_unix_nano":"' + $timeNs + '"' +
            ',"trace_id":"' + $traceId + '"' +
            ',"parent_span_id":"' + $parentId + '"}'

        # Git and the send run in a detached, hidden child, so the session never
        # waits for them, and they outlive the 1.5 s SessionEnd budget and the
        # end of a `claude -p` run. The child inherits the fields through this
        # process's environment, not through stdin or its command line.
        [Environment]::SetEnvironmentVariable($FieldsVariable, $fields)
        $childArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ' +
            (ConvertTo-ProcessArgument $PSCommandPath) + ' -Send'
        if ($SettingsFile) { $childArgs += ' -SettingsFile ' + (ConvertTo-ProcessArgument $SettingsFile) }
        if ($OtlpEndpoint) { $childArgs += ' -OtlpEndpoint ' + (ConvertTo-ProcessArgument $OtlpEndpoint) }
        if ($OtlpHeaders) { $childArgs += ' -OtlpHeaders ' + (ConvertTo-ProcessArgument $OtlpHeaders) }
        if ($ResourceAttributes) { $childArgs += ' -ResourceAttributes ' + (ConvertTo-ProcessArgument $ResourceAttributes) }
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $powershell -ArgumentList $childArgs -WindowStyle Hidden
        exit 0
    }

    # --- Sender (-Send): git, payload, POST ----------------------------------
    $fieldsJson = [Environment]::GetEnvironmentVariable($FieldsVariable)
    [Environment]::SetEnvironmentVariable($FieldsVariable, $null)
    if (-not $fieldsJson) { exit 0 }
    $f = $fieldsJson | ConvertFrom-Json
    if (-not $f -or -not $f.session_id -or -not $f.hook_event -or -not $f.trace_id) { exit 0 }

    try {
        $spanAttrs = New-Object System.Collections.ArrayList
        function Add-SpanAttr([string]$Key, [string]$Value) {
            if (-not $Value) { return }
            [void]$spanAttrs.Add('{"key":"' + $Key + '","value":{"stringValue":' + (ConvertTo-JsonString $Value) + '}}')
        }

        Add-SpanAttr 'agent_name' 'claude-code'
        Add-SpanAttr 'hook_event' ([string]$f.hook_event)
        Add-SpanAttr 'session_id' ([string]$f.session_id)
        Add-SpanAttr 'tool_name' ([string]$f.tool_name)
        $dir = [string]$f.directory
        if ($dir) {
            $origin = Get-Remote (Invoke-GitBounded $dir @('remote', 'get-url', 'origin'))
            if ($origin) {
                Add-SpanAttr 'vcs_repository_url_full' $origin[0]
                Add-SpanAttr 'vcs_repository_name' $origin[1]
                # Not --short: it prints heads/<name> when a tag has the same name. Fails on a detached HEAD.
                $ref = Invoke-GitBounded $dir @('symbolic-ref', '--quiet', 'HEAD')
                if ($ref.StartsWith('refs/heads/', [StringComparison]::Ordinal)) {
                    Add-SpanAttr 'vcs_ref_head_name' $ref.Substring('refs/heads/'.Length)
                }
            }
        }

        $rattrs = '{"key":"service.name","value":{"stringValue":"claude-code-hook"}}' +
            ',{"key":"cx.source.integration.type","value":{"stringValue":"claude_code_agent"}}'
        if ($app) { $rattrs += ',{"key":"cx.application.name","value":{"stringValue":' + (ConvertTo-JsonString $app) + '}}' }
        if ($sub) { $rattrs += ',{"key":"cx.subsystem.name","value":{"stringValue":' + (ConvertTo-JsonString $sub) + '}}' }

        $spanBytes = New-Object byte[] 8
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($spanBytes)
        $spanId = ($spanBytes | ForEach-Object { $_.ToString('x2') }) -join ''

        $parent = ''
        if ($f.parent_span_id) { $parent = ',"parentSpanId":"' + [string]$f.parent_span_id + '"' }
        $timeNs = [string]$f.time_unix_nano

        $payload = '{"resourceSpans":[{"resource":{"attributes":[' + $rattrs + ']},' +
            '"scopeSpans":[{"scope":{"name":"claude-code-hook"},' +
            '"spans":[{"traceId":"' + [string]$f.trace_id + '","spanId":"' + $spanId + '"' + $parent + ',' +
            '"name":' + (ConvertTo-JsonString ('agent_hook.' + [string]$f.hook_event)) + ',"kind":1,' +
            '"startTimeUnixNano":"' + $timeNs + '","endTimeUnixNano":"' + $timeNs + '",' +
            '"attributes":[' + ($spanAttrs -join ',') + ']}]}]}]}'

        $ep = $endpoint.TrimEnd('/')
        if ($ep -notmatch '^https?://') { $ep = "https://$ep" }

        # No redirect is followed: it would carry the key to another URL. PS 5.1
        # returns a 3xx as the response or reports it as an error: either way it
        # is recorded as a failure.
        $sendErrors = $null
        $resp = Invoke-WebRequest -Uri "$ep/v1/traces" -Method Post `
            -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
            -ContentType 'application/json' `
            -Headers @{ Authorization = $auth } `
            -MaximumRedirection 0 -TimeoutSec 5 -UseBasicParsing `
            -ErrorAction SilentlyContinue -ErrorVariable sendErrors
        if ($resp) {
            $code = [int]$resp.StatusCode
            if ($code -ge 300) { Write-LastError "HTTP $code" }
        } elseif ($sendErrors) {
            throw $sendErrors[0].Exception
        }
    } catch {
        # The sender runs detached, so this file is the only trace of a failure.
        # Only the status or the exception type: a message could echo the key.
        $ex = $_.Exception
        while ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
        if ($ex -is [System.Net.WebException] -and $ex.Response) {
            Write-LastError ('HTTP ' + [int]$ex.Response.StatusCode)
        } else {
            Write-LastError $ex.GetType().Name
        }
    }
} catch {}

exit 0
'@

# 4. Write as UTF-8 WITHOUT BOM (Set-Content -Encoding utf8 on Windows
#    PowerShell 5.1 would prepend a BOM).
[System.IO.File]::WriteAllText($TargetFile, $Content, (New-Object System.Text.UTF8Encoding $false))

Write-Host "Deployed Claude Code session-spans hook to $TargetFile"
exit 0
