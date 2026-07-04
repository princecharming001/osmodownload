// The Unipile seam. Real client when UNIPILE_DSN + UNIPILE_API_KEY are set;
// MockUnipile otherwise (keyless demo mode — the default). Routes never know
// which one they're talking to.

import type { Platform } from "../connections/types";
import { mockUnipile } from "./mock";
import { realUnipile } from "./real";

export interface HostedAuthOptions {
  linkId: string;
  platform: Platform;
  deviceId: string;
  /** Absolute origin of this deployment, e.g. http://localhost:3000 */
  origin: string;
  reconnectAccountId?: string;
}

export interface UnipileAccount {
  id: string;
  provider: string;
  name: string;
  status: "OK" | "CREDENTIALS" | "CONNECTING" | string;
}

export interface UnipileClient {
  readonly mode: "mock" | "live";
  createHostedAuthLink(opts: HostedAuthOptions): Promise<{ url: string }>;
  listAccounts(): Promise<UnipileAccount[]>;
  /** Send into a chat; resolves with the provider's real message id. */
  sendMessage(accountId: string, chatId: string, text: string): Promise<{ messageId: string }>;
}

export function isLiveUnipile(): boolean {
  return Boolean(process.env.UNIPILE_DSN && process.env.UNIPILE_API_KEY);
}

export function getUnipile(): UnipileClient {
  return isLiveUnipile() ? realUnipile() : mockUnipile();
}
