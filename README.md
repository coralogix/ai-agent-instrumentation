# Coralogix AI Agents Instrumentation

A collection of instrumentation integrations for AI agents, enabling observability through [Coralogix](https://coralogix.com).

## Overview

This repository provides ready-to-use instrumentation setups that forward telemetry from AI agent tools to Coralogix via OpenTelemetry (OTLP).

## Integrations

| Agent | Description |
|-------|-------------|
| [Claude Code](./claude-code/) | Forward token usage, costs, code changes, and prompt logs to Coralogix via OTLP |
| [Codex CLI](./codex/) | Forward API requests, tool calls, SSE events, and session activity to Coralogix via OTLP |

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request. All contributors are required to sign the [Coralogix CLA](https://cla-assistant.io/coralogix/ai-agents-instrumentation).

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

[Apache 2.0](LICENSE) — Copyright 2026 Coralogix Ltd.
