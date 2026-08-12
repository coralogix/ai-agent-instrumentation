# Deploy Cursor telemetry to your whole team from the Cursor dashboard

Complete A-Z runbook. No MDM, no per-developer steps. Works for any Coralogix
region. Requires Cursor **Enterprise** and a Cursor team admin account.

Verified end-to-end: dashboard entry -> Cursor cloud sync -> developer
machine -> 18 hooks installed -> spans in Coralogix.

| Platform | Status |
|---|---|
| macOS | Verified end-to-end, including Cursor cloud delivery |
| Windows Server 2022 / PowerShell 5.1 | Verified on a clean machine: 17/17 checks, dependencies installed from scratch, span confirmed in Coralogix |
| Linux | Same script path as macOS |

A machine with no Python is a verified no-op: the hook prints `{}`, exits 0,
creates nothing, and leaves no lock behind. Cursor is unaffected.

---

## What you need before you start

| | |
|---|---|
| Cursor plan | Enterprise (team hooks are Enterprise-only) |
| Cursor role | Team admin |
| Coralogix | A **Send-Your-Data** API key (ingest-only) |
| Coralogix | Your account's OTLP ingress endpoint - see step 2 |
| Developer machines | Python 3.8+ (`python3` on macOS/Linux, `python`/`py -3` on Windows) |

If Python is missing on a machine, the hook exits silently and Cursor is
unaffected. Nothing breaks; that machine just sends no telemetry.

---

## Step 1 - Create a Send-Your-Data API key

Coralogix UI -> **Data Flow -> API Keys -> Send-Your-Data**. Copy the key.

This key can only ingest. It cannot read or delete data. It will be embedded in
the script you paste into the Cursor dashboard, so treat it like any other
fleet-deployed ingest credential.

## Step 2 - Find your OTLP endpoint

Your endpoint is `https://ingress.<your-coralogix-domain>`. Look at the domain
you use to log in to Coralogix:

| Your Coralogix domain | OTLP endpoint |
|---|---|
| `us1.coralogix.com` | `https://ingress.us1.coralogix.com` |
| `us2.coralogix.com` | `https://ingress.us2.coralogix.com` |
| `eu1.coralogix.com` | `https://ingress.eu1.coralogix.com` |
| `eu2.coralogix.com` | `https://ingress.eu2.coralogix.com` |
| `ap1.coralogix.com` | `https://ingress.ap1.coralogix.com` |
| `ap2.coralogix.com` | `https://ingress.ap2.coralogix.com` |
| `ap3.coralogix.com` | `https://ingress.ap3.coralogix.com` |

Dedicated or single-tenant domains follow the same rule: prefix `ingress.` to
your domain. If you run your own OTel collector, point at that instead; only
`https://` is accepted (plus `http://localhost` for a local collector), so the
API key is never sent in cleartext.

## Step 3 - Generate the two script bodies

From a checkout of the repo's `cursor/` directory:

```bash
./make-team-hook.py \
  --repo        . \
  --api-key     <your-send-your-data-key> \
  --endpoint    https://ingress.<your-domain> \
  --application cursor \
  --subsystem   cursor-sessions
```

Optional flags: `--no-mask-prompts` sends full prompt and response text
(masked by default), `--out-dir <dir>` changes the output location.

This writes two self-contained files, roughly 17 KB each:

- `out/team-hook.unix.sh` - for macOS and Linux
- `out/team-hook.windows.ps1` - for Windows

Each one carries `install.sh` (or `install.ps1`) and `hook.py` inside itself,
gzip + base64. Nothing is downloaded at run time, so locked-down networks are
fine.

Both files embed your API key. They are written mode `600` (owner-only) and are
git-ignored, but they are still credential files: delete the output directory
once you have pasted the bodies into the dashboard, and regenerate when you need
them again.

## Step 4 - Add the macOS/Linux hook in the dashboard

Cursor dashboard -> **Rules, Commands, Hooks** -> **Hooks** tab -> **Add**:

| Field | Value |
|---|---|
| Hook Name | `coralogix-bootstrap.sh` |
| Hook Type | Command Hook |
| Hook Step | **Workspace Open** (cannot be changed later) |
| Script Content | paste the entire contents of `out/team-hook.unix.sh` |
| Operating Systems | **Linux** and **Macintosh** |
| Active | on |

Click **Create Hook**.

## Step 5 - Add the Windows hook

Repeat step 4 with:

- Hook Name `coralogix-bootstrap.ps1`
- Script Content: `out/team-hook.windows.ps1`
- Operating Systems: **Windows** only

Two entries are required because one entry carries one script body, and one
shell cannot serve both platforms. Skip this step if your fleet has no Windows.

## Step 6 - Pilot before the full rollout (recommended)

Team hooks reach **everyone on the team**, with no group or user targeting. To
pilot, create a small team in your organization and put the pilot users in it.

