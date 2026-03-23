# Codex CLI — Telemetry Reference

What Codex actually emits, confirmed against real telemetry, and what each signal enables in a dashboard.

---

## Signal inventory

### Two pipelines, two originator values

Codex sends telemetry over two separate OTLP pipelines:

| Pipeline | Config key | What it carries | `originator` (v0.111) | `originator` (v0.115+) | `scope.name` (v0.111) | `scope.name` (v0.115+) |
|---|---|---|---|---|---|---|
| Log exporter | `exporter` | Standalone OTLP log records | `codex_cli_rs` | `codex-tui` | `codex_otel::traces::otel_manager` | `codex_otel.log_only` |
| Trace exporter | `trace_exporter` | Spans with embedded log events | `codex_cli_rs` | `codex_cli_rs` | `codex_cli_rs` | `codex_cli_rs` |

Both `originator` and `scope.name` on standalone log records changed between v0.111.0 and v0.115.0. Filtering on either alone will miss records from older clients.

**Most reliable cross-version filter for `source logs`:**
```
$d.resource.attributes['service.name'] == 'codex_cli_rs'
```
This is set on the resource (not the log record itself) and has not changed across versions.

Standalone log records carry both `spanId` and `traceId`, so individual log events can be correlated back to their parent trace when both pipelines are active.

---

### Log events (`source logs`)

These are standalone OTLP log records sent via the `exporter` pipeline. Originator: `codex-tui`.

#### `codex.tool_result`
Emitted after every tool execution.

| Field | Notes |
|---|---|
| `conversation.id` | Session identifier |
| `user.email` | Developer identity |
| `user.account_id` | Account-level identity |
| `model` | Model used in session |
| `tool_name` | e.g. `exec_command`, `apply_patch` |
| `arguments` | JSON string of tool arguments |
| `output` | Full command output. Contains the plain-text line `Original token count: N` — this is Codex's estimate of how many context-window tokens the output consumes, **not** API billing tokens. Parseable with regex if needed. |
| `duration_ms` | Tool execution time |
| `success` | `"true"` / `"false"` |
| `call_id` | Correlates to the `codex.tool_decision` for this call |
| `mcp_server` | MCP server name — empty for native tools, populated for MCP |
| `mcp_server_origin` | MCP server origin URL |
| `terminal.type` | Editor, e.g. `vscode/2.6.19` |
| `auth_mode` | e.g. `Chatgpt` |
| `slug` | Model slug (same as `model` in observed data) |
| `app.version` | Codex client version |
| `host.name` _(resource)_ | Machine hostname |
| `env` _(resource)_ | Environment tag |

#### `codex.api_request`
Emitted at the end of each streaming API call. Also appears as an embedded log inside `stream_request` spans. Originator: `codex_cli_rs`.

| Field | Notes |
|---|---|
| `conversation.id` | Session identifier |
| `user.email` | Developer identity |
| `user.account_id` | Account-level identity |
| `model` | Model used |
| `duration_ms` | Round-trip time |
| `http.response.status_code` | HTTP status |
| `attempt` | Retry count — `0` on first try, increments on retry |
| `terminal.type` | Editor |
| `auth_mode` | Auth mode |

#### `codex.sse_event` (token counts)
Token counts arrive when `event.kind = response.completed`. Not yet confirmed with a real example but referenced in dashboard queries.

| Field | Notes |
|---|---|
| `conversation.id` | Session identifier |
| `user.email` | Developer identity |
| `model` | Model used |
| `input_token_count` | Input tokens for this response |
| `output_token_count` | Output tokens |
| `cached_token_count` | Cached input tokens |

#### `codex.tool_decision`
Emitted when an AI-generated tool call is approved or rejected. Confirmed from real trace data.

| Field | Confirmed values | Notes |
|---|---|---|
| `conversation.id` | — | Session identifier |
| `user.email` | — | Developer identity |
| `user.account_id` | — | Account-level identity |
| `model` | — | Model in use |
| `tool_name` | e.g. `exec_command` | Tool that was proposed |
| `decision` | `approved` | Observed value. Likely `rejected` for manual rejects — not yet seen |
| `source` | `Config` | Auto-approved by config rule. Other values likely include `User` for manual decisions |
| `originator` | `codex_cli_rs` | Emitted from OTel manager (span-embedded) |

> Note: the README documents `decision` as `accept`/`reject`. Real data shows `approved`. Do not use `accept`/`reject` in dashboard filters.

#### `codex.user_prompt`
Emitted when the user submits a prompt. Confirmed from real trace data.

| Field | Notes |
|---|---|
| `conversation.id` | Session identifier |
| `user.email` | Developer identity |
| `user.account_id` | Account-level identity |
| `model` | Model in use |
| `prompt` | Full prompt text — **present by default**, not opt-in |
| `prompt_length` | Character count of prompt (field name is `prompt_length`, not `length`) |
| `originator` | `codex_cli_rs` |

> Note: the README states prompt content requires `log_user_prompt = true`. Real data shows `prompt` is included unconditionally in span-embedded log events. If privacy matters, this must be accounted for.

#### `codex.conversation_starts`
Emitted at session start.

| Field | Notes |
|---|---|
| `conversation.id` | Session identifier |
| `model` | Initial model |
| `approval_policy` | Approval mode |
| `sandbox_mode` | Sandbox config |

---

### Spans (`source spans`)

Sent via the `trace_exporter` pipeline.

#### `session_loop` (root span)
One span per Codex session. No user identity fields directly in tags — correlate via `traceId` to child span logs.

