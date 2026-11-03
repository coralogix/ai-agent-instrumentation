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

# Codex CLI PostToolUse hook that tracks repository names per session (Windows).
#
# The Windows variant of hooks/codex.sh, emitting the same OTLP/JSON gauges
# with the same labels and the same counting rules:
#   codex_session_repo_info{session_id, repository_name[, agent_id]}
#   codex_session_branch_info{session_id, repository_name, branch_name}
#   codex_session_commits / codex_session_prs_opened
#   codex_session_lines_added / codex_session_lines_removed
# repository_name is the checkout's `origin` URL, credentials stripped.
# session_id equals the conversation.id on Codex's own OTel log events, so
# user attribution is a join, not another label on this metric.
#
# ZERO runtime assumptions: requires only Windows PowerShell 5.1, which ships
# with every Windows 10/11. No node, no python, no binaries to sign. git is
# optional: repo detection degrades to "unknown" without it, and every git
# call is bounded to 5s so a stale mount can never hang the session. Codex
# runs hook commands through cmd.exe on Windows; register this script via
# powershell.exe -File (see hooks.example.json, command_windows).
#
# Config comes from the same [otel] block Codex itself exports with - one
# config serves Codex's native telemetry and this hook, with no duplicated
# secrets:
#   [otel.exporter.otlp-http]          endpoint  (the /v1/logs suffix is
#                                       swapped for /v1/metrics)
#   [otel.exporter.otlp-http.headers]  Authorization, CX-Application-Name,
#                                       CX-Subsystem-Name
# It is read from the user's config ($env:CODEX_HOME\config.toml, default
# %USERPROFILE%\.codex\config.toml), then the machine-wide managed defaults
# (%ProgramData%\OpenAI\Codex\config.toml) - the same order Codex itself
# resolves them on Windows, where the user's file overrides the system one.
# CX_* environment variables (CX_OTLP_ENDPOINT / CX_API_KEY /
# CX_APPLICATION_NAME / CX_SUBSYSTEM_NAME - the same names codex/.env.example
# uses) are read as fallbacks for machines that configure Codex differently.
# The API key is passed to the HTTP call in process, never on a child
# process's argv where ps-style tooling would see it.
# Optional flags (manual testing): -ConfigFile, -OtlpEndpoint, -OtlpAuth,
# -ApplicationName, -SubsystemName.

