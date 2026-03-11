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

# Source this file (do NOT execute it) to export Gemini CLI telemetry env vars:
#   source activate.sh

set -a
# shellcheck source=.env
source "$(dirname "${BASH_SOURCE[0]}")/.env"
set +a

# ── Gemini CLI telemetry toggle ───────────────────────────────────────────────
export GEMINI_TELEMETRY_ENABLED=true

# ── Target: custom OTLP endpoint (not GCP) ───────────────────────────────────
export GEMINI_TELEMETRY_TARGET=local

# ── Protocol: gRPC (protobuf) — most reliable with Coralogix ─────────────────
# Gemini CLI's HTTP exporters use JSON format, which Coralogix accepts (200 OK)
# but silently drops. gRPC uses protobuf which Coralogix ingests correctly.
export GEMINI_TELEMETRY_OTLP_PROTOCOL=grpc

# ── Coralogix gRPC OTLP ingress endpoint ─────────────────────────────────────
# gRPC uses origin only (no /v1/ path suffix); Coralogix exposes gRPC on 443.
export GEMINI_TELEMETRY_OTLP_ENDPOINT="${CX_OTLP_ENDPOINT}"

# ── Auth + routing headers — sent as gRPC metadata by the OTel gRPC exporter ─
# gRPC metadata keys must be lowercase; HTTP headers are case-insensitive.
export OTEL_EXPORTER_OTLP_HEADERS="authorization=Bearer ${CX_API_KEY},cx-application-name=${CX_APPLICATION_NAME},cx-subsystem-name=${CX_SUBSYSTEM_NAME}"

# ── Resource attributes (belt-and-suspenders routing for Coralogix) ───────────
export OTEL_RESOURCE_ATTRIBUTES="cx.application.name=${CX_APPLICATION_NAME},cx.subsystem.name=${CX_SUBSYSTEM_NAME}"

# ── Include prompt text in telemetry (off by default) ────────────────────────
# Uncomment to capture prompt content in gemini_cli.user_prompt log events.
export GEMINI_TELEMETRY_LOG_PROMPTS=true

echo "✓  Gemini CLI → Coralogix telemetry configured"
echo "   Endpoint : ${GEMINI_TELEMETRY_OTLP_ENDPOINT}"
echo "   App      : ${CX_APPLICATION_NAME}"
echo "   Subsystem: ${CX_SUBSYSTEM_NAME}"
echo ""
echo "Run 'gemini' to start a session with telemetry enabled."
