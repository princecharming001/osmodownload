import { redirect } from "next/navigation";
import { currentSessionUser } from "@/lib/auth/session";
import { getAccounts } from "@/lib/accounts/store";
import { resolveTier, TRIAL_DAYS } from "@/lib/license/entitlement";
import { UpgradeButton, SignOutButton } from "./AccountActions";

const ink = "#08152e";
const muted = "#95a0aa";
const card = "#f5f6f8";
const accent = "#0a84ff";
const hair = "rgba(8,21,46,.10)";

const DAY_MS = 86_400_000;

export default async function Account() {
  const user = await currentSessionUser();
  if (!user) redirect("/login");

  const accounts = getAccounts();
  const sub = await accounts.subscriptionForUser(user.id);
  const devices = await accounts.devicesForUser(user.id);
  const now = Date.now();
  const { tier } = resolveTier(sub, now);
  const isPro = tier === "pro" || tier === "trial";

  let planLabel = "Free";
  if (tier === "pro") planLabel = "Pro";
  else if (tier === "trial" && sub.trialStartedAt) {
    const daysLeft = Math.max(0, Math.ceil((sub.trialStartedAt + TRIAL_DAYS * DAY_MS - now) / DAY_MS));
    planLabel = `Pro — trial (${daysLeft} day${daysLeft === 1 ? "" : "s"} left)`;
  }

  return (
    <main style={{ maxWidth: 620, margin: "0 auto", padding: "72px 24px", color: ink }}>
      <a href="/" style={{ color: muted, textDecoration: "none", fontSize: 14 }}>← Osmo</a>
      <h1 style={{ fontSize: 32, fontWeight: 600, marginTop: 16 }}>Your account</h1>

      {/* Identity */}
      <div style={{ marginTop: 24, padding: 22, background: card, border: `1px solid ${hair}`, borderRadius: 16 }}>
        <div style={{ fontWeight: 590, fontSize: 17 }}>{user.displayName || user.email}</div>
        <div style={{ color: muted, fontSize: 14, marginTop: 4 }}>{user.email}</div>
      </div>

      {/* Plan + billing */}
      <div style={{ marginTop: 16, padding: 22, background: card, border: `1px solid ${hair}`, borderRadius: 16 }}>
        <div style={{ fontSize: 12, fontWeight: 600, letterSpacing: 0.6, color: muted, textTransform: "uppercase" }}>Plan</div>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 8 }}>
          <div style={{ fontWeight: 590, fontSize: 17 }}>{planLabel}</div>
          <UpgradeButton isPro={isPro} />
        </div>
        <p style={{ color: muted, fontSize: 13, lineHeight: 1.55, marginTop: 12, marginBottom: 0 }}>
          {isPro
            ? "You have full access across the Mac app and here on the web — it's the same account."
            : "Free includes 15 AI drafts a week. Pro unlocks unlimited drafting, the Read on every person, autodraft, and your voice profile — synced to your Mac app automatically."}
        </p>
      </div>

      {/* Devices */}
      <div style={{ marginTop: 16, padding: 22, background: card, border: `1px solid ${hair}`, borderRadius: 16 }}>
        <div style={{ fontSize: 12, fontWeight: 600, letterSpacing: 0.6, color: muted, textTransform: "uppercase" }}>Your Macs</div>
        {devices.length === 0 ? (
          <p style={{ color: muted, fontSize: 14, marginTop: 8, marginBottom: 0 }}>
            No Mac linked yet. <a href="/download" style={{ color: accent }}>Download Osmo</a>, then Sign in with Apple in the app to link it to this account.
          </p>
        ) : (
          <div style={{ marginTop: 10, display: "flex", flexDirection: "column", gap: 8 }}>
            {devices.map(d => (
              <div key={d.id} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 14 }}>
                <span style={{ width: 7, height: 7, borderRadius: 999, background: "#3ad35f", display: "inline-block" }} />
                <span>Mac · linked {new Date(d.createdAt).toLocaleDateString()}</span>
              </div>
            ))}
          </div>
        )}
        <p style={{ color: muted, fontSize: 12, lineHeight: 1.55, marginTop: 12, marginBottom: 0 }}>
          Your messages stay encrypted on each Mac and are never uploaded — only your account and plan sync here.
        </p>
      </div>

      <div style={{ marginTop: 24, display: "flex", alignItems: "center", gap: 16 }}>
        <a href="/download" style={{ color: accent, fontSize: 14, textDecoration: "none" }}>Download Osmo for Mac →</a>
        <SignOutButton />
      </div>
    </main>
  );
}
