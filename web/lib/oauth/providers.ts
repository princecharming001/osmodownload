// Gmail + Slack OAuth, server-side (client secrets never reach the Mac app).
// Keyless mode (no GOOGLE_CLIENT_ID / SLACK_CLIENT_ID): the auth URL points at
// the local mock wizard, exactly like MockUnipile — one consistent connect UX.

import crypto from "node:crypto";
import type { Platform } from "../connections/types";

export function isLiveOAuth(platform: Platform): boolean {
  if (platform === "gmail") return Boolean(process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET);
  if (platform === "slack") return Boolean(process.env.SLACK_CLIENT_ID && process.env.SLACK_CLIENT_SECRET);
  if (platform === "x")     return Boolean(process.env.X_CLIENT_ID && process.env.X_CLIENT_SECRET);
  return false;
}

/** X OAuth callback. Points at the LOCAL backend so it doesn't depend on the
    ephemeral tunnel — the OAuth redirect is browser-side and the user's browser
    can always reach their own :3000. Overridable via X_REDIRECT_URI. */
export function xRedirectUri(): string {
  return process.env.X_REDIRECT_URI ?? "http://127.0.0.1:3000/api/oauth/x/callback";
}

/** PKCE pair — X OAuth 2.0 requires it even for confidential clients. */
export function makePkce(): { verifier: string; challenge: string } {
  const verifier = crypto.randomBytes(32).toString("base64url");
  const challenge = crypto.createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

/** Where "Connect Gmail/Slack" sends the browser. */
export function authURL(platform: Platform, linkId: string, origin: string, codeChallenge?: string): string {
  if (!isLiveOAuth(platform)) {
    const url = new URL("/connect/mock", origin);
    url.searchParams.set("linkId", linkId);
    url.searchParams.set("platform", platform);
    return url.toString();
  }
  if (platform === "x") {
    const url = new URL("https://x.com/i/oauth2/authorize");
    url.searchParams.set("response_type", "code");
    url.searchParams.set("client_id", process.env.X_CLIENT_ID!);
    url.searchParams.set("redirect_uri", xRedirectUri());
    // dm.read/write = the DMs; users.read = names; offline.access = refresh token.
    url.searchParams.set("scope", "dm.read dm.write tweet.read users.read offline.access");
    url.searchParams.set("state", linkId);
    url.searchParams.set("code_challenge", codeChallenge ?? "");
    url.searchParams.set("code_challenge_method", "S256");
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

/** X token exchange — confidential client → HTTP Basic auth, plus the PKCE
    verifier. Returns { access_token, refresh_token, expires_in, ... }. */
export async function exchangeXCode(code: string, verifier: string): Promise<unknown> {
  const basic = Buffer.from(`${process.env.X_CLIENT_ID}:${process.env.X_CLIENT_SECRET}`).toString("base64");
  const res = await fetch("https://api.x.com/2/oauth2/token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: `Basic ${basic}`,
    },
    body: new URLSearchParams({
      code,
      grant_type: "authorization_code",
      client_id: process.env.X_CLIENT_ID!,
      redirect_uri: xRedirectUri(),
      code_verifier: verifier,
    }),
  });
  if (!res.ok) throw new Error(`x token exchange → ${res.status}`);
  return res.json();
}

/** Refresh an expired X access token (offline.access grant). Best-effort; the
    caller re-persists the new token bundle. */
export async function refreshXToken(refreshToken: string): Promise<unknown> {
  const basic = Buffer.from(`${process.env.X_CLIENT_ID}:${process.env.X_CLIENT_SECRET}`).toString("base64");
  const res = await fetch("https://api.x.com/2/oauth2/token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: `Basic ${basic}`,
    },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: process.env.X_CLIENT_ID!,
    }),
  });
  if (!res.ok) throw new Error(`x token refresh → ${res.status}`);
  return res.json();
}

/** Refresh an expired Google (Gmail) access token. Returns a new token bundle
    ({ access_token, expires_in, ... }); Google omits refresh_token on refresh so
    the caller keeps the original. */
export async function refreshGoogleToken(refreshToken: string): Promise<unknown> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: process.env.GOOGLE_CLIENT_ID!,
      client_secret: process.env.GOOGLE_CLIENT_SECRET!,
    }),
  });
  if (!res.ok) throw new Error(`google token refresh → ${res.status}`);
  return res.json();
}
