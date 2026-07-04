// Real Unipile client — active only when UNIPILE_DSN + UNIPILE_API_KEY are set.
// THE API KEY NEVER LEAVES THIS MODULE and never reaches the Mac app: the key
// is tenant-wide (it can read every user's accounts), so every read a route
// makes is scoped to the caller's stored connection ids.

import type { HostedAuthOptions, UnipileAccount, UnipileClient } from "./client";

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
      // is how we map account_id → device without trusting the redirect.
      name: opts.linkId,
      notify_url: `${opts.origin}/api/connect/notify`,
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

  async sendMessage(accountId: string, chatId: string, text: string): Promise<{ messageId: string }> {
    const out = await this.call<{ message_id?: string; id?: string }>(
      `/api/v1/chats/${encodeURIComponent(chatId)}/messages`,
      { method: "POST", body: JSON.stringify({ account_id: accountId, text }) },
    );
    return { messageId: out.message_id ?? out.id ?? `unipile-${Date.now()}` };
  }
}

let instance: RealUnipileClient | null = null;
export function realUnipile(): UnipileClient {
  instance ??= new RealUnipileClient();
  return instance;
}
