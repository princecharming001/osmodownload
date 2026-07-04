const ink = "#08152e";
const muted = "#95a0aa";

export default function Privacy() {
  return (
    <main style={{ maxWidth: 720, margin: "0 auto", padding: "80px 24px", color: ink }}>
      <a href="/" style={{ color: muted, textDecoration: "none", fontSize: 14 }}>← Osmo</a>
      <h1 style={{ fontSize: 40, fontWeight: 600, marginTop: 16 }}>Privacy commitment</h1>
      <p style={{ color: muted, fontSize: 16, lineHeight: 1.6 }}>
        Osmo is built local-first. Here is exactly what happens to your data.
      </p>

      <Section title="Your messages stay on your Mac">
        Every message Osmo reads is stored in an encrypted database on your own machine
        (SQLCipher, whole-database AES). The key lives in your macOS Keychain. If someone
        copied the file, it would be unreadable without your key.
      </Section>

      <Section title="One permission, and we say so">
        The pill needs macOS Accessibility to see the message field you&apos;re typing in.
        No screen recording. No keylogging. It reads only the focused compose field of
        apps you&apos;re actively messaging in — nothing else on your screen.
      </Section>

      <Section title="Connecting a platform">
        When you connect an account, authentication happens through a hosted wizard;
        Osmo never sees your password. Message history syncs into the encrypted store on
        your Mac. Our servers relay realtime updates and hold the connection tokens needed
        to do that — they never store your message content.
      </Section>

      <Section title="The AI drafts">
        To draft a reply, the relevant conversation context is sent to a language model
        through a thin proxy under zero-retention terms. The proxy holds the AI key; the app
        never sees it, and nothing is stored. You approve every message — Osmo never sends
        on its own, and it coaches clarity and empathy, never manipulation.
      </Section>

      <Section title="Your controls">
        Export all your data to JSON, or erase everything on your Mac (which also removes the
        encryption key) at any time, from Settings → Privacy.
      </Section>

      <p style={{ color: muted, fontSize: 13, marginTop: 40 }}>© 2026 Osmo</p>
    </main>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section style={{ marginTop: 32 }}>
      <h2 style={{ fontSize: 18, fontWeight: 590, margin: "0 0 8px" }}>{title}</h2>
      <p style={{ color: muted, fontSize: 15, lineHeight: 1.6, margin: 0 }}>{children}</p>
    </section>
  );
}
