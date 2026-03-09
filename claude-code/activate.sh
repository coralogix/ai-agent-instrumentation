#!/usr/bin/env bash
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

# Source this file (do NOT execute it) to export Claude Code telemetry env vars:
#   source activate.sh

set -a
# shellcheck source=.env
source "$(dirname "${BASH_SOURCE[0]}")/.env"
set +a

# ── Claude Code telemetry toggle ──────────────────────────────────────────────
export CLAUDE_CODE_ENABLE_TELEMETRY=1

# ── OTLP exporters ────────────────────────────────────────────────────────────
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp

# Coralogix expects HTTP/protobuf
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf

# Coralogix OTLP ingress endpoint (base URL — no signal suffix)
export OTEL_EXPORTER_OTLP_ENDPOINT="${CX_OTLP_ENDPOINT}"

# Authenticate with the Coralogix Send-Your-Data API key
# Application and subsystem names are passed as resource attributes
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${CX_API_KEY}"

# Map application / subsystem via OTEL resource attributes
export OTEL_RESOURCE_ATTRIBUTES="cx.application.name=${CX_APPLICATION_NAME},cx.subsystem.name=${CX_SUBSYSTEM_NAME}"

# Coralogix works best with delta temporality for counters
export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta

# Log the content of user prompts — disabled by default, uncomment to enable
# export OTEL_LOG_USER_PROMPTS=1

echo "✓  Claude Code → Coralogix telemetry configured"
echo "   Endpoint : ${OTEL_EXPORTER_OTLP_ENDPOINT}"
echo "   App      : ${CX_APPLICATION_NAME}"
echo "   Subsystem: ${CX_SUBSYSTEM_NAME}"
echo ""
echo "Run 'claude' to start a session with telemetry enabled."
