#!/usr/bin/env bash
# build-installer.sh
#
# Regenerates the embedded hook.py (base64) inside install.sh from the canonical
# source at extension/resources/hook.py, so the self-contained installer that
# gets pasted into an MDM (JumpCloud/Jamf/Intune) never drifts from the real hook.
#
# Run this whenever you change extension/resources/hook.py, then commit install.sh.
#
# Usage:
#   ./build-installer.sh          # regenerate in place
#   ./build-installer.sh --check  # exit 1 if install.sh is out of sync (for CI)

set -euo pipefail

cd "$(dirname "$0")"

HOOK_SRC="extension/resources/hook.py"
INSTALLER="install.sh"
CHECK=false
[[ "${1:-}" == "--check" ]] && CHECK=true

if [[ ! -f "$HOOK_SRC" ]]; then
  echo "Error: $HOOK_SRC not found." >&2
  exit 1
fi

# Splice the base64 of hook.py between the two heredoc markers in the
# embedded_hook_b64() function. python3 keeps this portable across macOS/Linux.
python3 - "$INSTALLER" "$HOOK_SRC" "$CHECK" <<'PYEOF'
import base64, sys, textwrap

installer_path, hook_path, check = sys.argv[1], sys.argv[2], sys.argv[3] == "true"

START = "  cat <<'CX_HOOK_B64_EOF'\n"
END   = "CX_HOOK_B64_EOF\n"

with open(installer_path) as f:
    lines = f.readlines()

try:
    i = lines.index(START)
    j = lines.index(END, i + 1)
except ValueError:
    sys.exit("Error: could not find the CX_HOOK_B64_EOF markers in " + installer_path)

with open(hook_path, "rb") as f:
    b64 = base64.b64encode(f.read()).decode("ascii")
payload = [l + "\n" for l in textwrap.wrap(b64, 76)]

new_lines = lines[:i + 1] + payload + lines[j:]

if new_lines == lines:
    print("install.sh already in sync with hook.py.")
    sys.exit(0)

if check:
    sys.exit("install.sh is OUT OF SYNC with hook.py — run ./build-installer.sh and commit.")

with open(installer_path, "w") as f:
    f.writelines(new_lines)
print(f"Embedded {len(b64)} base64 chars of hook.py into install.sh ({len(payload)} lines).")
PYEOF

chmod +x "$INSTALLER"
