// Orchid-token landing (paper ground, ink-alpha hairlines, iOS-blue accent,
// one serif hero word, real glass hero card).

const paper = "#fcfcfd";
const ink = "#08152e";
const muted = "#95a0aa";
const card = "#f5f6f8";
const accent = "#0a84ff";
const hair = "rgba(8,21,46,.10)";
const hairSoft = "rgba(8,21,46,.06)";

function Feature({ title, body }: { title: string; body: string }) {
  return (
    <div style={{ padding: 22, background: card, border: `1px solid ${hairSoft}`, borderRadius: 16 }}>
      <h3 style={{ margin: "0 0 6px", fontSize: 16, fontWeight: 590, color: ink }}>{title}</h3>
      <p style={{ margin: 0, color: muted, fontSize: 14, lineHeight: 1.55 }}>{body}</p>
    </div>
  );
}

/// A mock of the liquid-glass pill, expanded.
function PillMock() {
  return (
    <div style={{
      marginTop: 44, maxWidth: 420, padding: 20, borderRadius: 24,
      background: "rgba(255,255,255,.65)", backdropFilter: "blur(20px)",
      border: `1px solid ${hair}`, boxShadow: "0 8px 24px rgba(8,21,46,.12)",
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
        <span style={{ fontSize: 14, fontWeight: 590, color: ink }}>Sara Kim</span>
        <span style={{ fontSize: 11, color: muted, background: "#ebeef2", padding: "2px 8px", borderRadius: 999 }}>LinkedIn</span>
      </div>
      {[
        ["DIRECT", "Thursday 2pm works — I'll send an invite. Looking forward to it."],
        ["WARMER", "Thursday 2pm is perfect. Genuinely excited to dig into the sync layer with you."],
      ].map(([slant, text]) => (
        <div key={slant} style={{ padding: 12, background: card, borderRadius: 12, border: `1px solid ${hairSoft}`, marginBottom: 8 }}>
          <div style={{ fontSize: 10, fontWeight: 600, letterSpacing: 0.6, color: accent }}>{slant}</div>
          <div style={{ fontSize: 13, color: ink, marginTop: 2 }}>{text}</div>
        </div>
      ))}
    </div>
  );
}

export default function Home() {
  return (
    <main style={{ maxWidth: 960, margin: "0 auto", padding: "80px 24px", color: ink }}>
      <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: 1, color: muted, textTransform: "uppercase" }}>
        Local-first · Mac
      </div>
      <h1 style={{ fontSize: 52, lineHeight: 1.05, margin: "12px 0 0", fontWeight: 600 }}>
        Every conversation,<br /><span style={{ fontFamily: "'New York', Georgia, serif", fontStyle: "italic" }}>remembered.</span>
      </h1>
      <p style={{ fontSize: 19, color: muted, lineHeight: 1.55, maxWidth: 640, marginTop: 20 }}>
        Osmo connects your messages across LinkedIn, WhatsApp, Instagram, Gmail, Slack, and
        iMessage, remembers every person, and drafts what to say — in your voice, toward what
        you want. It appears the moment you start writing.
      </p>
      <div style={{ display: "flex", gap: 12, marginTop: 28, alignItems: "center" }}>
        <a href="/download" style={{ background: accent, color: "#fff", padding: "12px 22px", borderRadius: 999, textDecoration: "none", fontWeight: 550, fontSize: 15 }}>
          Download for Mac
        </a>
        <a href="#how" style={{ color: ink, padding: "12px 22px", textDecoration: "none", fontSize: 15 }}>How it works →</a>
      </div>

      <PillMock />

      <section id="how" style={{ marginTop: 72, display: "grid", gap: 16, gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))" }}>
        <Feature title="Connect in one click" body="Link your accounts and Osmo pulls your full history and keeps it live — no copy-paste, no screenshots." />
        <Feature title="One memory per person" body="The same person is recognized across every platform, with everything you know about them in one place." />
        <Feature title="Psychology, not vibes" body="Drafts use real technique — tactical empathy, repair, reciprocity, style-matching — and tell you why each works." />
        <Feature title="Projects, not an inbox" body="Set a goal and tone for someone who matters. Every message advances it. A morning digest keeps you on track." />
        <Feature title="The pill, right where you type" body="A quiet glass pill appears beside any messaging app with three ways to reply — send, tweak, or ignore." />
        <Feature title="You approve everything" body="Three ways to say it, in your own voice. Osmo never sends on its own." />
      </section>

      <section style={{ marginTop: 72, padding: 28, border: `1px solid ${hair}`, borderRadius: 16, background: card }}>
        <h2 style={{ marginTop: 0, fontSize: 22, fontWeight: 590 }}>Your words stay yours</h2>
        <p style={{ color: muted, fontSize: 15, lineHeight: 1.6, margin: 0 }}>
          Messages and memory live encrypted on your Mac. No screen recording. No keylogging.
          One permission. You approve every message; Osmo never sends on its own, and it coaches
          clarity and empathy — never manipulation. <a href="/privacy" style={{ color: accent }}>Read the privacy commitment →</a>
        </p>
      </section>

      <footer style={{ marginTop: 64, color: muted, fontSize: 13, display: "flex", gap: 16 }}>
        <span>© 2026 Osmo</span>
        <a href="/download" style={{ color: muted }}>Download</a>
        <a href="/privacy" style={{ color: muted }}>Privacy</a>
      </footer>
    </main>
  );
}