param(
    [string]$ConfigFile = '',
    [string]$OtlpEndpoint = '',
    [string]$OtlpAuth = '',
    [string]$ApplicationName = '',
    [string]$SubsystemName = ''
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
# to objects - a PS 5.1 ConvertTo-Json quirk that would corrupt the OTLP shape.
function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { $s = '' }
    return ($s | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------------------
# Minimal TOML reader for the documented [otel.exporter.otlp-http] shape:
# tracks the current [section] (quotes in section parts ignored, so
# [otel.exporter."otlp-http"] matches too) and returns the first
# `key = "value"` in it. Basic strings honour \" escapes and drop trailing
# comments; literal strings are taken to the closing quote; bare values are
# cut at the first '#'. Deliberately not a general TOML parser - anything it
# cannot read falls through to the CX_* environment fallbacks.
# ---------------------------------------------------------------------------
function Get-TomlValue([string]$Path, [string]$Section, [string]$Key) {
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
        $inSection = $false
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            $t = $line.Trim()
            if ($t -match '^#') { continue }
            if ($t -match '^\[+([^\]]*)\]') {
                $name = $Matches[1] -replace '"', '' -replace '\s', ''
                $inSection = ($name -eq $Section)
                continue
            }
            if (-not $inSection) { continue }
            $eq = $t.IndexOf('=')
            if ($eq -lt 1) { continue }
            $k = $t.Substring(0, $eq).Trim().Trim('"')
            if ($k -ne $Key) { continue }
            $v = $t.Substring($eq + 1).Trim()
            if ($v.StartsWith('"')) {
                if ($v -match '^"((\\.|[^"\\])*)"') {
                    return $Matches[1].Replace('\"', '"').Replace('\\', '\')
                }
                return ($v.Trim('"') -split '"', 2)[0]
            }
            if ($v.StartsWith("'")) {
                $end = $v.IndexOf("'", 1)
                if ($end -gt 0) { return $v.Substring(1, $end - 1) }
                return $v.Trim("'")
            }
            return ($v -split '#', 2)[0].Trim()
        }
    } catch {}
    return $null
}

# ---------------------------------------------------------------------------
# Run git with a 5s bound so a hung fs/mount degrades instead of stalling the
# session. Returns @{ Code = <exit code, 124 on timeout/error>; Out = <stdout,
# trailing newline trimmed> }. Dynamic argument values are quoted with
# embedded quotes removed ('"' is illegal in Windows paths; a '"' in a git
# identity would only mis-filter, never execute).
# ---------------------------------------------------------------------------
$script:GitOk = $false
try { if (Get-Command git -ErrorAction SilentlyContinue) { $script:GitOk = $true } } catch {}

function Invoke-GitBounded([string]$Dir, [string[]]$GitArgs) {
    $res = @{ Code = 124; Out = '' }
    if (-not $script:GitOk) { return $res }
    try {
        $quoted = foreach ($a in (@('-C', $Dir) + $GitArgs)) {
            '"' + ($a -replace '"', '') + '"'
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $psi.Arguments = $quoted -join ' '
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit(5000)) {
            $res.Code = $p.ExitCode
            $res.Out = ([string]$outTask.Result).TrimEnd("`r", "`n")
            $null = $errTask.Result
        } else {
            try { $p.Kill() } catch {}
        }
    } catch {}
    return $res
}

try {
    # --- Config resolution: flags > config file > CX_* environment, where the
    # config file is -ConfigFile > user config.toml > machine-wide managed
    # defaults. A candidate without the exporter endpoint leaves the next file
    # in charge, mirroring codex.sh's managed-then-user fallback.
    $codexHome = $env:CODEX_HOME
    if (-not $codexHome -and $env:USERPROFILE) { $codexHome = Join-Path $env:USERPROFILE '.codex' }

    $cfg = ''
    if ($ConfigFile) {
        $cfg = $ConfigFile
    } else {
        $candidates = @()
        if ($codexHome) { $candidates += (Join-Path $codexHome 'config.toml') }
        if ($env:ProgramData) { $candidates += (Join-Path $env:ProgramData 'OpenAI\Codex\config.toml') }
        foreach ($f in $candidates) {
            if (Get-TomlValue $f 'otel.exporter.otlp-http' 'endpoint') { $cfg = $f; break }
        }
        if (-not $cfg -and $candidates.Count -gt 0) { $cfg = $candidates[0] }
    }

    $sec = 'otel.exporter.otlp-http'
    $ep = $OtlpEndpoint
    if (-not $ep) { $ep = Get-TomlValue $cfg $sec 'endpoint' }
    if (-not $ep) { $ep = $env:CX_OTLP_ENDPOINT }

    $auth = $OtlpAuth
    if (-not $auth) { $auth = Get-TomlValue $cfg "$sec.headers" 'Authorization' }
    if (-not $auth -and $env:CX_API_KEY) { $auth = "Bearer $($env:CX_API_KEY)" }

    # Application/subsystem are stamped only when explicitly configured;
    # otherwise routing falls to the API key's admin-panel configuration.
    $app = $ApplicationName
    if (-not $app) { $app = Get-TomlValue $cfg "$sec.headers" 'CX-Application-Name' }
    if (-not $app) { $app = $env:CX_APPLICATION_NAME }
    $sub = $SubsystemName
    if (-not $sub) { $sub = Get-TomlValue $cfg "$sec.headers" 'CX-Subsystem-Name' }
    if (-not $sub) { $sub = $env:CX_SUBSYSTEM_NAME }

    if (-not $ep -or -not $auth) { exit 0 }

    # --- Event (PostToolUse JSON on stdin) ------------------------------------
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    $ev = $raw | ConvertFrom-Json
    if (-not $ev -or -not $ev.session_id) { exit 0 }
    $sid = [string]$ev.session_id
    $evCwd = ''
    if ($ev.cwd) { $evCwd = [string]$ev.cwd }
    # Codex shell tools carry only {command}; file tools may carry a path -
    # probe the common keys and fall back to cwd alone when absent.
    $fp = ''
    if ($ev.tool_input) {
        if ($ev.tool_input.file_path) { $fp = [string]$ev.tool_input.file_path }
        elseif ($ev.tool_input.path) { $fp = [string]$ev.tool_input.path }
    }
    if (-not $evCwd -and -not $fp) { exit 0 }
    # For the PR counter only - see Update-Counts. Both may be empty or huge;
    # they are matched as text, never executed or shipped anywhere.
    $evCmd = ''
    if ($ev.tool_input -and $ev.tool_input.command -is [string]) { $evCmd = [string]$ev.tool_input.command }
    $evResp = ''
    if ($ev.tool_response -is [string]) { $evResp = [string]$ev.tool_response }
    # Present only inside a thread-spawned sub-agent: its own thread id, which
    # is the conversation.id on its Codex log events, while session_id stays
    # the root's - without it the sub-agent's tokens have no repo to join to.
    $agentId = ''
    if ($ev.agent_id) { $agentId = [string]$ev.agent_id }

    # --- Repo detection (git optional) ----------------------------------------
    function Get-RepoRoot([string]$Dir) {
        $r = Invoke-GitBounded $Dir @('rev-parse', '--show-toplevel')
        if ($r.Code -eq 0 -and $r.Out) { return $r.Out }
        return $null
    }

    function Get-RepoName([string]$Root) {
        # The origin URL as-is (directory-name fallback), with any
        # user:token@ userinfo stripped. An '@' after the authority belongs to
        # the path, and userinfo may itself contain '@' - cut at the
        # authority's LAST one.
        $r = Invoke-GitBounded $Root @('remote', 'get-url', 'origin')
        $name = ''
        if ($r.Code -eq 0 -and $r.Out) { $name = $r.Out }
        if (-not $name) { $name = Split-Path -Leaf $Root }
        $schemeEnd = $name.IndexOf('://')
        if ($schemeEnd -ge 0) {
            $rest = $name.Substring($schemeEnd + 3)
            $pathStart = $rest.IndexOf('/')
            $authority = if ($pathStart -ge 0) { $rest.Substring(0, $pathStart) } else { $rest }
            $at = $authority.LastIndexOf('@')
            if ($at -ge 0) {
                $name = $name.Substring(0, $schemeEnd + 3) + $authority.Substring($at + 1) + $rest.Substring($authority.Length)
            }
        }
        return $name
    }

    function Get-RepoBranch([string]$Root) {
        # symbolic-ref (not rev-parse) so a fresh repo with no commits still
        # resolves; not --short, which keeps "heads/" when a tag shares the
        # branch's name. With -q it exits 1 only for a detached HEAD, so a git
        # error or the 5s timeout never passes for one, and a partial name is
        # never emitted.
        $r = Invoke-GitBounded $Root @('symbolic-ref', '-q', 'HEAD')
        if ($r.Code -eq 0) {
            if ($r.Out) { return ($r.Out -replace '^refs/heads/', '') }
            return 'unknown'
        }
        if ($r.Code -eq 1) { return 'HEAD' }
        return 'unknown'
    }

    # --- Commit / line / PR counting (per session x repo, cumulative) ---------
    # Same rules as codex.sh: commits are VERIFIED against git, never parsed
    # out of command text. The state file keeps the last HEAD seen for this
    # (session, repo), the four running totals, and the SHA of every commit
    # already counted, so no commit is counted twice. A non-linear move (a
    # switch to a diverged branch, a rebase, an amend) only re-baselines; a
    # pull counts nothing of other people's work thanks to the author filter.
    # PRs count only on proof: `gh pr create` in the command AND the /pull/<n>
    # URL in the response. Totals are emitted EVERY time, zeros included.
    $tmpBase = $env:TEMP
    if (-not $tmpBase) { $tmpBase = [IO.Path]::GetTempPath() }
    $stateDir = Join-Path $tmpBase 'cx-codex-repo-tracker'
    try {
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        # Opportunistic cleanup; sessions do not outlive days of inactivity.
        Get-ChildItem -LiteralPath $stateDir -File |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } |
            Remove-Item -Force
    } catch {}

    function ConvertTo-Count($v) {
        if ($v -match '^[0-9]+$') { return [long]$v }
        return [long]0
    }

    $script:Commits = [long]0; $script:Prs = [long]0
    $script:Added = [long]0; $script:Removed = [long]0

    function Update-Counts([string]$Root) {
        $key = (("$sid|$Root") -replace '[^A-Za-z0-9]', '_')
        if ($key.Length -gt 200) { $key = $key.Substring(0, 200) }
        $sf = Join-Path $stateDir $key
        $head = ''
        $r = Invoke-GitBounded $Root @('rev-parse', 'HEAD')
        if ($r.Code -eq 0) { $head = $r.Out }
        $prev = ''; $seen = @(); $fresh = @()
        $script:Commits = [long]0; $script:Prs = [long]0
        $script:Added = [long]0; $script:Removed = [long]0
        if (Test-Path -LiteralPath $sf) {
            $lines = @([IO.File]::ReadAllLines($sf))
            if ($lines.Count -ge 1) { $prev = $lines[0] }
            if ($lines.Count -ge 2) { $script:Commits = ConvertTo-Count $lines[1] }
            if ($lines.Count -ge 3) { $script:Prs = ConvertTo-Count $lines[2] }
            if ($lines.Count -ge 4) { $script:Added = ConvertTo-Count $lines[3] }
            if ($lines.Count -ge 5) { $script:Removed = ConvertTo-Count $lines[4] }
            if ($lines.Count -ge 6) { $seen = @($lines[5..($lines.Count - 1)] | Where-Object { $_ }) }
        }

        $linear = $false
        if ($head -and $prev -and $head -ne $prev) {
            $r = Invoke-GitBounded $Root @('merge-base', '--is-ancestor', $prev, $head)
            $linear = ($r.Code -eq 0)
        }
        if ($linear) {
            $author = ''
            $r = Invoke-GitBounded $Root @('config', 'user.email')
            if ($r.Code -eq 0) { $author = $r.Out }
            # One log call yields the commits AND their numstat, so both share
            # one author filter and one timeout. log.mailmap=false matches
            # --author against the raw author: through .mailmap it would match
            # an identity other than user.email. A timed-out log is dropped
            # whole rather than counted partially.
            $logArgs = @('-c', 'log.mailmap=false', 'log', '--no-color', '--numstat', '--format=C %H')
            if ($author) { $logArgs += "--author=$author" }
            $logArgs += "$prev..$head"
            $r = Invoke-GitBounded $Root $logArgs
            if ($r.Code -eq 0) {
                $seenSet = @{}
                foreach ($s in $seen) { $seenSet[$s] = $true }
                $take = $false
                $newCommits = [long]0; $addSum = [long]0; $delSum = [long]0
                foreach ($line in ($r.Out -split "`n")) {
                    $line = $line.TrimEnd("`r")
                    if ($line -match '^C ([0-9a-f]+)$') {
                        $sha = $Matches[1]
                        $take = -not $seenSet.ContainsKey($sha)
                        if ($take) {
                            $newCommits++
                            $seenSet[$sha] = $true
                            $fresh += $sha
                        }
                        continue
                    }
                    if (-not $take) { continue }
                    # numstat rows are "added<TAB>removed<TAB>path"; a binary
                    # file prints "-" for both and is skipped. Only the sums
                    # and new SHAs leave this loop, never a path.
                    $parts = $line -split "`t"
                    if ($parts.Count -ge 3 -and $parts[0] -match '^[0-9]+$' -and $parts[1] -match '^[0-9]+$') {
                        $addSum += [long]$parts[0]
                        $delSum += [long]$parts[1]
                    }
                }
                $script:Commits += $newCommits
                $script:Added += $addSum
                $script:Removed += $delSum
            }
        }

        if ($evCmd -like '*gh pr create*' -and $evResp -match '/pull/[0-9]') {
            $script:Prs++
        }

        try {
            $out = @()
            $out += $(if ($head) { $head } else { $prev })
            $out += [string]$script:Commits
            $out += [string]$script:Prs
            $out += [string]$script:Added
            $out += [string]$script:Removed
            $out += $seen
            $out += $fresh
            $tmpFile = "$sf.tmp"
            [IO.File]::WriteAllLines($tmpFile, [string[]]$out)
            Move-Item -LiteralPath $tmpFile -Destination $sf -Force
        } catch {}
    }

    # --- Build OTLP/JSON payload (hand-built string; guaranteed array shape) ---
    $nowNs = ([long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) * 1000000000).ToString()
    $sidJson = ConvertTo-JsonString $sid

    $agentAttr = ''
    if ($agentId) {
        $agentAttr = ',{"key":"agent_id","value":{"stringValue":' + (ConvertTo-JsonString $agentId) + '}}'
    }

    function New-CountDp([string]$Name, [string]$Count, [string]$Extra) {
        return '{"attributes":[{"key":"session_id","value":{"stringValue":' + $sidJson +
            '}},{"key":"repository_name","value":{"stringValue":' + (ConvertTo-JsonString $Name) + '}}' + $Extra +
            '],"timeUnixNano":"' + $nowNs + '","asInt":"' + $Count + '"}'
    }

    function New-BranchDp([string]$Name, [string]$Branch) {
        return '{"attributes":[{"key":"session_id","value":{"stringValue":' + $sidJson +
            '}},{"key":"repository_name","value":{"stringValue":' + (ConvertTo-JsonString $Name) +
            '}},{"key":"branch_name","value":{"stringValue":' + (ConvertTo-JsonString $Branch) +
            '}}],"timeUnixNano":"' + $nowNs + '","asInt":"1"}'
    }

    # Dedupe by repo root AND by resolved name (two roots - e.g. a linked
    # worktree - share one origin URL; emit one data point per name). Branches
    # dedupe by name+branch instead, so worktrees of one repo on different
    # branches each report theirs. Commit/line/PR totals only for the repo the
    # command RAN in - a file-path root names where an edit landed, not where
    # git state moved. Only repo_info names the sub-agent - the counters stay
    # per session.
    $dps = @(); $branchDps = @()
    $commitDps = @(); $prDps = @(); $addedDps = @(); $removedDps = @()
    $seenRoots = @(); $seenNames = @(); $seenKeys = @()
    foreach ($p in @($evCwd, $fp)) {
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
        if ($seenKeys -notcontains "$name $branch") {
            $seenKeys += "$name $branch"
            $branchDps += (New-BranchDp $name $branch)
        }
        if ($seenNames -contains $name) { continue }
        $seenNames += $name
        $dps += (New-CountDp $name '1' $agentAttr)
        if ($p -eq $evCwd) {
            Update-Counts $root
            $commitDps += (New-CountDp $name ([string]$script:Commits) '')
            $prDps += (New-CountDp $name ([string]$script:Prs) '')
            $addedDps += (New-CountDp $name ([string]$script:Added) '')
            $removedDps += (New-CountDp $name ([string]$script:Removed) '')
        }
    }
    if ($dps.Count -eq 0) {
        $dps += (New-CountDp 'unknown' '1' $agentAttr)
        $branchDps += (New-BranchDp 'unknown' 'unknown')
    }

    $metrics = '{"name":"codex_session_repo_info","gauge":{"dataPoints":[' + ($dps -join ',') + ']}}'
    $metrics += ',{"name":"codex_session_branch_info","gauge":{"dataPoints":[' + ($branchDps -join ',') + ']}}'
    if ($commitDps.Count -gt 0) {
        $metrics += ',{"name":"codex_session_commits","gauge":{"dataPoints":[' + ($commitDps -join ',') + ']}}'
        $metrics += ',{"name":"codex_session_prs_opened","gauge":{"dataPoints":[' + ($prDps -join ',') + ']}}'
        $metrics += ',{"name":"codex_session_lines_added","gauge":{"dataPoints":[' + ($addedDps -join ',') + ']}}'
        $metrics += ',{"name":"codex_session_lines_removed","gauge":{"dataPoints":[' + ($removedDps -join ',') + ']}}'
    }

    $payload = '{"resourceMetrics":[{"resource":{"attributes":[' +
        '{"key":"service.name","value":{"stringValue":"codex-hook"}}]},' +
        '"scopeMetrics":[{"scope":{"name":"repo-tracker","version":"1.6.0"},' +
        '"metrics":[' + $metrics + ']}]}]}'

    # --- Emit (errors swallowed by design; the hook must never disturb the
    # session). The config.toml endpoint ends in the signal path Codex exports
    # to (/v1/logs); strip any /v1/<signal> suffix down to the ingress base,
    # then post to /v1/metrics. Application/subsystem ride as CX-* headers -
    # the same routing mechanism the [otel] block itself uses. Header values
    # are folded to one line so a CR/LF in a config value cannot smuggle its
    # own header.
    if ($ep -notmatch '^https?://') { $ep = "https://$ep" }
    $ep = $ep.TrimEnd('/')
    $ep = $ep -replace '/v1/(logs|traces|metrics)$', ''

    function Limit-OneLine([string]$s) { return ($s -replace "[`r`n]", '') }
    $headers = @{ Authorization = (Limit-OneLine $auth) }
    if ($app) { $headers['CX-Application-Name'] = Limit-OneLine $app }
    if ($sub) { $headers['CX-Subsystem-Name'] = Limit-OneLine $sub }

    Invoke-WebRequest -Uri "$ep/v1/metrics" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
        -ContentType 'application/json' `
        -Headers $headers `
        -TimeoutSec 5 -UseBasicParsing | Out-Null
} catch {}

exit 0
