// Global Anthropic spend circuit-breaker. Caps the number of real model calls in
// a rolling day + month window; when tripped, /api/suggest degrades to the
// deterministic mock rather than burning the key unbounded (per-account quota
// only limits free tier; this is the aggregate backstop that also covers Pro and
// any auth bypass).
//
// In-memory / per-process for now — moves to durable Postgres counters under 0-B
// so it survives restart and holds across instances. Budgets are env-tunable;
// picking the numbers is a HUMAN GATE. Defaults are protective-but-generous.

const g = globalThis as unknown as { __osmoSpend?: SpendState };
interface SpendState { day: string; dayCount: number; month: string; monthCount: number; }

function dayKey(now: number): string { return new Date(now).toISOString().slice(0, 10); }  // YYYY-MM-DD
function monthKey(now: number): string { return new Date(now).toISOString().slice(0, 7); }  // YYYY-MM

function num(env: string | undefined, dflt: number): number {
  const n = env ? Number(env) : NaN;
  return Number.isFinite(n) && n > 0 ? n : dflt;
}
function dailyMax(): number { return num(process.env.OSMO_ANTHROPIC_DAILY_MAX_CALLS, 2000); }
function monthlyMax(): number { return num(process.env.OSMO_ANTHROPIC_MONTHLY_MAX_CALLS, 40000); }

function state(now: number): SpendState {
  const s = g.__osmoSpend ?? (g.__osmoSpend = { day: dayKey(now), dayCount: 0, month: monthKey(now), monthCount: 0 });
  const dk = dayKey(now), mk = monthKey(now);
  if (s.day !== dk) { s.day = dk; s.dayCount = 0; }
  if (s.month !== mk) { s.month = mk; s.monthCount = 0; }
  return s;
}

export function breakerTripped(now: number = Date.now()): { tripped: boolean; reason?: string } {
  const s = state(now);
  if (s.dayCount >= dailyMax()) return { tripped: true, reason: "daily_budget" };
  if (s.monthCount >= monthlyMax()) return { tripped: true, reason: "monthly_budget" };
  return { tripped: false };
}

/** Count one real model call against the day + month budgets. */
export function recordModelCall(now: number = Date.now()): void {
  const s = state(now);
  s.dayCount++;
  s.monthCount++;
}

export function resetSpendForTests(): void { delete g.__osmoSpend; }
