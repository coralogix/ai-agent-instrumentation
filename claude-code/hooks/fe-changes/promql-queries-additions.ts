// Add these to the end of codeAgentsPromQLQueries object in promql-queries.ts
// (before the closing `};`)

  // Per-session breakdown queries (used in the user drawer session table)
  costBySession: (filters?: QueryFilters) => {
    const rangeSeconds = getFullRangeSeconds();
    const labelFilter = buildLabelFilter(filters);
    return `sum by (session_id) (increase(claude_code_cost_usage_USD_total${labelFilter}[${rangeSeconds}s]))`;
  },

  tokensBySession: (filters?: QueryFilters) => {
    const rangeSeconds = getFullRangeSeconds();
    const labelFilter = buildLabelFilter(filters);
    return `sum by (session_id) (increase(claude_code_token_usage_tokens_total${labelFilter}[${rangeSeconds}s]))`;
  },

  // Note: queries the hook-emitted gauge metric, not a native Claude Code metric.
  // Uses max (not increase) since it's an info gauge always set to 1.
  // Does NOT filter by user_email — the client-side join handles user scoping.
  reposBySession: (filters?: QueryFilters) => {
    const parts: string[] = [];
    const appFilter = buildMultiValueFilter(
      'cx_application_name',
      filters?.application,
    );
    if (appFilter) parts.push(appFilter);
    const subFilter = buildMultiValueFilter(
      'cx_subsystem_name',
      filters?.subsystem,
    );
    if (subFilter) parts.push(subFilter);
    const labelFilter = parts.length > 0 ? `{${parts.join(',')}}` : '';
    return `max by (session_id, repository_name) (claude_code_session_repo_info${labelFilter})`;
  },
