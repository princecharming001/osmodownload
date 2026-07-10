// Deep-fetch scope — how many of the most-recently-active NON-AUTOMATED
// conversations per platform get their FULL history pulled (beyond the
// account-wide sweep), and how many messages each is paged to. The sweep gives
// breadth; this gives the "last ~10 human conversations with full context"
// depth. Demo scope shrinks it so first imports stay instant.

import { envInt } from "./scope";

export type DeepFetchScope = {
  /** Conversations per platform that get the full-history pass. */
  conversations: number;
  /** Message ceiling per deep-fetched conversation. */
  messagesPerConversation: number;
};

export function deepFetchScope(): DeepFetchScope {
  const demo = (process.env.OSMO_BACKFILL_SCOPE ?? "").toLowerCase() === "demo";
  return {
    conversations: envInt("OSMO_DEEP_FETCH_CONVERSATIONS", demo ? 2 : 10),
    messagesPerConversation: envInt("OSMO_DEEP_FETCH_MESSAGES", 100),
  };
}
