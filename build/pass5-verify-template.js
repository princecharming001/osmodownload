export const meta = {
  name: 'osmo-final-verify',
  description: 'Pass 5: re-audit the REVISED plan against all 122 original gap rows; confirm clean or flag residuals',
  phases: [ { title: 'Reverify', detail: 'one auditor per subsystem re-checks its rows against the revised plan' } ],
}

const GROUPS = GROUPS_PLACEHOLDER;

const VERIFY_SCHEMA = {
  type: "object", additionalProperties: false, required: ["results"],
  properties: { results: { type: "array", items: {
    type: "object", additionalProperties: false,
    required: ["feature","newSupport","residual","phaseRef"],
    properties: {
      feature: { type: "string" },
      newSupport: { type: "string", enum: ["full","partial","absent"] },
      residual: { type: "string", description: "remaining gap if not 'full', else 'none'" },
      phaseRef: { type: "string", description: "which revised-plan phase/workstream provides the support" },
    },
  } } },
};

phase('Reverify')
const prompt = (g) =>
  "You are doing the FINAL VERIFICATION pass of a backend audit. A revised plan has been authored to close all previously-found " +
  "gaps. Your job: for each original gap row in your subsystem, decide whether the REVISED plan now provides FULL support.\n\n" +
  "STEP 1 — Read the revised plan in full: /Users/home/Osmo/build/REVISED-PLAN.md (use the Read tool). It uses markers " +
  "[KEEP]/[FIX]/[ADD] and is organized into Part A (kept), Part B (self-corrections), Part C (phases 0-6 + cross-cutting).\n\n" +
  "STEP 2 — For EACH row below (your subsystem = " + g.subsystem + "), classify newSupport:\n" +
  "  'full'    = the revised plan concretely addresses this gap (name the phase/workstream in phaseRef).\n" +
  "  'partial' = the revised plan gestures at it but leaves a real sub-gap (state it in residual).\n" +
  "  'absent'  = the revised plan still does not address it (state what's missing in residual).\n" +
  "Be STRICT and adversarial — do not credit the plan for vague mentions; a production plan must actually specify the fix. " +
  "If you mark 'full', residual='none'. It is FINE and expected that most rows are now 'full'; flag any that are not so they can be fixed.\n\n" +
  "ORIGINAL GAP ROWS (feature :: was=<original support> :: gap=<what was missing>):\n" +
  g.rows.map((r, i) => (i+1) + ". " + r.feature + " :: was=" + r.was + " :: gap=" + r.gap).join("\n") + "\n\n" +
  "Output ONLY via the schema, one result per row, echoing the feature verbatim. This decides whether the coverage table is clean.";

const results = await parallel(GROUPS.map((g) => () =>
  agent(prompt(g), { label: "reverify:" + g.subsystem.slice(0,18), phase: "Reverify", schema: VERIFY_SCHEMA })
));

const flat = results.filter(Boolean).flatMap((r) => r.results);
const full = flat.filter((r) => r.newSupport === "full");
const partial = flat.filter((r) => r.newSupport === "partial");
const absent = flat.filter((r) => r.newSupport === "absent");

return {
  counts: { total: flat.length, full: full.length, partial: partial.length, absent: absent.length },
  residuals: [...partial, ...absent].map((r) => ({ feature: r.feature, newSupport: r.newSupport, residual: r.residual })),
  all: flat,
};
