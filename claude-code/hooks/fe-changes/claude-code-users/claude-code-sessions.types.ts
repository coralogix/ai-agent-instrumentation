export interface SessionBreakdownRow {
  sessionId: string;
  repos: string; // comma-separated repo names, or "—"
  costUsd: number;
  tokens: number;
}
