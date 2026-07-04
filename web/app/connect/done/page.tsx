"use client";

// Post-connect landing (also the live-mode success_redirect_url target).
// Tells the user to return to the app — the app learns about the connection
// via SSE + reconciliation, not via this page.

import { Suspense } from "react";
import { useSearchParams } from "next/navigation";

function Done() {
  const failed = useSearchParams().get("failed") === "1";
  return (
    <main style={{
      minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center",
      background: "#fcfcfd", color: "#08152e",
      fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif",
    }}>
      <div style={{ textAlign: "center", maxWidth: 380, padding: 24 }}>
        <div style={{ fontSize: 44, marginBottom: 16 }}>{failed ? "···" : "✓"}</div>
        <h1 style={{ fontSize: 22, fontWeight: 600, margin: "0 0 8px" }}>
          {failed ? "Connection didn't complete" : "Connected"}
        </h1>
        <p style={{ fontSize: 14, lineHeight: 1.5, color: "#95a0aa" }}>
          {failed
            ? "No changes were made. You can close this tab and try again from Osmo."
            : "You can close this tab and return to Osmo — your conversations are syncing now."}
        </p>
      </div>
    </main>
  );
}

export default function Page() {
  return <Suspense fallback={null}><Done /></Suspense>;
}