| Field | Notes |
|---|---|
| `duration` | Total session wall time in microseconds |
| `busy_ns` | Time the agent was actively processing (nanoseconds) |
| `idle_ns` | Time waiting — developer reading/typing/thinking (nanoseconds) |
| `serviceName` | `codex_cli_rs` |

AI-to-idle ratio: `busy_ns / (busy_ns + idle_ns)`. In observed data, most sessions are >99% idle.

#### `stream_request` (child of `session_loop`)
One span per API call. Contains embedded log events including `codex.api_request` (with `user.email`) and the raw HTTP `Request completed` log.

| Field | Notes |
|---|---|
| `parentId` | Links to `session_loop` |
| `duration` | API call wall time in microseconds |
| `busy_ns` / `idle_ns` | Processing vs wait breakdown for this call |
| _(embedded `codex.api_request` log)_ | Full user + model + session context — see above |
| _(embedded `Request completed` log)_ | Raw response headers as JSON string |

#### Quota headers (inside `stream_request` → `Request completed` log)
Parsed from the `headers` JSON string on the HTTP response log.

| Header | Example value | Notes |
|---|---|---|
| `x-codex-plan-type` | `free` | User's plan |
| `x-codex-primary-used-percent` | `25` | % of quota consumed in current window |
| `x-codex-primary-window-minutes` | `10080` | Rolling window length (7 days) |
| `x-codex-primary-reset-at` | Unix timestamp | When quota resets |
| `x-codex-credits-has-credits` | `False` | Whether credits are attached |
| `x-codex-credits-unlimited` | `False` | Unlimited plan flag |

---

## Dashboard section mapping

### Overview

| Panel | Source | Buildable |
|---|---|---|
| Active models | `codex.api_request` grouped by `model` | Yes |
| Session volume | `distinct conversation.id` or count of `session_loop` spans | Yes |
| Total estimated spend | Token counts × hardcoded per-model rates | Partial — rates must be hardcoded |
| Quota utilization | `x-codex-primary-used-percent` from span response headers | Yes — requires header parsing |
| Plan distribution | `x-codex-plan-type` from span response headers | Yes — requires header parsing |

### Cost

| Panel | Source | Buildable |
|---|---|---|
| Model cost distribution | `codex.sse_event` tokens × rate, grouped by `model` | Partial — unconfirmed token field names |
| Users ranked by spend | Same, grouped by `user.email` | Partial |
| Productivity ratio | `codex.tool_decision`: `count(decision=approved) / count(*)` | Confirmed — filter on `decision == 'approved'` (not `accept`) |

### Usage

| Panel | Source | Buildable |
|---|---|---|
| Session count over time | `distinct conversation.id` by day | Yes |
| Request volume over time | `codex.api_request` count by day | Yes |
| Tool call breakdown | `codex.tool_result` grouped by `tool_name` | Yes |
| MCP vs native tool split | `codex.tool_result`: `mcp_server` empty vs populated | Yes |
| Acceptance rate trend | `codex.tool_decision` ratio over time — `decision == 'approved'` | Confirmed |
| Retry rate | `codex.api_request` where `attempt > 0` | Yes |
| AI vs idle time | `busy_ns / (busy_ns + idle_ns)` on `session_loop` spans | Yes |
| Code impact (lines, commits, PRs) | Not emitted | No — not in Codex telemetry |

### Users

| Panel | Source | Buildable |
|---|---|---|
| Users ranked by session count | `distinct conversation.id` by `user.email` | Yes |
| Users ranked by estimated spend | Token × rate by `user.email` | Partial |
| Per-user tool breakdown | `codex.tool_result` filtered by `user.email` | Yes |
| Per-user request volume | `codex.api_request` filtered by `user.email` | Yes |
| Per-user AI vs idle time | Requires traceId join from `session_loop` to `stream_request` logs | Indirect — no direct `user.email` on root span |
| Per-user code impact | Not emitted | No |

---

## Known issues

### Originator filter
All existing dashboard queries filter on `originator == 'codex_cli_rs'`. This works only for events that reach the logs store as standalone records via the log exporter — and only if those records use `codex_cli_rs` as originator.

Real data shows that span-embedded events (all event types in the trace exporter path) use `originator: codex_cli_rs`, while direct OTLP log records use `originator: codex-tui`. If both pipelines are active, filters on `originator` alone are unreliable.

**Correct filter for `source logs` (works across all versions):**
```
$d.resource.attributes['service.name'] == 'codex_cli_rs'
```
Both `originator` and `scope.name` changed between v0.111.0 and v0.115.0, making them unreliable for cross-version queries. The resource `service.name` has remained stable.

### Cost calculation
Codex emits no cost field. Estimated cost must be computed in DataPrime using hardcoded rates, for example:

```
| create cost_usd from (input_tokens * 0.000003) + (output_tokens * 0.000012) + (cached_tokens * 0.00000075)
```

Rates need to be updated when OpenAI changes pricing or when new models are added.

### User identity on session spans
`user.email` is not in `session_loop` span tags. It is available in the embedded `codex.api_request` log inside child `stream_request` spans. Cross-source joins (span + log) are not supported in a single DataPrime query, so AI-vs-idle time cannot be attributed to a specific user in one query.

### Token event confirmation
`codex.sse_event` token field names (`input_token_count`, `output_token_count`, `cached_token_count`) appear in existing dashboard queries but have not yet been confirmed against a real log record. Verify before relying on cost panels.

### `codex.sse_event` still unconfirmed
Token counts (`input_token_count`, `output_token_count`, `cached_token_count`) are referenced in the existing dashboard queries but no real `codex.sse_event` record has been observed. This event is absent from the trace CSV (it likely arrives via the standalone log pipeline only). Verify field names before building cost panels.
