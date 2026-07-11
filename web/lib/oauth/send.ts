// Live send for the OAuth platforms (Gmail, Slack) — Unipile only covers
// LinkedIn/WhatsApp/Instagram, so Gmail/Slack must use their own APIs with the
// user's stored OAuth token (which never leaves the backend).

type GmailTokens = { access_token?: string };
type SlackTokens = { authed_user?: { access_token?: string } };
type XTokens = { access_token?: string };

/** Reply into an X DM conversation. platformThreadID is the dm_conversation_id. */
export async function sendX(tokens: unknown, conversationId: string, text: string): Promise<{ messageId: string }> {
  const token = (tokens as XTokens)?.access_token;
  if (!token) throw new Error("x: no access token");
  const res = await fetch(`https://api.x.com/2/dm_conversations/${conversationId}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });
  const data = await res.json() as { data?: { dm_event_id?: string }; errors?: unknown };
  const id = data.data?.dm_event_id;
  if (!id) throw new Error(`x dm send: ${JSON.stringify(data.errors ?? "failed").slice(0, 200)}`);
  return { messageId: id };
}

/** Reply into a Slack DM/channel. platformThreadID is the channel id. */
export async function sendSlack(tokens: unknown, channel: string, text: string): Promise<{ messageId: string }> {
  const token = (tokens as SlackTokens)?.authed_user?.access_token;
  if (!token) throw new Error("slack: no user token");
  const res = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "content-type": "application/json; charset=utf-8" },
    body: JSON.stringify({ channel, text }),
  });
  const data = await res.json() as { ok?: boolean; ts?: string; error?: string };
  if (!data.ok) throw new Error(`slack chat.postMessage: ${data.error ?? "failed"}`);
  return { messageId: `${channel}:${data.ts}` };   // matches the backfill's id scheme
}

/** Reply into a Gmail thread. platformThreadID is the Gmail threadId; we look up
    the thread's latest message to address the reply + thread it correctly. */
export async function sendGmail(tokens: unknown, threadId: string, text: string): Promise<{ messageId: string }> {
  const token = (tokens as GmailTokens)?.access_token;
  if (!token) throw new Error("gmail: no access token");
  const auth = { Authorization: `Bearer ${token}` };
  const api = "https://gmail.googleapis.com/gmail/v1/users/me";

  // The user's own address — a reply must go to the last COUNTERPARTY, not
  // "whoever last wrote" (after your own reply, that's YOU: the second send
  // in a row used to email the user themselves).
  const profile = await fetch(`${api}/profile`, { headers: auth })
    .then(r => r.json()).catch(() => ({})) as { emailAddress?: string };
  const selfAddr = (profile.emailAddress ?? "").toLowerCase();

  const thread = await fetch(
    `${api}/threads/${threadId}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Message-ID`,
    { headers: auth },
  ).then(r => r.json()) as { messages?: { payload?: { headers?: { name: string; value: string }[] } }[] };
  const msgs = thread.messages ?? [];
  const headerValue = (m: typeof msgs[number] | undefined, n: string) =>
    m?.payload?.headers?.find(x => x.name.toLowerCase() === n.toLowerCase())?.value ?? "";
  const isFromSelf = (m: typeof msgs[number]) =>
    selfAddr !== "" && headerValue(m, "from").toLowerCase().includes(selfAddr);

  // Last message from someone else; if the whole thread is self (note-to-self),
  // fall back to the last message of any kind.
  const counterpart = [...msgs].reverse().find(m => !isFromSelf(m)) ?? msgs[msgs.length - 1];
  const last = msgs[msgs.length - 1];

  const to = headerValue(counterpart, "reply-to") || headerValue(counterpart, "from");
  const subjectRaw = headerValue(last, "subject") || headerValue(counterpart, "subject");
  const subject = subjectRaw.toLowerCase().startsWith("re:") ? subjectRaw : `Re: ${subjectRaw}`;
  const inReplyTo = headerValue(last, "message-id");

  // NOTE: the blank line separating headers from body is STRUCTURAL — it must
  // never pass through a filter (a filter(Boolean) here once stripped it and
  // every email went out with an EMPTY body).
  const headerLines = [
    `To: ${to}`,
    `Subject: ${subject}`,
    inReplyTo ? `In-Reply-To: ${inReplyTo}` : "",
    inReplyTo ? `References: ${inReplyTo}` : "",
    "Content-Type: text/plain; charset=UTF-8",
  ].filter(Boolean);
  const mime = headerLines.join("\r\n") + "\r\n\r\n" + text;

  // base64url, no padding — Gmail's raw format.
  const raw = Buffer.from(mime, "utf8").toString("base64")
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const res = await fetch(`${api}/messages/send`, {
    method: "POST",
    headers: { ...auth, "content-type": "application/json" },
    body: JSON.stringify({ raw, threadId }),
  });
  const data = await res.json() as { id?: string; error?: unknown };
  if (!data.id) throw new Error(`gmail send: ${JSON.stringify(data.error ?? "failed").slice(0, 200)}`);
  return { messageId: data.id };
}
