import { inject, Injectable } from '@angular/core';
import { forkJoin, type Observable, of } from 'rxjs';
import { catchError, map } from 'rxjs/operators';

import { cxAiTimeRange } from '@cx/ai-center';

import {
  codeAgentsPromQLQueries,
  type QueryFilters,
} from '../../promql-queries';
import {
  PrometheusQueryService,
  type PrometheusResponse,
} from '../../prometheus-query.service';

import { type SessionBreakdownRow } from './claude-code-sessions.types';

@Injectable()
export class ClaudeCodeSessionsService {
  #prometheus = inject(PrometheusQueryService);

  getSessionBreakdown(
    filters: QueryFilters & { user: string },
  ): Observable<SessionBreakdownRow[]> {
    const { to } = cxAiTimeRange();
    const timeMs = Number(to);

    const empty: PrometheusResponse = {
      status: 'success',
      data: { resultType: 'vector', result: [] },
    };

    return forkJoin({
      costBySession: this.#prometheus
        .queryInstant(codeAgentsPromQLQueries.costBySession(filters), timeMs)
        .pipe(catchError(() => of(empty))),
      tokensBySession: this.#prometheus
        .queryInstant(
          codeAgentsPromQLQueries.tokensBySession(filters),
          timeMs,
        )
        .pipe(catchError(() => of(empty))),
      reposBySession: this.#prometheus
        .queryInstant(codeAgentsPromQLQueries.reposBySession(filters), timeMs)
        .pipe(catchError(() => of(empty))),
    }).pipe(
      map(({ costBySession, tokensBySession, reposBySession }) => {
        const costMap = this.#prometheus.extractLabeledValues(
          costBySession,
          'session_id',
        );
        const tokenMap = this.#prometheus.extractLabeledValues(
          tokensBySession,
          'session_id',
        );
        const repoMap = this.#extractRepoMap(reposBySession);

        const rows: SessionBreakdownRow[] = [];
        for (const [sessionId, cost] of costMap) {
          rows.push({
            sessionId,
            repos: repoMap.get(sessionId)?.join(', ') ?? '—',
            costUsd: cost,
            tokens: tokenMap.get(sessionId) ?? 0,
          });
        }

        rows.sort((a, b) => b.costUsd - a.costUsd);
        return rows.slice(0, 50);
      }),
      catchError(() => of([])),
    );
  }

  #extractRepoMap(response: PrometheusResponse): Map<string, string[]> {
    const repoMap = new Map<string, string[]>();
    if (response.status === 'error' || !response.data?.result.length) {
      return repoMap;
    }
    for (const result of response.data.result) {
      const sessionId = result.metric['session_id'];
      const repo = result.metric['repository_name'];
      if (!sessionId || !repo) continue;
      if (!repoMap.has(sessionId)) repoMap.set(sessionId, []);
      repoMap.get(sessionId)!.push(repo);
    }
    return repoMap;
  }
}
