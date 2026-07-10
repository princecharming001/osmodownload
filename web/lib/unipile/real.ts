// Real Unipile client — active only when UNIPILE_DSN + UNIPILE_API_KEY are set.
// THE API KEY NEVER LEAVES THIS MODULE and never reaches the Mac app: the key
// is tenant-wide (it can read every user's accounts), so every read a route
// makes is scoped to the caller's stored connection ids.

import type { HostedAuthOptions, UnipileAccount, UnipileAttendee, UnipileChat, UnipileClient, UnipileMessage, UnipileUserProfile, UnipileWebhook } from "./client";

const PROVIDER_BY_PLATFORM: Record<string, string> = {
  linkedin: "LINKEDIN",
  whatsapp: "WHATSAPP",
  instagram: "INSTAGRAM",
  x: "TWITTER",
};

class RealUnipileClient implements UnipileClient {
  readonly mode = "live" as const;
  private dsn = (process.env.UNIPILE_DSN ?? "").replace(/\/+$/, "");
  private key = process.env.UNIPILE_API_KEY ?? "";

  private async call<T>(path: string, init?: RequestInit): Promise<T> {
    const res = await fetch(`${this.dsn}${path}`, {
      ...init,
      headers: {
        "X-API-KEY": this.key,
        "accept": "application/json",
        ...(init?.body ? { "content-type": "application/json" } : {}),
        ...init?.headers,
      },
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new Error(`unipile ${path} → ${res.status}: ${body.slice(0, 300)}`);
    }
    return res.json() as Promise<T>;
  }

  async createHostedAuthLink(opts: HostedAuthOptions): Promise<{ url: string }> {
    const provider = PROVIDER_BY_PLATFORM[opts.platform];
    if (!provider) throw new Error(`platform ${opts.platform} is not Unipile-backed`);
    const body: Record<string, unknown> = {
      type: opts.reconnectAccountId ? "reconnect" : "create",
      providers: [provider],
      api_url: this.dsn,
      expiresOn: new Date(Date.now() + 30 * 60_000).toISOString(),
      // linkId rides in `name` — Unipile echoes it in the notify callback, which
      // is how we map account_id → device without trusting the redirect. The
      // shared secret rides in the notify_url query (Unipile can't send our
      // header) so the callback can be authenticated.
      name: opts.linkId,
      notify_url: process.env.OSMO_WEBHOOK_SECRET
        ? `${opts.origin}/api/connect/notify?secret=${encodeURIComponent(process.env.OSMO_WEBHOOK_SECRET)}`
        : `${opts.origin}/api/connect/notify`,
      success_redirect_url: `${opts.origin}/connect/done`,
      failure_redirect_url: `${opts.origin}/connect/done?failed=1`,
      ...(opts.reconnectAccountId ? { reconnect_account: opts.reconnectAccountId } : {}),
    };
    const out = await this.call<{ url: string }>(`/api/v1/hosted/accounts/link`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    return { url: out.url };
  }

  async listAccounts(): Promise<UnipileAccount[]> {
    const out = await this.call<{ items?: UnipileAccount[] }>(`/api/v1/accounts`);
    return out.items ?? [];
  }

  async listChats(accountId: string, cursor?: string): Promise<{ chats: UnipileChat[]; cursor: string | null }> {
    const q = new URLSearchParams({ account_id: accountId, limit: "50" });
    if (cursor) q.set("cursor", cursor);
    const out = await this.call<{ items?: UnipileChat[]; cursor?: string | null }>(`/api/v1/chats?${q}`);
    return { chats: out.items ?? [], cursor: out.cursor ?? null };
  }

  async listChatAttendees(chatId: string): Promise<UnipileAttendee[]> {
    type RawAttendee = Record<string, unknown>;
    const out = await this.call<{ items?: RawAttendee[] }>(
      `/api/v1/chats/${encodeURIComponent(chatId)}/attendees`);
    return (out.items ?? []).map((a) => ({
      // Messages reference senders by any of these ids — index them all.
      ids: [a.id, a.provider_id, a.attendee_provider_id]
        .filter((v): v is string => typeof v === "string" && v.length > 0)
        .filter((v, i, arr) => arr.indexOf(v) === i),
      name: (a.name as string | undefined) ?? null,
      pictureUrl: (a.picture_url as string | undefined)
        ?? (a.profile_picture_url as string | undefined) ?? null,
      isSelf: Boolean(a.is_self ?? a.is_me ?? false),
    })).filter((a) => a.ids.length > 0);
  }

  async getUserProfile(accountId: string, identifier: string): Promise<UnipileUserProfile | null> {
    type Raw = Record<string, unknown>;
    // Our contacts carry Unipile's internal attendee id, but /users wants the
    // LinkedIn member id ("ACoA…") — verified live: attendee id → 422, member
    // id → 200. Translate via the attendee lookup when needed.
    let memberId = identifier;
    if (!identifier.startsWith("ACoA")) {
      try {
        const attendee = await this.call<Raw>(
          `/api/v1/chat_attendees/${encodeURIComponent(identifier)}`);
        const pid = attendee.provider_id as string | undefined;
        if (!pid) return null;
        memberId = pid;
      } catch (e) {
        if (e instanceof Error && /→ (404|422):/.test(e.message)) return null;
        throw e;
      }
    }
    let out: Raw;
    try {
      // linkedin_sections=* unlocks work_experience/education/summary (the
      // bare call returns only the headline card).
      out = await this.call<Raw>(
        `/api/v1/users/${encodeURIComponent(memberId)}?account_id=${encodeURIComponent(accountId)}&linkedin_sections=%2A`);
    } catch (e) {
      // Stale/wrong handle → no profile, not a failure; anything else rethrows.
      if (e instanceof Error && /→ (404|422):/.test(e.message)) return null;
      throw e;
    }
    // Field names vary by provider version — read every known variant.
    const period = (start: unknown, end: unknown, openEnded: boolean): string | null => {
      if (!start) return null;
      return `${start}–${end || (openEnded ? "present" : "")}`.replace(/–$/, "");
    };
    const rawPositions = (out.work_experience ?? out.experience ?? []) as Raw[];
    const positions = rawPositions.slice(0, 5).map((p) => ({
      title: String(p.position ?? p.title ?? p.role ?? ""),
      company: String(p.company ?? p.company_name ?? p.organization ?? ""),
      period: period(p.start, p.end, true),
    })).filter((p) => p.title || p.company);
    const rawEducation = (out.education ?? []) as Raw[];
    const education = rawEducation.slice(0, 3).map((e) => ({
      school: String(e.school ?? e.school_name ?? e.institution ?? ""),
      degree: (e.degree ?? e.field_of_study ?? null) as string | null,
      period: period(e.start, e.end, false),
    })).filter((e) => e.school);
    const publicId = out.public_identifier as string | undefined;
    return {
      name: String(out.name ?? [out.first_name, out.last_name].filter(Boolean).join(" ")),
      headline: String(out.headline ?? ""),
      company: String(out.company ?? positions[0]?.company ?? ""),
      title: String(out.title ?? out.occupation ?? positions[0]?.title ?? ""),
      location: String(out.location ?? ""),
      summary: String(out.summary ?? out.about ?? "").slice(0, 600),
      positions,
      education,
      linkedinURL: (out.public_profile_url as string | undefined)
        ?? (publicId ? `https://www.linkedin.com/in/${publicId}` : null),
    };
  }

  async listMessages(accountId: string, cursor?: string, sinceISO?: string): Promise<{ messages: UnipileMessage[]; cursor: string | null }> {
    // Larger pages = fewer round-trips over a 2-month backfill. `after`/`since`
    // ask Unipile to bound the window by date; providers vary on the exact param,
    // so we set both — an ignored one is harmless, and paging still covers the
    // window via the backfill's time-cutoff loop.
    const q = new URLSearchParams({ account_id: accountId, limit: "250" });
    if (cursor) q.set("cursor", cursor);
    if (sinceISO) { q.set("after", sinceISO); q.set("since", sinceISO); }
    const out = await this.call<{ items?: UnipileMessage[]; cursor?: string | null }>(`/api/v1/messages?${q}`);
    return { messages: out.items ?? [], cursor: out.cursor ?? null };
  }

  async listChatMessages(chatId: string, cursor?: string): Promise<{ messages: UnipileMessage[]; cursor: string | null }> {
    // The GET sibling of sendMessage's POST on the same path — one chat's
    // messages, newest first, cursor-paged.
    const q = new URLSearchParams({ limit: "100" });
    if (cursor) q.set("cursor", cursor);
    const out = await this.call<{ items?: UnipileMessage[]; cursor?: string | null }>(
      `/api/v1/chats/${encodeURIComponent(chatId)}/messages?${q}`);
    return { messages: out.items ?? [], cursor: out.cursor ?? null };
  }

  async sendMessage(accountId: string, chatId: string, text: string): Promise<{ messageId: string }> {
    const out = await this.call<{ message_id?: string; id?: string }>(
      `/api/v1/chats/${encodeURIComponent(chatId)}/messages`,
      { method: "POST", body: JSON.stringify({ account_id: accountId, text }) },
    );
    return { messageId: out.message_id ?? out.id ?? `unipile-${Date.now()}` };
  }

  async listWebhooks(): Promise<UnipileWebhook[]> {
    const out = await this.call<{ items?: Record<string, unknown>[] }>(`/api/v1/webhooks`);
    return (out.items ?? []).map((w) => ({
      id: String(w.id ?? ""),
      name: String(w.name ?? ""),
      source: String(w.source ?? ""),
      requestUrl: String(w.request_url ?? w.requestUrl ?? ""),
    }));
  }

  async createWebhook(opts: { name: string; source: string; requestUrl: string }): Promise<UnipileWebhook> {
    const out = await this.call<{ id?: string }>(`/api/v1/webhooks`, {
      method: "POST",
      body: JSON.stringify({ name: opts.name, source: opts.source, request_url: opts.requestUrl }),
    });
    return { id: out.id ?? "", name: opts.name, source: opts.source, requestUrl: opts.requestUrl };
  }

  async deleteWebhook(id: string): Promise<void> {
    await this.call(`/api/v1/webhooks/${encodeURIComponent(id)}`, { method: "DELETE" });
  }

  async downloadAttachment(accountId: string, messageId: string, attachmentId: string): Promise<Buffer | null> {
    // Binary response — can't reuse `call` (JSON-only).
    const res = await fetch(
      `${this.dsn}/api/v1/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}?account_id=${encodeURIComponent(accountId)}`,
      { headers: { "X-API-KEY": this.key, accept: "*/*" } },
    );
    if (!res.ok) return null;
    return Buffer.from(await res.arrayBuffer());
  }
}

let instance: RealUnipileClient | null = null;
export function realUnipile(): UnipileClient {
  instance ??= new RealUnipileClient();
  return instance;
}
