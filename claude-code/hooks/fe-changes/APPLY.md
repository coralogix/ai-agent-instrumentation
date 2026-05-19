# FE Changes — Session Breakdown Table

Apply these changes to `cx-web-workspace` once the repo has no merge conflicts.

## Files to copy

Copy these files into the cx-web-workspace repo:

```
claude-code-sessions.types.ts  → libs/ai-center/code-agents/src/lib/code-agents-claude-code/claude-code-users/claude-code-sessions.types.ts
claude-code-sessions.service.ts → libs/ai-center/code-agents/src/lib/code-agents-claude-code/claude-code-users/claude-code-sessions.service.ts
```

## Patch to apply

```bash
cd /path/to/cx-web-workspace
git apply /path/to/patches/2.1-promql-queries.patch
```

## Manual edits needed

### 1. claude-code-user-dialog.component.ts

Add `SessionBreakdownRow` import and `sessions` to `ClaudeCodeUserDialogData`:

```typescript
import { type SessionBreakdownRow } from '../claude-code-sessions.types';

// Add to ClaudeCodeUserDialogData interface:
export interface ClaudeCodeUserDialogData {
  // ... existing fields ...
  sessions: SessionBreakdownRow[];
}
```

### 2. claude-code-users.component.ts

Inject `ClaudeCodeSessionsService`, add `rxResource` for sessions, pass into dialog data:

```typescript
import { ClaudeCodeSessionsService } from './claude-code-sessions.service';

// Add to providers:
providers: [ClaudeCodeUsersService, ClaudeCodeSessionsService],

// Add resource:
#sessionsService = inject(ClaudeCodeSessionsService);

#sessionsResource = rxResource({
  params: () => {
    const user = this.#selectedUserEmail();
    if (!user) return undefined;
    return {
      time: this.time(),
      filters: { ...this.#filtersService.filters(), user },
    };
  },
  stream: ({ params }) =>
    params
      ? this.#sessionsService.getSessionBreakdown(params.filters)
      : EMPTY,
});

// Add to #userDialogData computed:
sessions: this.#sessionsResource.value() ?? [],
```

### 3. claude-code-user-dialog.component.html

Add Sessions card after the Code Impact card (before the closing `</div>`):

```html
<!-- Subsection 3: Sessions -->
<cxui-card class="ai-center-section-card">
  <cxui-card-title class="tw-flex tw-items-center tw-gap-[8px]">
    <cxui-icon
      class="tw-text-[--c-icon-secondary]"
      icon="general/list.svg"
      size="sm"
    />
    <span class="f-paragraph-bold">{{ t.SESSIONS_TABLE?.TITLE ?? 'Sessions' }}</span>
  </cxui-card-title>
  <cxui-card-body>
    @if (data().sessions.length > 0) {
      <div class="tw-max-h-[300px] tw-overflow-y-auto">
        <table class="tw-w-full tw-text-[13px]">
          <thead>
            <tr class="tw-text-left tw-text-[--c-text-secondary]">
              <th class="tw-pb-[8px] tw-font-medium">Session ID</th>
              <th class="tw-pb-[8px] tw-font-medium">Repos</th>
              <th class="tw-pb-[8px] tw-font-medium tw-text-right">Cost</th>
              <th class="tw-pb-[8px] tw-font-medium tw-text-right">Tokens</th>
            </tr>
          </thead>
          <tbody>
            @for (session of data().sessions; track session.sessionId) {
              <tr class="tw-border-0 tw-border-t tw-border-solid tw-border-[--c-border-subtle]">
                <td
                  class="tw-py-[6px] tw-font-mono tw-text-[12px]"
                  [cxTooltip]="session.sessionId"
                >
                  {{ session.sessionId | slice:0:8 }}
                </td>
                <td class="tw-py-[6px]">{{ session.repos }}</td>
                <td class="tw-py-[6px] tw-text-right">${{ session.costUsd.toFixed(2) }}</td>
                <td class="tw-py-[6px] tw-text-right">{{ session.tokens | number }}</td>
              </tr>
            }
          </tbody>
        </table>
      </div>
    } @else {
      <div class="tw-py-[16px] tw-text-center tw-text-[--c-text-secondary]">
        No session data available
      </div>
    }
  </cxui-card-body>
</cxui-card>
```

### 4. i18n (en.json)

Add under `AI-CENTER.CODE_AGENTS.CLAUDE_CODE.USER_DIALOG`:

```json
"SESSIONS_TABLE": {
  "TITLE": "Sessions",
  "SESSION_ID": "Session ID",
  "REPOS": "Repos",
  "COST": "Cost",
  "TOKENS": "Tokens",
  "EMPTY": "No session data available"
}
```
