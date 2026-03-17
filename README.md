# Coralogix AI Agents Instrumentation

A collection of instrumentation integrations for AI agents, enabling observability through [Coralogix](https://coralogix.com).

## Overview

This repository provides ready-to-use instrumentation setups that forward telemetry from AI agent tools to Coralogix via OpenTelemetry (OTLP).

## Integrations

| Agent | Description |
|-------|-------------|
| [Claude Code](./claude-code/) | Forward token usage, costs, code changes, and prompt logs to Coralogix via OTLP |
| [Codex CLI](./codex/) | Forward API requests, tool calls, SSE events, and session activity to Coralogix via OTLP |
| [Gemini CLI](./gemini-cli/) | Forward token usage, tool calls, API requests, model routing, agent runs, and prompt logs to Coralogix via OTLP |
| [OpenClaw](./openclaw/) | Forward gateway sessions, token usage, costs, model runs, message flow, and webhook activity to Coralogix via OTLP |


## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request. All contributors are required to sign the [Coralogix CLA](https://cla-assistant.io/coralogix/ai-agent-instrumentation).

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

[Apache 2.0](LICENSE) — Copyright 2026 Coralogix Ltd.
