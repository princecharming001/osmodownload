import type { Metadata } from "next";
import type { ReactNode } from "react";

export const metadata: Metadata = {
  title: "Osmo — your relationship memory, on your Mac",
  description:
    "Osmo reads your conversations locally, remembers every person across platforms, and drafts what to say to move each relationship toward a goal you set. Local-first. Your messages never leave your machine.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          fontFamily:
            "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
          background: "#f5f4ef",
          color: "#1c1a17",
        }}
      >
        {children}
      </body>
    </html>
  );
}
