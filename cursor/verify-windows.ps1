# verify-windows.ps1 - test the Coralogix Cursor bootstrap on Windows.
#
# Run it next to the generated team-hook.windows.ps1:
#     powershell -ExecutionPolicy Bypass -File .\verify-windows.ps1
#
# It runs the bootstrap exactly as Cursor would (JSON event on stdin), waits for
# the detached installer, then checks every artifact and prints PASS/FAIL.
# Add -SendTestSpan to also push one span to Coralogix through the installed hook.

param(
    [string]$Bootstrap  = '.\team-hook.windows.ps1',
    [int]$TimeoutSec    = 180,
    [switch]$SendTestSpan,
    [switch]$Clean
)

$ErrorActionPreference = 'Continue'
$UserHome  = $env:USERPROFILE
$HooksDir  = Join-Path $UserHome '.cursor\hooks'
$HooksJson = Join-Path $UserHome '.cursor\hooks.json'

$pass = 0; $fail = 0
function Check($name, $ok, $detail = '') {
    if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  FAIL  $name  $detail" -ForegroundColor Red;  $script:fail++ }
}
function Section($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }

if ($Clean) {
    Section 'Cleaning previous install (fresh-machine simulation)'
    Remove-Item -Recurse -Force $HooksDir -ErrorAction SilentlyContinue
    Remove-Item -Force $HooksJson -ErrorAction SilentlyContinue
    # Uninstall the OTel packages so the pip step is genuinely exercised.
    foreach ($p in @('python','py','python3')) {
        if (Get-Command $p -ErrorAction SilentlyContinue) {
            & $p -m pip uninstall -y opentelemetry-sdk opentelemetry-exporter-otlp-proto-http 2>&1 | Out-Null
            break
        }
    }
    Write-Host '  cleaned'
}

Section 'Preflight'
Check 'bootstrap file present' (Test-Path -LiteralPath $Bootstrap) $Bootstrap
$pyFound = $null
foreach ($c in @('python','py','python3')) { if (Get-Command $c -ErrorAction SilentlyContinue) { $pyFound = $c; break } }
Check 'Python on PATH' ($null -ne $pyFound) 'tried python, py, python3'
if ($pyFound) { Write-Host ("        using: {0} - {1}" -f $pyFound, (& $pyFound --version 2>&1)) }
Write-Host  ("        PowerShell: {0}" -f $PSVersionTable.PSVersion)
if (-not (Test-Path -LiteralPath $Bootstrap)) { Write-Host 'Cannot continue.' -ForegroundColor Red; exit 1 }

Section 'Running the bootstrap the way Cursor does (JSON on stdin)'
$event = '{"hook_event_name":"workspaceOpen","workspaceRoots":["C:\\temp"]}'
$out = $event | powershell -ExecutionPolicy Bypass -NoProfile -File $Bootstrap 2>&1
Write-Host ("        stdout: {0}" -f ($out -join ' '))
Check 'bootstrap emitted {} (never blocks Cursor)' (($out -join '') -match '\{\}')

Section "Waiting up to $TimeoutSec s for the detached installer"
# hooks.json is written at installer step 5, BEFORE the pip step and before the
# bootstrap stamps its version marker. Waiting on hooks.json races the install;
# the stamp is the only true completion signal.
$sw = [Diagnostics.Stopwatch]::StartNew()
$jsonAt = $null
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    if (-not $jsonAt -and (Test-Path -LiteralPath $HooksJson)) {
        $jsonAt = $sw.Elapsed.TotalSeconds
        Write-Host ("        hooks.json after {0:N0}s (install still running)" -f $jsonAt)
    }
    if (Get-ChildItem -Path $HooksDir -Filter '.coralogix-bootstrap-*' -Force -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Seconds 3
}
Check 'hooks.json created' ($null -ne $jsonAt) ("waited {0:N0}s" -f $sw.Elapsed.TotalSeconds)
Check 'install completed (version stamp written)' ($null -ne (Get-ChildItem -Path $HooksDir -Filter '.coralogix-bootstrap-*' -Force -ErrorAction SilentlyContinue)) ("waited {0:N0}s" -f $sw.Elapsed.TotalSeconds)
Write-Host ("        install finished after {0:N0}s" -f $sw.Elapsed.TotalSeconds)

