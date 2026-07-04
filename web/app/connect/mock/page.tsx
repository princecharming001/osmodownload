"use client";

// The mock hosted-auth wizard — keyless mode's stand-in for Unipile's hosted
// wizard / provider OAuth. One click "authorizes" and seeds demo conversations.
// Styled on the orchid tokens so the demo flow feels like the real thing.

import { Suspense, useState } from "react";
import { useSearchParams } from "next/navigation";

const NAMES: Record<string, string> = {
  linkedin: "LinkedIn", whatsapp: "WhatsApp", instagram: "Instagram",
  gmail: "Gmail", slack: "Slack", x: "X",
};

const GLYPHS: Record<string, string> = {
  linkedin: "in", whatsapp: "◎", instagram: "◇", gmail: "✉", slack: "#", x: "𝕏",
};

function MockWizard() {
  const params = useSearchParams();
  const linkId = params.get("linkId") ?? "";
  const platform = params.get("platform") ?? "linkedin";
  const [state, setState] = useState<"idle" | "working" | "done" | "error">("idle");

  const authorize = async () => {
    setState("working");
    try {
      const res = await fetch("/api/connect/mock/complete", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ linkId }),
      });
      if (!res.ok) throw new Error(String(res.status));
      setState("done");
      setTimeout(() => { window.location.href = "/connect/done"; }, 900);
    } catch {
      setState("error");
    }
  };

  const name = NAMES[platform] ?? platform;

  return (
    <main style={{
      minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center",
      background: "#fcfcfd", color: "#08152e",
      fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif",
    }}>
      <div style={{
        width: 420, padding: "40px 36px", borderRadius: 24,
        background: "#ffffff", border: "1px solid rgba(8,21,46,.10)",
        boxShadow: "0 8px 24px rgba(8,21,46,.08)", textAlign: "center",
      }}>
        <div style={{
          width: 56, height: 56, margin: "0 auto 20px", borderRadius: 16,
          background: "#ebeef2", display: "flex", alignItems: "center",
          justifyContent: "center", fontSize: 24, fontWeight: 600,
        }}>{GLYPHS[platform] ?? "•"}</div>

        <div style={{ fontSize: 11, letterSpacing: 1.2, textTransform: "uppercase", color: "#95a0aa", fontWeight: 600 }}>
          Demo connection
        </div>
        <h1 style={{ fontSize: 22, fontWeight: 600, margin: "8px 0 6px" }}>
          Connect {name} to Osmo
        </h1>
        <p style={{ fontSize: 14, lineHeight: 1.5, color: "#95a0aa", margin: "0 0 28px" }}>
          This is the keyless demo wizard. Authorizing loads sample {name} conversations
          so you can try the full product — no real account is touched.
        </p>

        {state === "done" ? (
          <div style={{ fontSize: 15, fontWeight: 500, color: "#0a84ff" }}>Connected ✓</div>
        ) : (
          <button
            onClick={authorize}
            disabled={state === "working" || !linkId}
            style={{
              width: "100%", padding: "12px 0", borderRadius: 999, border: "none",
              background: state === "working" ? "#9cc7f7" : "#0a84ff", color: "#fff",
              fontSize: 15, fontWeight: 500, cursor: "pointer",
              transition: "background .15s cubic-bezier(.4,0,.2,1)",
            }}>
            {state === "working" ? "Connecting…" : `Authorize ${name}`}
          </button>
        )}
        {state === "error" && (
          <p style={{ color: "#ff383c", fontSize: 13, marginTop: 12 }}>
            That link is expired or already used. Go back to Osmo and try again.
          </p>
        )}
        <p style={{ fontSize: 12, color: "#95a0aa", marginTop: 20 }}>
          Osmo never sees your password. Messages stay on your Mac.
        </p>
      </div>
    </main>
  );
}

export default function Page() {
  return <Suspense fallback={null}><MockWizard /></Suspense>;
}