Important caveat found in testing: a developer's Cursor **app** must actually
resolve to the pilot team, not just be a member of it. Cursor fetches hooks for
the app's active team only, so a member of both teams whose app still points at
the main team receives nothing. Confirm on the pilot machine with step 7.

## Step 7 - Verify on a developer machine

Have the developer open a **new Cursor window**. Within about a minute:

```bash
# 1. Cursor delivered the hook
ls ~/.cursor/managed/team_<TEAM_ID>/hooks/
#    -> coralogix-bootstrap.sh

# 2. The installer ran
ls -la ~/.cursor/hooks/
#    -> coralogix_hook.py, coralogix_hook.sh, coralogix_hook.env (mode 600),
#       .coralogix-bootstrap-<version>

# 3. All 18 events registered
python3 -c "import json,pathlib;d=json.load(open(pathlib.Path.home()/'.cursor/hooks.json'));print(len(d['hooks']),'events')"
#    -> 18 events
```

**Wait for the version stamp, not `hooks.json`.** The installer writes
`hooks.json` before it installs the Python dependencies, so `hooks.json` appears
within seconds while the install is still running. The
`.coralogix-bootstrap-<version>` marker is written last and is the only reliable
"finished" signal. On a clean Windows box the gap was 6s to `hooks.json`, 12s to
the stamp; a slow network makes it longer.

Cursor's own log confirms delivery. **View -> Output -> Hooks**, or:

```bash
grep -h "team hook" ~/Library/Application\ Support/Cursor/logs/*/window*/output_*/cursor.hooks.*.log | tail
#    -> Team hooks updated: 1 hook steps configured
```

Windows paths: `%USERPROFILE%\.cursor\managed\team_<id>\hooks\`,
`%USERPROFILE%\.cursor\hooks\`, `%APPDATA%\Cursor\logs\`.

No restart is needed. Cursor watches `hooks.json` and reloads it automatically,
so telemetry begins in the same session.

## Step 8 - Verify data in Coralogix

Use the agent in Cursor for a minute (send a prompt, let it edit a file), then
query spans:

```
source spans
| filter $l.applicationName == 'cursor'
| countby $l.operationName
| sort by _count desc
```

Expect span names like `cursor.sessionStart`, `cursor.beforeSubmitPrompt`,
`cursor.preToolUse`, `cursor.afterFileEdit`, `cursor.stop`. Each Cursor
conversation is one trace, with `cursor.sessionStart` as the root span.

Allow a few minutes before concluding nothing arrived - spans are queryable a
little after ingest, so an immediate query can come back empty while the data is
in flight. To confirm a specific machine's hook is exporting, set
`CX_OTLP_DEBUG=true` in its `coralogix_hook.env`: a successful send logs
`exported span event=... trace_id=...`, and a bad key logs a loud `403`.

## Step 9 - Roll out to the whole team

Repeat steps 4 and 5 on your main team. Every member picks it up on their next
workspace open; new joiners are covered automatically on first launch.

---

## Operating it

**Upgrade.** Bump `VERSION` in `make-team-hook.py`, regenerate, and paste the
new body over the existing hook's Script Content. Each machine reinstalls once on
its next workspace open, then goes back to a no-op.

**Rotate the API key.** Regenerate with the new key and replace the script body.
Machines pick it up on the next workspace open.

**Uninstall.** Set the dashboard hook to Inactive (or delete it), then remove the
local install on each machine with `install.sh --uninstall` /
`install.ps1 -Uninstall`. Deleting the dashboard hook alone stops future
installs but does not remove an existing one, because the installed hooks live
in the user's own `~/.cursor/hooks.json`.

**Privacy.** Prompts and agent responses are replaced with `[MASKED]` by
default. Tool names, file paths, and shell commands are always sent. Use
`--no-mask-prompts` only with explicit sign-off.

**Cost of a no-op.** After the first install, every hook event runs a version
check that exits in about 2 ms.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `No active team hooks found for OS` in the Hooks log | The hook's Operating Systems don't include this machine's OS, or the app's active team has no hooks. Check step 6. |
| Nothing in `~/.cursor/managed/` | Cursor has not synced yet, or the developer's app resolves to a different team. Sign out and back in to force a fetch. |
| `~/.cursor/managed/...` has the script but `~/.cursor/hooks.json` never appears | No `python3` on PATH, or the installer failed. Run the delivered script by hand and read stderr. |
| Files installed but no spans in Coralogix | Wrong endpoint or key. `403` means a bad key. Set `CX_OTLP_DEBUG=true` in `~/.cursor/hooks/coralogix_hook.env` and check **Output -> Hooks**. |
| Warning about Python dependencies | PyPI is blocked. Pre-seed `opentelemetry-sdk` and `opentelemetry-exporter-otlp-proto-http`, or ship them via your image. |
| Duplicate spans | The hook is installed twice, e.g. team hook plus the MDM installer or the VSIX extension. Use one delivery mechanism per machine. |
| Env var overrides seem ignored | `coralogix_hook.env` is loaded by the wrapper and wins over the surrounding shell environment. Edit the file, not your shell. |