Section 'Installed files'
foreach ($f in @('coralogix_hook.py','coralogix_hook.ps1','coralogix_hook.cmd','coralogix_hook.env')) {
    $p = Join-Path $HooksDir $f
    $sz = if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).Length } else { 0 }
    Check "$f present" (Test-Path -LiteralPath $p) ''
    if ($sz) { Write-Host ("        {0} bytes" -f $sz) }
}

Section 'hooks.json contents'
if (Test-Path -LiteralPath $HooksJson) {
    $cfg = Get-Content -Raw -LiteralPath $HooksJson | ConvertFrom-Json
    $events = @($cfg.hooks.PSObject.Properties.Name)
    Check 'all 18 events registered' ($events.Count -eq 18) ("found {0}: {1}" -f $events.Count, ($events -join ','))
    $cmds = @($cfg.hooks.PSObject.Properties.Value | ForEach-Object { $_ } | ForEach-Object { $_.command } | Sort-Object -Unique)
    Check 'every event points at coralogix_hook.cmd' (($cmds.Count -eq 1) -and ($cmds[0] -like '*coralogix_hook.cmd')) ($cmds -join ' | ')
}

Section 'Credentials file'
$envFile = Join-Path $HooksDir 'coralogix_hook.env'
if (Test-Path -LiteralPath $envFile) {
    $lines = Get-Content -LiteralPath $envFile
    Check 'endpoint set'    (($lines -match '^CX_OTLP_ENDPOINT=https://').Count -gt 0)
    Check 'application set' (($lines -match '^CX_APPLICATION_NAME=\S').Count -gt 0)
    Check 'masking on'      (($lines -match '^CURSOR_MASK_PROMPTS=true').Count -gt 0) 'prompts would be sent in full'
    $acl = (icacls $envFile) -join ' '
    Check 'ACL restricted to this user' ($acl -notmatch 'BUILTIN\\Users') 'API key readable by all local users'
    Write-Host ("        icacls: {0}" -f (($acl -split "`n")[0]))
}

Section 'Python dependencies (the pip step)'
if ($pyFound) {
    & $pyFound -c "import opentelemetry.sdk, opentelemetry.exporter.otlp.proto.http.trace_exporter; print('importable')" 2>&1 | ForEach-Object { Write-Host "        $_" }
    $depOk = $LASTEXITCODE -eq 0
    Check 'OTel SDK + HTTP exporter importable' $depOk 'pip step did not complete'
}

if ($SendTestSpan) {
    Section 'Sending one real span through the installed hook'
    $cmdShim = Join-Path $HooksDir 'coralogix_hook.cmd'
    $evt = '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"win-verify-1","generation_id":"g1","prompt":"windows verification","model":"claude-opus-5"}'
    $r = $evt | & $cmdShim 2>&1
    Write-Host ("        hook output: {0}" -f ($r -join ' '))
    Check 'hook responded with {}' (($r -join '') -match '\{\}')
    Write-Host '        Now query Coralogix:' -ForegroundColor Yellow
    Write-Host "        source spans | filter `$l.applicationName == 'cursor' | countby `$l.operationName"
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) {
    Write-Host ''
    Write-Host 'Debugging: set CX_OTLP_DEBUG=true in coralogix_hook.env and re-run with -SendTestSpan,' -ForegroundColor Yellow
    Write-Host 'or run the bootstrap without -File to see the installer output inline.' -ForegroundColor Yellow
}
exit $(if ($fail) { 1 } else { 0 })
