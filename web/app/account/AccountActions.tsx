"use client";

import { useState } from "react";

const accent = "#0a84ff";
const muted = "#95a0aa";

export function UpgradeButton({ isPro }: { isPro: boolean }) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  if (isPro) return null;

  async function upgrade() {
    setBusy(true); setMsg(null);
    try {
      const res = await fetch("/api/account/upgrade", { method: "POST" });
      const data = await res.json();
      if (!res.ok) { setMsg(data.error ?? "Couldn't upgrade."); return; }
      window.location.reload();
    } catch {
      setMsg("Couldn't reach the server.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <button
        onClick={upgrade} disabled={busy}
        style={{ background: accent, color: "#fff", border: "none", padding: "10px 20px", borderRadius: 999, fontWeight: 550, fontSize: 15, cursor: busy ? "default" : "pointer", opacity: busy ? 0.6 : 1 }}
      >
        {busy ? "Upgrading…" : "Upgrade to Pro"}
      </button>
      {msg && <p style={{ color: "#ff3b30", fontSize: 13, marginTop: 8 }}>{msg}</p>}
    </div>
  );
}

export function SignOutButton() {
  return (
    <button
      type="button"
      onClick={async () => { await fetch("/api/auth/logout", { method: "POST" }); window.location.href = "/"; }}
      style={{ background: "none", border: "none", color: muted, fontSize: 14, cursor: "pointer", padding: 0 }}
    >
      Sign out
    </button>
  );
}
