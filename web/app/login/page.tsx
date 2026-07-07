"use client";

import { useState } from "react";

const ink = "#08152e";
const muted = "#95a0aa";
const card = "#f5f6f8";
const accent = "#0a84ff";
const hair = "rgba(8,21,46,.10)";

export default function Login() {
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [devLink, setDevLink] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null); setDevLink(null);
    try {
      const res = await fetch("/api/auth/request", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email }),
      });
      const data = await res.json();
      if (!res.ok) { setError(data.error ?? "Something went wrong."); return; }
      setSent(true);
      if (data.mode === "mock") setDevLink(data.verifyUrl);
    } catch {
      setError("Couldn't reach the server — try again.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main style={{ maxWidth: 440, margin: "0 auto", padding: "80px 24px", color: ink }}>
      <a href="/" style={{ color: muted, textDecoration: "none", fontSize: 14 }}>← Osmo</a>
      <h1 style={{ fontSize: 32, fontWeight: 600, marginTop: 16 }}>Sign in or sign up</h1>
      <p style={{ color: muted, fontSize: 15, lineHeight: 1.55 }}>
        Enter your email and we&apos;ll send a one-time link — no password. New here? This creates
        your account. It&apos;s the same account you use in the Mac app.
      </p>

      {!sent ? (
        <form onSubmit={submit} style={{ marginTop: 24 }}>
          <input
            type="email" required placeholder="you@example.com" value={email}
            onChange={e => setEmail(e.target.value)}
            style={{
              width: "100%", boxSizing: "border-box", padding: "12px 14px", fontSize: 15,
              borderRadius: 12, border: `1px solid ${hair}`, background: card, color: ink,
            }}
          />
          {error && <p style={{ color: "#ff3b30", fontSize: 13, marginTop: 8 }}>{error}</p>}
          <button
            type="submit" disabled={busy}
            style={{
              marginTop: 14, width: "100%", background: accent, color: "#fff", border: "none",
              padding: "12px 20px", borderRadius: 999, fontWeight: 550, fontSize: 15,
              opacity: busy ? 0.6 : 1, cursor: busy ? "default" : "pointer",
            }}
          >
            {busy ? "Sending…" : "Send magic link"}
          </button>
        </form>
      ) : (
        <div style={{ marginTop: 24, padding: 20, background: card, border: `1px solid ${hair}`, borderRadius: 16 }}>
          <div style={{ fontWeight: 590 }}>Check your email</div>
          <div style={{ color: muted, fontSize: 14, marginTop: 4 }}>
            We sent a sign-in link to {email}. It expires in 15 minutes.
          </div>
          {devLink && (
            <div style={{ marginTop: 14, paddingTop: 14, borderTop: `1px solid ${hair}` }}>
              <div style={{ fontSize: 12, color: muted, fontWeight: 600, letterSpacing: 0.4, textTransform: "uppercase" }}>
                Dev mode — no email provider configured yet
              </div>
              <a href={devLink} style={{ color: accent, fontSize: 14, wordBreak: "break-all" }}>
                {devLink}
              </a>
            </div>
          )}
        </div>
      )}
    </main>
  );
}
