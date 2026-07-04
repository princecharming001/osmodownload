const ink = "#1c1a17";
const muted = "#6b6860";
const gold = "#d4a017";
const surface = "#fbfaf7";
const hair = "rgba(0,0,0,0.08)";

function Feature({ title, body }: { title: string; body: string }) {
  return (
    <div style={{ padding: 20, background: surface, border: `1px solid ${hair}`, borderRadius: 16 }}>
      <h3 style={{ margin: "0 0 6px", fontSize: 17 }}>{title}</h3>
      <p style={{ margin: 0, color: muted, fontSize: 15, lineHeight: 1.5 }}>{body}</p>
    </div>
  );
}

export default function Home() {
  return (
    <main style={{ maxWidth: 920, margin: "0 auto", padding: "80px 24px" }}>
      <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: 0.6, color: gold, textTransform: "uppercase" }}>
        Local-first · Mac
      </div>
      <h1 style={{ fontSize: 52, lineHeight: 1.05, margin: "12px 0 0", fontFamily: "Georgia, serif" }}>
        Know exactly what to say —<br />to everyone who matters.
      </h1>
      <p style={{ fontSize: 20, color: muted, lineHeight: 1.5, maxWidth: 640, marginTop: 20 }}>
        Osmo reads your conversations on your Mac, remembers every person across iMessage,
        Gmail, Slack, WhatsApp and more, and drafts what to say to move each relationship toward
        a goal you set. Grounded in real communication psychology. Your messages never leave your machine.
      </p>
      <div style={{ display: "flex", gap: 12, marginTop: 28 }}>
        <a href="/download" style={{ background: ink, color: surface, padding: "12px 22px", borderRadius: 999, textDecoration: "none", fontWeight: 600 }}>
          Download for Mac
        </a>
        <a href="#how" style={{ color: ink, padding: "12px 22px", textDecoration: "none" }}>How it works →</a>
      </div>

      <section id="how" style={{ marginTop: 72, display: "grid", gap: 16, gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))" }}>
        <Feature title="It reads locally" body="Osmo reads your conversations on your own Mac — nothing is uploaded. The privacy is the product." />
        <Feature title="One memory per person" body="The same person is recognized across every platform, with everything you know about them in one place." />
        <Feature title="Psychology, not vibes" body="Drafts use real technique — tactical empathy, repair, reciprocity, style-matching — and tell you why each works." />
        <Feature title="Projects, not an inbox" body="Set a goal and tone for someone who matters. Every message advances it. A morning queue keeps you on track." />
        <Feature title="Three ways to say it" body="Direct, warmer, lighter — in your own voice. You approve every message before it sends." />
        <Feature title="Overlay, right where you text" body="A quiet panel appears beside your messaging app with the reply, ready to send or drop in." />
      </section>

      <section style={{ marginTop: 72, padding: 24, border: `1px solid ${hair}`, borderRadius: 16, background: surface }}>
        <h2 style={{ marginTop: 0, fontSize: 22 }}>Your words stay yours</h2>
        <p style={{ color: muted, fontSize: 15, lineHeight: 1.6, margin: 0 }}>
          Messages and memory live encrypted on your Mac. When you turn on sync, it&apos;s
          end-to-end encrypted — our servers only ever hold ciphertext they can&apos;t read.
          You approve every message; Osmo never sends on its own. It coaches clarity and empathy,
          never manipulation.
        </p>
      </section>

      <footer style={{ marginTop: 64, color: muted, fontSize: 13 }}>
        © {new Date().getFullYear()} Osmo · <a href="/download" style={{ color: muted }}>Download</a>
      </footer>
    </main>
  );
}
