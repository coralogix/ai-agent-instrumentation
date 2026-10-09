#!/bin/sh
# ==============================================================================
# Builds the com.openai.codex managed-preferences plist for Jamf
# (Configuration Profiles → Application & Custom Settings → Upload,
# preference domain com.openai.codex).
#
#   requirements_toml_base64  ← REQUIREMENTS (hook registration, enforced)
#   config_toml_base64        ← CONFIG (the [otel] block: Codex's own telemetry
#                               and the endpoint/key the hook reads)
#
# Codex expects both as base64 TOML without line wrapping.
#
# Usage:
#   ./hooks/make-jamf-plist.sh hooks/requirements.example.toml <config.toml> \
#     > com.openai.codex.plist
#
# <config.toml> is codex/config.toml.example with your values filled in, e.g.
#   set -a; source .env; set +a
#   envsubst < config.toml.example > /tmp/codex-managed.toml
# The output holds your send key — keep it out of git.
# ==============================================================================

set -e

REQ="$1"
CFG="$2"
if [ ! -f "$REQ" ] || [ ! -f "$CFG" ]; then
  echo "usage: $0 <requirements.toml> <config.toml> > com.openai.codex.plist" >&2
  exit 2
fi

REQ_B64="$(base64 -i "$REQ" | tr -d '\n')"
CFG_B64="$(base64 -i "$CFG" | tr -d '\n')"

cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>config_toml_base64</key>
	<string>${CFG_B64}</string>
	<key>requirements_toml_base64</key>
	<string>${REQ_B64}</string>
</dict>
</plist>
EOF
