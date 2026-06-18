# Licensed under the Apache License, Version 2.0 (the "License").
#
# Runs the Claude Code repo-tracker DEBUG hook (claude_debug.py) with a dummy
# PostToolUse event, so we can see exactly why the metric is/ isn't reaching
# Coralogix. All output is shown on the console AND written to a debug log file.
#
# USAGE (from the folder containing claude_debug.py):
#     powershell -ExecutionPolicy Bypass -File .\run-debug.ps1
#
# Optional: point at a script in a different location:
#     powershell -ExecutionPolicy Bypass -File .\run-debug.ps1 -Script C:\path\to\claude_debug.py

param(
    [string]$Script = (Join-Path $PSScriptRoot 'claude_debug.py')
)

$ErrorActionPreference = 'Stop'

# Find a python interpreter (works on Windows PowerShell 5.1 and PowerShell 7+)
$py = $null
foreach ($name in 'python', 'python3', 'py') {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd; break }
}
if (-not $py) { Write-Error 'No python/python3/py found on PATH.'; exit 1 }

# Where the debug log will land (also printed by the script itself)
$logFile = Join-Path $env:TEMP 'claude_hook_debug.log'
$env:CX_HOOK_DEBUG_LOG = $logFile

# Build a realistic dummy PostToolUse event. ConvertTo-Json handles all the
# backslash/quote escaping in the Windows path for us.
$event = @{
    session_id = 'debug-session-0001'
    cwd        = (Get-Location).Path
    tool_name  = 'Read'
    tool_input = @{ file_path = (Join-Path (Get-Location).Path 'README.md') }
    user_email = $env:USERNAME + '@debug.local'
} | ConvertTo-Json -Compress

Write-Host "Running debug hook: $($py.Source) $Script"
Write-Host "Dummy event: $event"
Write-Host "Debug log:   $logFile"
Write-Host ('=' * 72)

# Pipe the event into the debug hook; mirror everything to the console.
$event | & $py.Source $Script 2>&1 | Tee-Object -FilePath $logFile

Write-Host ('=' * 72)
Write-Host "Done. Send back BOTH the console output above and the file: $logFile"
