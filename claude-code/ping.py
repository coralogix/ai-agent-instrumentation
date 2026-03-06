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

"""
ping.py
-------
Sends a representative set of claude_code.* metrics and log events to
Coralogix over OTLP/HTTP to verify end-to-end connectivity before running
a real Claude Code session.

Usage:
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt
    python3 ping.py
"""

import os
import time
import uuid
from dotenv import load_dotenv

load_dotenv()

# ── Resolve configuration ─────────────────────────────────────────────────────
API_KEY       = os.environ.get("CX_API_KEY")
ENDPOINT      = os.environ.get("CX_OTLP_ENDPOINT", "https://ingress.eu1.coralogix.com")
APP_NAME      = os.environ.get("CX_APPLICATION_NAME", "claude-code")
SUBSYSTEM     = os.environ.get("CX_SUBSYSTEM_NAME", "claude-code-sessions")

if not API_KEY:
    raise SystemExit("❌  CX_API_KEY is not set. Copy .env.example → .env and fill in your key.")

OTLP_HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
}

print(f"Sending test telemetry to: {ENDPOINT}")
print("─" * 60)

# ── OpenTelemetry SDK setup ───────────────────────────────────────────────────
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
import logging

TEST_SESSION_ID = str(uuid.uuid4())

resource = Resource.create({
    "service.name":        "claude-code",
    "service.version":     "1.0.0-test",
    "cx.application.name": APP_NAME,
    "cx.subsystem.name":   SUBSYSTEM,
    "session.id":          TEST_SESSION_ID,
    "user.id":             "test-user",
})

# Metrics exporter — delta temporality (required for Coralogix counters)
metric_exporter = OTLPMetricExporter(
    endpoint=f"{ENDPOINT}/v1/metrics",
    headers=OTLP_HEADERS,
    preferred_temporality={},  # defaults; delta set via env var when using Claude Code
)

# Short export interval so we don't have to wait long
reader = PeriodicExportingMetricReader(metric_exporter, export_interval_millis=5_000)
meter_provider = MeterProvider(resource=resource, metric_readers=[reader])

meter = meter_provider.get_meter("claude-code-test")

# Logs exporter
log_exporter = OTLPLogExporter(
    endpoint=f"{ENDPOINT}/v1/logs",
    headers=OTLP_HEADERS,
)
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))

handler = LoggingHandler(level=logging.DEBUG, logger_provider=logger_provider)
logging.getLogger().addHandler(handler)
logging.getLogger().setLevel(logging.DEBUG)
logger = logging.getLogger("claude-code")

# ── Record test metrics ───────────────────────────────────────────────────────
print("Recording test metrics …")

session_counter = meter.create_counter(
    "claude_code.session.count",
    description="Sessions started",
    unit="1",
)
token_counter = meter.create_counter(
    "claude_code.token.usage",
    description="Tokens consumed per model",
    unit="1",
)
cost_counter = meter.create_counter(
    "claude_code.cost.usage",
    description="Estimated USD cost per model",
    unit="USD",
)
lines_counter = meter.create_counter(
    "claude_code.lines_of_code.count",
    description="Lines added / removed",
    unit="1",
)

session_counter.add(1,  {"session.id": TEST_SESSION_ID})
token_counter.add(1200, {"model": "claude-opus-4-5", "type": "input",       "session.id": TEST_SESSION_ID})
token_counter.add(350,  {"model": "claude-opus-4-5", "type": "output",      "session.id": TEST_SESSION_ID})
token_counter.add(800,  {"model": "claude-opus-4-5", "type": "cacheRead",   "session.id": TEST_SESSION_ID})
cost_counter.add(0.042, {"model": "claude-opus-4-5", "session.id": TEST_SESSION_ID})
lines_counter.add(47,   {"change_type": "added",   "session.id": TEST_SESSION_ID})
lines_counter.add(12,   {"change_type": "removed",  "session.id": TEST_SESSION_ID})

# ── Record test log events ────────────────────────────────────────────────────
print("Recording test log events …")

logger.info(
    "claude_code.user_prompt",
    extra={
        "otelSpanID":   "0" * 16,
        "otelTraceID":  "0" * 32,
        "event.name":   "claude_code.user_prompt",
        "session.id":   TEST_SESSION_ID,
        "model":        "claude-opus-4-5",
        "redacted":     True,
    },
)
logger.info(
    "claude_code.api_request",
    extra={
        "event.name":    "claude_code.api_request",
        "session.id":    TEST_SESSION_ID,
        "model":         "claude-opus-4-5",
        "input_tokens":  1200,
        "output_tokens": 350,
        "latency_ms":    1843,
        "cost_usd":      0.042,
    },
)
logger.info(
    "claude_code.tool_result",
    extra={
        "event.name":  "claude_code.tool_result",
        "session.id":  TEST_SESSION_ID,
        "tool":        "bash",
        "success":     True,
        "duration_ms": 312,
        "decision":    "accept",
    },
)

# ── Flush and report ──────────────────────────────────────────────────────────
print("\nFlushing … (waiting 7 s for the metric export interval)")
time.sleep(7)

metric_errors  = meter_provider.shutdown()
log_errors     = logger_provider.shutdown()

print()
if not metric_errors:
    print("✓  Metrics exported successfully")
else:
    print(f"✗  Metrics export failed: {metric_errors}")

if not log_errors:
    print("✓  Log events exported successfully")
else:
    print(f"✗  Log events export failed: {log_errors}")

print()
print("─" * 60)
print("Done! Open your Coralogix tenant and look for:")
print(f"  App / Subsystem : {APP_NAME} / {SUBSYSTEM}")
print("  Metrics         : Metrics Explorer → search 'claude_code'")
print("  Logs            : Logs screen → filter subsystemName = claude-code-sessions")
