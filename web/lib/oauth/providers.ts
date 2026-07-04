// Gmail + Slack OAuth, server-side (client secrets never reach the Mac app).
// Keyless mode (no GOOGLE_CLIENT_ID / SLACK_CLIENT_ID): the auth URL points at
// the local mock wizard, exactly like MockUnipile — one consistent connect UX.

import type { Platform } from "../connections/types";

export function isLiveOAuth(platform: Platform): boolean {
  if (platform === "gmail") return Boolean(process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET);
  if (platform === "slack") return Boolean(process.env.SLACK_CLIENT_ID && process.env.SLACK_CLIENT_SECRET);
  return false;
}

/** Where "Connect Gmail/Slack" sends the browser. */
export function authURL(platform: Platform, linkId: string, origin: string): string {
  if (!isLiveOAuth(platform)) {
    const url = new URL("/connect/mock", origin);
    url.searchParams.set("linkId", linkId);
    url.searchParams.set("platform", platform);
    return url.toString();
  }
  if (platform === "gmail") {
    const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    url.searchParams.set("client_id", process.env.GOOGLE_CLIENT_ID!);
    url.searchParams.set("redirect_uri", `${origin}/api/oauth/google/callback`);
    url.searchParams.set("response_type", "code");
    url.searchParams.set("scope", "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send");
    url.searchParams.set("access_type", "offline");
    url.searchParams.set("prompt", "consent");
    url.searchParams.set("state", linkId);
    return url.toString();
  }
  // slack
  const url = new URL("https://slack.com/oauth/v2/authorize");
  url.searchParams.set("client_id", process.env.SLACK_CLIENT_ID!);
  url.searchParams.set("user_scope", "channels:history,im:history,users:read,chat:write");
  url.searchParams.set("redirect_uri", `${origin}/api/oauth/slack/callback`);
  url.searchParams.set("state", linkId);
  return url.toString();
}

export async function exchangeGoogleCode(code: string, origin: string): Promise<unknown> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: process.env.GOOGLE_CLIENT_ID!,
      client_secret: process.env.GOOGLE_CLIENT_SECRET!,
      redirect_uri: `${origin}/api/oauth/google/callback`,
      grant_type: "authorization_code",
    }),
  });
  if (!res.ok) throw new Error(`google token exchange → ${res.status}`);
  return res.json();
}

export async function exchangeSlackCode(code: string, origin: string): Promise<unknown> {
  const res = await fetch("https://slack.com/api/oauth.v2.access", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: process.env.SLACK_CLIENT_ID!,
      client_secret: process.env.SLACK_CLIENT_SECRET!,
      redirect_uri: `${origin}/api/oauth/slack/callback`,
    }),
  });
  if (!res.ok) throw new Error(`slack token exchange → ${res.status}`);
  return res.json();
}
