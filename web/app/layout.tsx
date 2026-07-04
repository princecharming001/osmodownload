import type { Metadata } from "next";
import type { ReactNode } from "react";

export const metadata: Metadata = {
  title: "Osmo — every conversation, remembered",
  description:
    "Osmo connects your messages across every platform, remembers every person, and drafts what to say — in your voice, toward what you want. Local-first, encrypted on your Mac.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          fontFamily:
            "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Roboto, sans-serif",
          background: "#fcfcfd",
          color: "#08152e",
        }}
      >
        {children}
      </body>
    </html>
  );
}
