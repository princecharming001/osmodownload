// Global test setup — reset per-process substrates before every test so limits
// (register/auth/enrich) never bleed across the ~30 register calls in the suite.
import { beforeEach } from "vitest";
import { resetRateLimitForTests } from "@/lib/rateLimit";

beforeEach(() => {
  resetRateLimitForTests();
});
