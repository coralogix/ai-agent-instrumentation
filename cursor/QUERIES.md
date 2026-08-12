# DataPrime queries for Cursor agent spans

Field names verified against live spans produced by this integration.

In the UI: **Explore -> Spans**, paste the query. In the CLI:
`cx spans "<query>" --output json` (the text renderer ignores `choose` aliases,
so always use `--output json` when you select fields).

## Keypaths

Labels, the cheap ones to filter on:

| Keypath | Value |
|---|---|
| `$l.applicationName` | `cursor` |
| `$l.subsystemName` | `cursor-sessions` |
| `$l.serviceName` | `cursor-agent` |
| `$l.operationName` | `cursor.<event>`, e.g. `cursor.beforeSubmitPrompt` |

Span structure:

| Keypath | Value |
|---|---|
| `$d.traceID` | one Cursor conversation = one trace |
| `$d.spanID`, `$d.parentId` | hierarchy |
| `$d.duration` | microseconds |

Attributes contain dots in their names, so they need **bracket syntax**:
`$d.tags['gen_ai.request.model']`. Dot syntax will not work.

Always present: `cursor.conversation_id`, `cursor.cursor_version`,
`gen_ai.request.model`, `gen_ai.system`, `cx.integration.source.type`,
`otel.scope.name`. Often present: `cursor.user_email`, `cursor.session_id`,
`cursor.composer_mode`, `cursor.generation_id`.

Per-event: `cursor.prompt`, `cursor.text`, `gen_ai.tool.name`,
`cursor.tool_input`, `cursor.tool_output`, `cursor.shell_command`, `cursor.cwd`,
`cursor.exit_code`, `cursor.file_path`, `cursor.lines_added`,
`cursor.lines_deleted`, `cursor.status`, `cursor.loop_count`, `cursor.error`,
`cursor.duration_ms`, `cursor.context_usage_pct`.

---

## 1. Start here - is anything arriving?

```
source spans | filter $l.applicationName == 'cursor'
```

## 2. Which events, how many

```
source spans
| filter $l.applicationName == 'cursor'
| countby $l.operationName
| sort by _count desc
```

## 3. Adoption - who is actually using Cursor

```
source spans
| filter $l.applicationName == 'cursor' && $l.operationName == 'cursor.sessionStart'
| countby $d.tags['cursor.user_email']
| sort by _count desc
```

## 4. Model usage across the team

```
source spans
| filter $l.applicationName == 'cursor'
| countby $d.tags['gen_ai.request.model']
| sort by _count desc
```

## 5. One full conversation, in order

Grab a `traceID` from any query above, then:

```
source spans
| filter $d.traceID == '<TRACE_ID>'
| choose $l.operationName as event,
         $d.tags['gen_ai.tool.name'] as tool,
         $d.duration as micros
| sort by $m.timestamp asc
```

The trace also renders as a waterfall in the UI under **Explore -> Traces**.

## 6. What the agent ran in the shell

```
source spans
| filter $l.applicationName == 'cursor' && $l.operationName == 'cursor.afterShellExecution'
| choose $d.tags['cursor.user_email'] as user,
         $d.tags['cursor.shell_command'] as command,
         $d.tags['cursor.exit_code'] as exit_code,
         $d.tags['cursor.cwd'] as cwd
| limit 100
```

Non-zero exits only: add `&& $d.tags['cursor.exit_code'] != '0'` to the filter.

## 7. Files the agent edited, with churn

```
source spans
| filter $l.applicationName == 'cursor' && $l.operationName == 'cursor.afterFileEdit'
| choose $d.tags['cursor.file_path'] as file,
         $d.tags['cursor.lines_added'] as added,
         $d.tags['cursor.lines_deleted'] as deleted,
         $d.tags['cursor.user_email'] as user
| limit 100
```

## 8. Tool failures

```
source spans
| filter $l.applicationName == 'cursor' && $l.operationName == 'cursor.postToolUseFailure'
| choose $d.tags['gen_ai.tool.name'] as tool,
         $d.tags['cursor.error'] as error,
         $d.tags['cursor.user_email'] as user
| limit 100
```

## 9. MCP server usage

```
source spans
| filter $l.applicationName == 'cursor' && $l.operationName == 'cursor.afterMCPExecution'
| countby $d.tags['gen_ai.tool.name']
| sort by _count desc
```

## 10. How sessions end

```
source spans
| filter $l.applicationName == 'cursor' && $l.operationName == 'cursor.stop'
| countby $d.tags['cursor.status']
```

## 11. Agent response latency

```
source spans
| filter $l.applicationName == 'cursor' && $l.operationName == 'cursor.afterAgentResponse'
| choose $d.tags['cursor.duration_ms'] as ms, $d.tags['cursor.user_email'] as user
| limit 100
```

## 12. Rollout verification - how many machines reported in

```
source spans
| filter $l.applicationName == 'cursor'
| countby $d.tags['cursor.cursor_version'], $d.tags['cursor.user_email']
```

Compare the distinct user count against your Cursor seat count to see how far
the rollout has reached.

---

## Notes

- Prompts and agent responses are `[MASKED]` unless deployed with
  `--no-mask-prompts`. `cursor.prompt` and `cursor.text` will read `[MASKED]`.
- `cursor.user_email` is not on every event type; `cursor.sessionStart` is the
  reliable place to count people.
- `$d.duration` is microseconds; `cursor.duration_ms` is milliseconds and only
  present on the events that measure their own elapsed time.
- Filter by `$l.applicationName` / `$l.subsystemName` first - they are indexed
  labels and much cheaper than tag lookups.
