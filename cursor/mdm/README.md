# Cursor - Coralogix: Jamf / Intune deployment

Turnkey deployers that wrap `../install.sh` / `../install.ps1` for fleet rollout. The Cursor hook is **per-user** (it lives in `~/.cursor` / `%USERPROFILE%\.cursor`), so both deployers exist to bridge from the MDM's usual execution context (root / SYSTEM) into the signed-in user's context — see each script's header for the full design rationale.

Both scripts require an API key and OTLP endpoint (no region default) and exit non-zero with a clear message if either is missing. Both delegate the actual install to the existing installer, which is idempotent — safe to re-run on every policy/app re-evaluation cycle.

---

## Jamf (macOS)

`deploy-jamf.sh` runs as root via a Jamf policy, resolves the console (logged-in) user, and re-execs `install.sh` as that user so `$HOME` resolves to their profile.

### 1. Package `cursor/` to a staging path

The script does not embed `install.sh` or `hook.py` (hook.py is 500+ lines and would drift from the source of truth). Instead:

1. Build a `.pkg` whose payload places a copy of the `cursor/` directory (`install.sh` plus `extension/resources/hook.py`) at a fixed staging path, e.g. `/usr/local/coralogix/cursor`.
2. Upload the `.pkg` to Jamf Pro as a package, scoped to your fleet.
3. Add `deploy-jamf.sh` to the **same** Jamf policy as a script, ordered to run after the package payload (a normal package + script policy already orders this correctly).

### 2. Script parameters

Jamf reserves `$1`-`$3` (mount point, computer name, username); policy parameters start at `$4`:

| Parameter | Value | Required | Fallback env var | Default |
|---|---|---|---|---|
| `$4` | API key | yes | `CX_API_KEY` | - |
| `$5` | OTLP endpoint | yes | `CX_OTLP_ENDPOINT` | - |
| `$6` | Application name | no | `CX_APPLICATION_NAME` | `cursor` |
| `$7` | Subsystem name | no | `CX_SUBSYSTEM_NAME` | `ai-agent` |
| `$8` | Mask prompts (`true`/`false`) | no | `CURSOR_MASK_PROMPTS` | `false` |
| `$9` | Staging path for `cursor/` | no | `CX_CURSOR_STAGING_DIR` | `/usr/local/coralogix/cursor` |

Fill these in on the policy's **Options** tab when adding the script.

### 3. Behavior

- Resolves the console user via `stat -f%Su /dev/console`; exits 1 with a clear message if nobody is logged in (no user, or `loginwindow`) — scope the policy to a login or recurring check-in trigger so it retries.
- Runs `install.sh` as that user via `launchctl asuser <uid> sudo -u <user> -H bash <staging>/install.sh ...` so `$HOME` and `~/.cursor` resolve correctly.
- Exits non-zero with a clear error if the API key, endpoint, or staged `install.sh` are missing.

---

## Intune (Windows)

`deploy-intune.ps1` must be assigned as a **Win32 app in USER context** — it refuses to run as SYSTEM.

### 1. Package with the Win32 Content Prep Tool

Lay out a source folder with the full `cursor/` directory (`install.ps1`, `extension\resources\hook.py`, `mdm\deploy-intune.ps1`), then:

```
IntuneWinAppUtil.exe -c <source-folder> -s mdm\deploy-intune.ps1 -o <output-folder>
```

### 2. Intune app settings

| Setting | Value |
|---|---|
| Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File deploy-intune.ps1 -ApiKey <key> -Endpoint <url>` |
| Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File deploy-intune.ps1 -Uninstall` |
| Install behavior | **User** (Program Settings tab) — **not** System |
| Detection rule | File exists — Path: `%USERPROFILE%\.cursor\hooks`, File: `coralogix_hook.cmd` |
| Assignment | A user group (not a device group) |

Optional passthrough parameters mirror `install.ps1`: `-Application`, `-Subsystem`, `-MaskPrompts`, `-OmitPreToolUse`, `-OtlpDebug`, `-EnvFile`.

### 3. Behavior

- Checks `[Security.Principal.WindowsIdentity]::GetCurrent()` for SID `S-1-5-18` (SYSTEM) and exits 1 with an explanation if it's running as SYSTEM instead of the assigned user.
- Delegates to `..\install.ps1`, which validates the API key/endpoint and installs into `%USERPROFILE%\.cursor`.
- `-Uninstall` passes straight through to `install.ps1 -Uninstall` for Intune's uninstall command.

---

## Injecting the API key

Prefer your MDM's own secret/variable mechanism over a hardcoded key in the policy or install command:

- **Jamf**: populate parameter `$4` from a Jamf Pro script parameter value backed by your secrets manager, rather than typing the key directly into a saved policy.
- **Intune**: use a wrapping script or Intune secure variable that pulls the key from your vault at install time, rather than a literal `-ApiKey` value in the app's install command — the plain command is visible to anyone with app read access in the console.

Both are better than hardcoding: a hardcoded key in a saved policy/app is plaintext to anyone with read access to that policy/app in the MDM console.
