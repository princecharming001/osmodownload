// Shared request-body reader. Every POST route that `.json()`s a body must
// tolerate junk — `null`, arrays, bare strings, invalid JSON, wrong
// content-type — as "no usable body" (routes then 4xx on their required
// fields) instead of throwing on a property read and 500ing. The old
// `.json().catch(() => ({}))` idiom handled invalid JSON but crashed on the
// VALID JSON value `null` (`body.field` on null throws).

/** Parse the request body as a plain JSON object; anything else → `{}`. */
export async function readJsonObject(req: Request): Promise<Record<string, unknown>> {
  const parsed = await req.json().catch(() => null) as unknown;
  return (parsed && typeof parsed === "object" && !Array.isArray(parsed))
    ? parsed as Record<string, unknown>
    : {};
}
