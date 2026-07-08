// Lightweight structured observability: JSON logs + in-process counters.
//
// Logs are single-line JSON so Render's log drain (or any aggregator) can parse
// them; counters are a cheap operational snapshot exposed on /api/health. This is
// deliberately dependency-free — a real metrics/APM backend is a later infra
// choice, but this makes the state-loss and cost events VISIBLE today (you can't
// fix what you can't see).

type Level = "info" | "warn" | "error";

const g = globalThis as unknown as { __osmoMetrics?: Map<string, number> };
function counters(): Map<string, number> { return (g.__osmoMetrics ??= new Map()); }

/** Increment a named counter (e.g. "draft.ok", "draft.upstream_error"). */
export function metric(name: string, n = 1): void {
  const c = counters();
  c.set(name, (c.get(name) ?? 0) + n);
}

export function getMetrics(): Record<string, number> {
  return Object.fromEntries(counters());
}

/** Structured log line. Render stamps the timestamp; we keep the payload flat. */
export function log(level: Level, event: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({ level, event, ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

export function resetMetricsForTests(): void { counters().clear(); }
