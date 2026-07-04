const ink = "#1c1a17";
const muted = "#6b6860";
const surface = "#fbfaf7";
const hair = "rgba(0,0,0,0.08)";

export default function Download() {
  return (
    <main style={{ maxWidth: 720, margin: "0 auto", padding: "80px 24px" }}>
      <a href="/" style={{ color: muted, textDecoration: "none" }}>← Osmo</a>
      <h1 style={{ fontSize: 40, fontFamily: "Georgia, serif", marginTop: 16 }}>Download Osmo for Mac</h1>
      <p style={{ color: muted, fontSize: 17, lineHeight: 1.55 }}>
        Osmo runs on macOS 14 and later, on Apple Silicon. It&apos;s a signed, notarized app you
        install outside the Mac App Store (required for the local read access that makes Osmo work).
      </p>
      <div style={{ marginTop: 24, padding: 20, background: surface, border: `1px solid ${hair}`, borderRadius: 16 }}>
        <div style={{ fontWeight: 600 }}>Osmo.dmg</div>
        <div style={{ color: muted, fontSize: 14, marginTop: 4 }}>
          Build in progress — the notarized release will appear here.
        </div>
        <button
          disabled
          style={{ marginTop: 14, background: ink, color: surface, border: "none", padding: "10px 20px", borderRadius: 999, opacity: 0.5 }}
        >
          Coming soon
        </button>
      </div>
      <ol style={{ color: muted, fontSize: 15, lineHeight: 1.7, marginTop: 28 }}>
        <li>Open Osmo. It&apos;ll walk you through granting Accessibility (for the overlay) and Full Disk Access (for iMessage), each with a plain reason.</li>
        <li>Connect the platforms you use — in order of how safe each is.</li>
        <li>Confirm which handles are the same person, set a goal with someone who matters, and Osmo drafts your first three takes.</li>
      </ol>
    </main>
  );
}
