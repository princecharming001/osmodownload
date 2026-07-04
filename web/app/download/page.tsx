const paper = "#fcfcfd";
const ink = "#08152e";
const muted = "#95a0aa";
const card = "#f5f6f8";
const accent = "#0a84ff";
const hair = "rgba(8,21,46,.10)";

export default function Download() {
  return (
    <main style={{ maxWidth: 720, margin: "0 auto", padding: "80px 24px", color: ink }}>
      <a href="/" style={{ color: muted, textDecoration: "none", fontSize: 14 }}>← Osmo</a>
      <h1 style={{ fontSize: 40, fontWeight: 600, marginTop: 16 }}>Download Osmo for Mac</h1>
      <p style={{ color: muted, fontSize: 16, lineHeight: 1.55 }}>
        Osmo runs on macOS 14 and later, on Apple Silicon. It&apos;s a signed, notarized app you
        install outside the Mac App Store (required for the local access that makes Osmo work).
      </p>
      <div style={{ marginTop: 24, padding: 22, background: card, border: `1px solid ${hair}`, borderRadius: 16 }}>
        <div style={{ fontWeight: 590 }}>Osmo 0.2.0</div>
        <div style={{ color: muted, fontSize: 14, marginTop: 4 }}>
          Beta build in progress — the notarized release lands here.
        </div>
        <button
          disabled
          style={{ marginTop: 14, background: accent, color: "#fff", border: "none", padding: "10px 20px", borderRadius: 999, opacity: 0.5, fontWeight: 550 }}
        >
          Coming soon
        </button>
      </div>
      <ol style={{ color: muted, fontSize: 15, lineHeight: 1.7, marginTop: 28 }}>
        <li>Open Osmo — it walks you through picking a summon shortcut and granting one Accessibility permission, with a plain reason.</li>
        <li>Try the pill on a practice message before you connect anything.</li>
        <li>Connect the platforms you use — one click each — and set a goal with someone who matters.</li>
      </ol>
      <p style={{ color: muted, fontSize: 13, marginTop: 32 }}>
        <a href="/privacy" style={{ color: accent }}>Privacy commitment →</a>
      </p>
    </main>
  );
}
