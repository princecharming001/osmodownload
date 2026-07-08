// The ACCOUNTS + SUBSCRIPTION layer — the durable identity/billing spine that
// the Mac app AND the website both authenticate against, so a person has ONE
// account and ONE subscription across both.
//
// This is deliberately SEPARATE from the in-memory message-sync store
// (lib/connections/memoryStore.ts). Message content is local-first and stays
// on the user's Mac; only identity + subscription live here, in a real
// Postgres (Supabase). That mirrors how local-first apps (1Password, Bear,
// Things) split a cloud account/license from on-device data.
//
// Backing store is chosen at runtime:
//   • SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY set → real Postgres (persistent,
//     shared across app + web + restarts).
//   • otherwise → an in-memory fallback (keyless/demo + the test suite), same
//     async interface, so nothing downstream knows the difference.
//
// All access is server-side with the service role; the osmo_* tables are
// RLS-locked so anon/publishable keys can't touch them.

import crypto from "node:crypto";
import type { Connection } from "../connections/types";

export interface AccountUser {
  id: string;
  email: string;
  appleUserID: string | null;
  displayName: string | null;
  createdAt: string;
}

export interface AccountDevice {
  id: string;
  token: string;
  userId: string | null;
  createdAt: string;
}

/** Structurally compatible with lib/license's LicenseRecord so it can be
    handed straight to buildSignedEntitlement(). `trialStartedAt` is epoch ms. */
export interface Subscription {
  deviceId: string;
  licenseKey: string | null;
  subscriptionActive: boolean;
  plan: string | null;
  trialStartedAt: number | null;
}

export interface MagicLinkRow { token: string; email: string; expiresAt: number; used: boolean; }
export interface WebSessionRow { token: string; userId: string; createdAt: number; }

export interface AccountsStore {
  // devices (durable copy — the linkage anchor; the sync store keeps its own
  // ephemeral token map for the message path)
  upsertDevice(id: string, token: string): Promise<AccountDevice>;
  deviceById(id: string): Promise<AccountDevice | null>;
  deviceByToken(token: string): Promise<AccountDevice | null>;
  devicesForUser(userId: string): Promise<AccountDevice[]>;
  linkDeviceToUser(deviceId: string, userId: string): Promise<void>;

  // users (sign-up = first login; find-or-create)
  findOrCreateUserByEmail(email: string): Promise<AccountUser>;
  findOrCreateUserByApple(appleUserID: string, email: string | null, name: string | null): Promise<AccountUser | null>;
  userById(id: string): Promise<AccountUser | null>;

  // subscription (resolves device → user → sub, else the device's own sub)
  subscriptionForDevice(deviceId: string): Promise<Subscription>;
  setSubscriptionForDevice(deviceId: string, patch: Partial<Omit<Subscription, "deviceId">>): Promise<Subscription>;
  startTrialForDevice(deviceId: string, nowMs: number): Promise<Subscription>;
  /** A user's own subscription (the website has no device to resolve through). */
  subscriptionForUser(userId: string): Promise<Subscription>;
  setSubscriptionForUser(userId: string, patch: Partial<Omit<Subscription, "deviceId">>): Promise<Subscription>;

  // web login (magic link + session tied to a user)
  createMagicLink(email: string, nowMs: number): Promise<MagicLinkRow>;
  consumeMagicLink(token: string, nowMs: number): Promise<string | null>;
  createWebSession(userId: string): Promise<WebSessionRow>;
  webSessionUser(token: string): Promise<AccountUser | null>;
  deleteWebSession(token: string): Promise<void>;

  // free-tier quota usage — durable per-device week bucket (osmo_usage), so the
  // count survives restart/redeploy instead of resetting to zero.
  usageCount(deviceId: string, weekStart: number): Promise<number>;
  /** Atomic reserve: +1 (reset on a new week); returns the new count. */
  bumpUsage(deviceId: string, weekStart: number): Promise<number>;
  /** Atomic refund: -1 (never below 0), used when an upstream call fails. */
  refundUsage(deviceId: string, weekStart: number): Promise<number>;

  // durable OAuth tokens (osmo_oauth_tokens) so connections survive redeploy.
  oauthTokens(deviceId: string, platform: string): Promise<Record<string, unknown> | null>;
  setOAuthTokens(deviceId: string, platform: string, tokens: Record<string, unknown>): Promise<void>;

  // durable connection records (osmo_connections) so a device's connections
  // survive redeploy (the in-memory set is empty after restart).
  upsertConnection(c: Connection): Promise<void>;
  connectionsForDevice(deviceId: string): Promise<Connection[]>;
  deleteConnection(id: string): Promise<void>;

  // durable webhook idempotency (osmo_processed_events): returns true the FIRST
  // time an event id is seen (process it), false on redelivery (dedup).
  markEventProcessed(eventId: string, source: string): Promise<boolean>;

  // deletion
  purgeByDevice(deviceId: string): Promise<void>;
}

const TRIAL_MS = 15 * 60_000;
const freeSub = (deviceId: string): Subscription => ({
  deviceId, licenseKey: null, subscriptionActive: false, plan: null, trialStartedAt: null,
});

// ───────────────────────────────────────────────────────────────────────────
// In-memory fallback (keyless/demo + tests). Same async surface.

interface Mem {
  users: Map<string, AccountUser>;                 // id → user
  devices: Map<string, AccountDevice>;             // id → device
  subs: Map<string, Subscription>;                 // `${ownerType}:${ownerId}` → sub (deviceId filled per-call)
  magic: Map<string, MagicLinkRow>;                // token → link
  sessions: Map<string, WebSessionRow>;            // token → session
  usage: Map<string, number>;                      // `${deviceId}:${weekStart}` → count
  oauth: Map<string, Record<string, unknown>>;     // `${deviceId}:${platform}` → tokens
  conns: Map<string, Connection>;                  // connection id → record
  processed: Set<string>;                           // `${source}:${eventId}` webhook dedup
}
function freshMem(): Mem {
  return { users: new Map(), devices: new Map(), subs: new Map(), magic: new Map(), sessions: new Map(), usage: new Map(), oauth: new Map(), conns: new Map(), processed: new Set() };
}

class MemoryAccountsStore implements AccountsStore {
  constructor(private m: Mem) {}

  async upsertDevice(id: string, token: string): Promise<AccountDevice> {
    const existing = this.m.devices.get(id);
    const dev: AccountDevice = existing
      ? { ...existing, token }
      : { id, token, userId: null, createdAt: new Date().toISOString() };
    this.m.devices.set(id, dev);
    return dev;
  }
  async deviceById(id: string) { return this.m.devices.get(id) ?? null; }
  async deviceByToken(token: string) { for (const d of this.m.devices.values()) if (d.token === token) return d; return null; }
  async devicesForUser(userId: string) { return [...this.m.devices.values()].filter(d => d.userId === userId); }
  async linkDeviceToUser(deviceId: string, userId: string) {
    const dev = this.m.devices.get(deviceId);
    if (dev) this.m.devices.set(deviceId, { ...dev, userId });
    // merge a device-owned sub into the user if the user has none active
    const devSub = this.m.subs.get(`device:${deviceId}`);
    const userKey = `user:${userId}`;
    if (devSub && !this.m.subs.get(userKey)?.subscriptionActive) {
      this.m.subs.set(userKey, { ...devSub });
      this.m.subs.delete(`device:${deviceId}`);
    }
  }

  async findOrCreateUserByEmail(email: string): Promise<AccountUser> {
    const norm = email.trim().toLowerCase();
    for (const u of this.m.users.values()) if (u.email === norm) return u;
    const user: AccountUser = { id: crypto.randomUUID(), email: norm, appleUserID: null, displayName: null, createdAt: new Date().toISOString() };
    this.m.users.set(user.id, user);
    return user;
  }
  async findOrCreateUserByApple(appleUserID: string, email: string | null, name: string | null): Promise<AccountUser | null> {
    for (const u of this.m.users.values()) if (u.appleUserID === appleUserID) return u;
    const norm = email?.trim().toLowerCase() ?? null;
    if (norm) {
      for (const u of this.m.users.values()) {
        if (u.email === norm) { const linked = { ...u, appleUserID, displayName: u.displayName ?? name }; this.m.users.set(u.id, linked); return linked; }
      }
    }
    if (!norm) return null; // can't create without an email (schema requires it)
    const user: AccountUser = { id: crypto.randomUUID(), email: norm, appleUserID, displayName: name, createdAt: new Date().toISOString() };
    this.m.users.set(user.id, user);
    return user;
  }
  async userById(id: string) { return this.m.users.get(id) ?? null; }

  private resolveOwner(deviceId: string): { key: string; sub: Subscription | undefined } {
    const dev = this.m.devices.get(deviceId);
    const key = dev?.userId ? `user:${dev.userId}` : `device:${deviceId}`;
    return { key, sub: this.m.subs.get(key) };
  }
  async subscriptionForDevice(deviceId: string): Promise<Subscription> {
    const { sub } = this.resolveOwner(deviceId);
    return sub ? { ...sub, deviceId } : freeSub(deviceId);
  }
  async setSubscriptionForDevice(deviceId: string, patch: Partial<Omit<Subscription, "deviceId">>): Promise<Subscription> {
    const { key, sub } = this.resolveOwner(deviceId);
    const merged: Subscription = { ...(sub ?? freeSub(deviceId)), ...patch, deviceId };
    this.m.subs.set(key, merged);
    return merged;
  }
  async startTrialForDevice(deviceId: string, nowMs: number): Promise<Subscription> {
    const cur = await this.subscriptionForDevice(deviceId);
    if (cur.trialStartedAt != null) return cur;          // idempotent — never re-opens
    return this.setSubscriptionForDevice(deviceId, { trialStartedAt: nowMs });
  }
  async subscriptionForUser(userId: string): Promise<Subscription> {
    const sub = this.m.subs.get(`user:${userId}`);
    return sub ? { ...sub, deviceId: "" } : freeSub("");
  }
  async setSubscriptionForUser(userId: string, patch: Partial<Omit<Subscription, "deviceId">>): Promise<Subscription> {
    const cur = this.m.subs.get(`user:${userId}`) ?? freeSub("");
    const merged: Subscription = { ...cur, ...patch, deviceId: "" };
    this.m.subs.set(`user:${userId}`, merged);
    return merged;
  }

  async createMagicLink(email: string, nowMs: number): Promise<MagicLinkRow> {
    const link: MagicLinkRow = { token: crypto.randomBytes(24).toString("base64url"), email: email.trim().toLowerCase(), expiresAt: nowMs + TRIAL_MS, used: false };
    this.m.magic.set(link.token, link);
    return link;
  }
  async consumeMagicLink(token: string, nowMs: number): Promise<string | null> {
    const link = this.m.magic.get(token);
    if (!link || link.used || link.expiresAt < nowMs) return null;
    link.used = true;
    return link.email;
  }
  async createWebSession(userId: string): Promise<WebSessionRow> {
    const s: WebSessionRow = { token: crypto.randomBytes(24).toString("base64url"), userId, createdAt: Date.now() };
    this.m.sessions.set(s.token, s);
    return s;
  }
  async webSessionUser(token: string): Promise<AccountUser | null> {
    const s = this.m.sessions.get(token);
    return s ? (this.m.users.get(s.userId) ?? null) : null;
  }
  async deleteWebSession(token: string) { this.m.sessions.delete(token); }

  async usageCount(deviceId: string, weekStart: number): Promise<number> {
    return this.m.usage.get(`${deviceId}:${weekStart}`) ?? 0;
  }
  async bumpUsage(deviceId: string, weekStart: number): Promise<number> {
    const key = `${deviceId}:${weekStart}`;
    const next = (this.m.usage.get(key) ?? 0) + 1;
    this.m.usage.set(key, next);
    return next;
  }
  async refundUsage(deviceId: string, weekStart: number): Promise<number> {
    const key = `${deviceId}:${weekStart}`;
    const next = Math.max(0, (this.m.usage.get(key) ?? 0) - 1);
    this.m.usage.set(key, next);
    return next;
  }
  async oauthTokens(deviceId: string, platform: string): Promise<Record<string, unknown> | null> {
    return this.m.oauth.get(`${deviceId}:${platform}`) ?? null;
  }
  async setOAuthTokens(deviceId: string, platform: string, tokens: Record<string, unknown>): Promise<void> {
    this.m.oauth.set(`${deviceId}:${platform}`, tokens);
  }
  async upsertConnection(c: Connection): Promise<void> { this.m.conns.set(c.id, { ...c }); }
  async connectionsForDevice(deviceId: string): Promise<Connection[]> {
    return [...this.m.conns.values()].filter((c) => c.deviceId === deviceId);
  }
  async deleteConnection(id: string): Promise<void> { this.m.conns.delete(id); }
  async markEventProcessed(eventId: string, source: string): Promise<boolean> {
    const key = `${source}:${eventId}`;
    if (this.m.processed.has(key)) return false;
    this.m.processed.add(key);
    return true;
  }

  async purgeByDevice(deviceId: string): Promise<void> {
    const dev = this.m.devices.get(deviceId);
    if (dev?.userId) {
      const uid = dev.userId;
      this.m.subs.delete(`user:${uid}`);
      for (const [t, s] of [...this.m.sessions]) if (s.userId === uid) this.m.sessions.delete(t);
      for (const [id, d] of [...this.m.devices]) if (d.userId === uid) this.m.devices.delete(id);
      this.m.users.delete(uid);
    }
    this.m.subs.delete(`device:${deviceId}`);
    this.m.devices.delete(deviceId);
    for (const k of [...this.m.usage.keys()]) if (k.startsWith(`${deviceId}:`)) this.m.usage.delete(k);
    for (const [id, c] of [...this.m.conns]) if (c.deviceId === deviceId) this.m.conns.delete(id);
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Supabase (real Postgres) — same interface, activated when the key is present.

/* eslint-disable @typescript-eslint/no-explicit-any */
class SupabaseAccountsStore implements AccountsStore {
  constructor(private sb: any) {}

  private mapUser = (r: any): AccountUser => ({ id: r.id, email: r.email, appleUserID: r.apple_user_id ?? null, displayName: r.display_name ?? null, createdAt: r.created_at });
  private mapDevice = (r: any): AccountDevice => ({ id: r.id, token: r.token, userId: r.user_id ?? null, createdAt: r.created_at });
  private mapSub = (r: any | null, deviceId: string): Subscription => r ? {
    deviceId, licenseKey: r.license_key ?? null, subscriptionActive: !!r.subscription_active,
    plan: r.plan ?? null, trialStartedAt: r.trial_started_at ? new Date(r.trial_started_at).getTime() : null,
  } : freeSub(deviceId);

  async upsertDevice(id: string, token: string): Promise<AccountDevice> {
    const { data } = await this.sb.from("osmo_devices")
      .upsert({ id, token, last_seen_at: new Date().toISOString() }, { onConflict: "id" })
      .select().single();
    return this.mapDevice(data);
  }
  async deviceById(id: string): Promise<AccountDevice | null> {
    const { data } = await this.sb.from("osmo_devices").select("*").eq("id", id).maybeSingle();
    return data ? this.mapDevice(data) : null;
  }
  async deviceByToken(token: string): Promise<AccountDevice | null> {
    const { data } = await this.sb.from("osmo_devices").select("*").eq("token", token).maybeSingle();
    return data ? this.mapDevice(data) : null;
  }
  async devicesForUser(userId: string): Promise<AccountDevice[]> {
    const { data } = await this.sb.from("osmo_devices").select("*").eq("user_id", userId).order("created_at", { ascending: true });
    return (data ?? []).map(this.mapDevice);
  }
  async linkDeviceToUser(deviceId: string, userId: string): Promise<void> {
    await this.sb.from("osmo_devices").update({ user_id: userId }).eq("id", deviceId);
    // merge a device-owned sub into the user when the user isn't already active
    const { data: devSub } = await this.sb.from("osmo_subscriptions").select("*").eq("owner_type", "device").eq("owner_id", deviceId).maybeSingle();
    if (!devSub) return;
    const { data: userSub } = await this.sb.from("osmo_subscriptions").select("*").eq("owner_type", "user").eq("owner_id", userId).maybeSingle();
    if (userSub?.subscription_active) return;
    await this.sb.from("osmo_subscriptions").upsert({
      owner_type: "user", owner_id: userId,
      license_key: devSub.license_key, subscription_active: devSub.subscription_active,
      plan: devSub.plan, trial_started_at: devSub.trial_started_at, updated_at: new Date().toISOString(),
    }, { onConflict: "owner_type,owner_id" });
    await this.sb.from("osmo_subscriptions").delete().eq("owner_type", "device").eq("owner_id", deviceId);
  }

  async findOrCreateUserByEmail(email: string): Promise<AccountUser> {
    const norm = email.trim().toLowerCase();
    const { data: existing } = await this.sb.from("osmo_users").select("*").eq("email", norm).maybeSingle();
    if (existing) return this.mapUser(existing);
    const { data, error } = await this.sb.from("osmo_users").insert({ email: norm }).select().single();
    if (error) { const { data: again } = await this.sb.from("osmo_users").select("*").eq("email", norm).single(); return this.mapUser(again); }
    return this.mapUser(data);
  }
  async findOrCreateUserByApple(appleUserID: string, email: string | null, name: string | null): Promise<AccountUser | null> {
    const { data: byApple } = await this.sb.from("osmo_users").select("*").eq("apple_user_id", appleUserID).maybeSingle();
    if (byApple) return this.mapUser(byApple);
    const norm = email?.trim().toLowerCase() ?? null;
    if (norm) {
      const { data: byEmail } = await this.sb.from("osmo_users").select("*").eq("email", norm).maybeSingle();
      if (byEmail) {
        const { data } = await this.sb.from("osmo_users").update({ apple_user_id: appleUserID, display_name: byEmail.display_name ?? name }).eq("id", byEmail.id).select().single();
        return this.mapUser(data);
      }
    }
    if (!norm) return null;
    const { data, error } = await this.sb.from("osmo_users").insert({ email: norm, apple_user_id: appleUserID, display_name: name }).select().single();
    if (error) { const { data: again } = await this.sb.from("osmo_users").select("*").eq("apple_user_id", appleUserID).maybeSingle(); return again ? this.mapUser(again) : null; }
    return this.mapUser(data);
  }
  async userById(id: string): Promise<AccountUser | null> {
    const { data } = await this.sb.from("osmo_users").select("*").eq("id", id).maybeSingle();
    return data ? this.mapUser(data) : null;
  }

  private async ownerFor(deviceId: string): Promise<{ type: "user" | "device"; id: string }> {
    const dev = await this.deviceById(deviceId);
    return dev?.userId ? { type: "user", id: dev.userId } : { type: "device", id: deviceId };
  }
  async subscriptionForDevice(deviceId: string): Promise<Subscription> {
    const owner = await this.ownerFor(deviceId);
    const { data } = await this.sb.from("osmo_subscriptions").select("*").eq("owner_type", owner.type).eq("owner_id", owner.id).maybeSingle();
    return this.mapSub(data, deviceId);
  }
  async setSubscriptionForDevice(deviceId: string, patch: Partial<Omit<Subscription, "deviceId">>): Promise<Subscription> {
    const owner = await this.ownerFor(deviceId);
    const { data: cur } = await this.sb.from("osmo_subscriptions").select("*").eq("owner_type", owner.type).eq("owner_id", owner.id).maybeSingle();
    const row: any = {
      owner_type: owner.type, owner_id: owner.id,
      license_key: patch.licenseKey !== undefined ? patch.licenseKey : (cur?.license_key ?? null),
      subscription_active: patch.subscriptionActive !== undefined ? patch.subscriptionActive : (cur?.subscription_active ?? false),
      plan: patch.plan !== undefined ? patch.plan : (cur?.plan ?? null),
      trial_started_at: patch.trialStartedAt !== undefined
        ? (patch.trialStartedAt == null ? null : new Date(patch.trialStartedAt).toISOString())
        : (cur?.trial_started_at ?? null),
      updated_at: new Date().toISOString(),
    };
    const { data } = await this.sb.from("osmo_subscriptions").upsert(row, { onConflict: "owner_type,owner_id" }).select().single();
    return this.mapSub(data, deviceId);
  }
  async startTrialForDevice(deviceId: string, nowMs: number): Promise<Subscription> {
    const cur = await this.subscriptionForDevice(deviceId);
    if (cur.trialStartedAt != null) return cur;
    return this.setSubscriptionForDevice(deviceId, { trialStartedAt: nowMs });
  }
  async subscriptionForUser(userId: string): Promise<Subscription> {
    const { data } = await this.sb.from("osmo_subscriptions").select("*").eq("owner_type", "user").eq("owner_id", userId).maybeSingle();
    return this.mapSub(data, "");
  }
  async setSubscriptionForUser(userId: string, patch: Partial<Omit<Subscription, "deviceId">>): Promise<Subscription> {
    const { data: cur } = await this.sb.from("osmo_subscriptions").select("*").eq("owner_type", "user").eq("owner_id", userId).maybeSingle();
    const row: any = {
      owner_type: "user", owner_id: userId,
      license_key: patch.licenseKey !== undefined ? patch.licenseKey : (cur?.license_key ?? null),
      subscription_active: patch.subscriptionActive !== undefined ? patch.subscriptionActive : (cur?.subscription_active ?? false),
      plan: patch.plan !== undefined ? patch.plan : (cur?.plan ?? null),
      trial_started_at: patch.trialStartedAt !== undefined
        ? (patch.trialStartedAt == null ? null : new Date(patch.trialStartedAt).toISOString())
        : (cur?.trial_started_at ?? null),
      updated_at: new Date().toISOString(),
    };
    const { data } = await this.sb.from("osmo_subscriptions").upsert(row, { onConflict: "owner_type,owner_id" }).select().single();
    return this.mapSub(data, "");
  }

  async createMagicLink(email: string, nowMs: number): Promise<MagicLinkRow> {
    const token = crypto.randomBytes(24).toString("base64url");
    const expiresAt = nowMs + TRIAL_MS;
    await this.sb.from("osmo_magic_links").insert({ token, email: email.trim().toLowerCase(), expires_at: new Date(expiresAt).toISOString(), used: false });
    return { token, email: email.trim().toLowerCase(), expiresAt, used: false };
  }
  async consumeMagicLink(token: string, nowMs: number): Promise<string | null> {
    const { data } = await this.sb.from("osmo_magic_links").select("*").eq("token", token).maybeSingle();
    if (!data || data.used || new Date(data.expires_at).getTime() < nowMs) return null;
    await this.sb.from("osmo_magic_links").update({ used: true }).eq("token", token);
    return data.email;
  }
  async createWebSession(userId: string): Promise<WebSessionRow> {
    const token = crypto.randomBytes(24).toString("base64url");
    await this.sb.from("osmo_web_sessions").insert({ token, user_id: userId });
    return { token, userId, createdAt: Date.now() };
  }
  async webSessionUser(token: string): Promise<AccountUser | null> {
    const { data } = await this.sb.from("osmo_web_sessions").select("user_id").eq("token", token).maybeSingle();
    return data ? this.userById(data.user_id) : null;
  }
  async deleteWebSession(token: string): Promise<void> {
    await this.sb.from("osmo_web_sessions").delete().eq("token", token);
  }

  // osmo_usage is ONE row per device (PK device_id): week_start + count, reset
  // when the week rolls over.
  async usageCount(deviceId: string, weekStart: number): Promise<number> {
    const { data } = await this.sb.from("osmo_usage").select("week_start,count")
      .eq("device_id", deviceId).maybeSingle();
    if (!data || Number(data.week_start) !== weekStart) return 0; // new week / device → 0
    return data.count ?? 0;
  }
  async bumpUsage(deviceId: string, weekStart: number): Promise<number> {
    // Atomic, race-safe reserve via the osmo_bump_usage RPC (single row-locked
    // statement — no read-modify-write lost-update, holds across instances).
    const { data } = await this.sb.rpc("osmo_bump_usage", { p_device_id: deviceId, p_week_start: weekStart });
    return (data as number) ?? 0;
  }
  async refundUsage(deviceId: string, weekStart: number): Promise<number> {
    const { data } = await this.sb.rpc("osmo_refund_usage", { p_device_id: deviceId, p_week_start: weekStart });
    return (data as number) ?? 0;
  }
  async oauthTokens(deviceId: string, platform: string): Promise<Record<string, unknown> | null> {
    const { data } = await this.sb.from("osmo_oauth_tokens").select("tokens")
      .eq("device_id", deviceId).eq("platform", platform).maybeSingle();
    return (data?.tokens as Record<string, unknown>) ?? null;
  }
  async setOAuthTokens(deviceId: string, platform: string, tokens: Record<string, unknown>): Promise<void> {
    await this.sb.from("osmo_oauth_tokens").upsert(
      { device_id: deviceId, platform, tokens, updated_at: new Date().toISOString() },
      { onConflict: "device_id,platform" },
    );
  }
  async upsertConnection(c: Connection): Promise<void> {
    await this.sb.from("osmo_connections").upsert({
      id: c.id, device_id: c.deviceId, platform: c.platform, status: c.status,
      display_name: c.displayName, backfill_progress: c.backfillProgress,
      created_at: c.createdAt, updated_at: new Date().toISOString(),
    }, { onConflict: "id" });
  }
  async connectionsForDevice(deviceId: string): Promise<Connection[]> {
    const { data } = await this.sb.from("osmo_connections").select("*").eq("device_id", deviceId);
    return (data ?? []).map((r: any): Connection => ({
      id: r.id, deviceId: r.device_id, platform: r.platform, status: r.status,
      displayName: r.display_name ?? "", backfillProgress: r.backfill_progress ?? 0, createdAt: r.created_at,
    }));
  }
  async deleteConnection(id: string): Promise<void> {
    await this.sb.from("osmo_connections").delete().eq("id", id);
  }
  async markEventProcessed(eventId: string, source: string): Promise<boolean> {
    // INSERT ... ON CONFLICT DO NOTHING; a returned row means it was newly
    // inserted (first delivery), empty means a duplicate.
    const { data } = await this.sb.from("osmo_processed_events")
      .upsert({ event_id: eventId, source }, { onConflict: "event_id", ignoreDuplicates: true })
      .select("event_id");
    return (data?.length ?? 0) > 0;
  }

  async purgeByDevice(deviceId: string): Promise<void> {
    const dev = await this.deviceById(deviceId);
    if (dev?.userId) {
      // cascades: web_sessions (fk cascade) + devices.user_id set null; drop user's sub explicitly
      await this.sb.from("osmo_subscriptions").delete().eq("owner_type", "user").eq("owner_id", dev.userId);
      await this.sb.from("osmo_devices").delete().eq("user_id", dev.userId);
      await this.sb.from("osmo_users").delete().eq("id", dev.userId);
    }
    await this.sb.from("osmo_subscriptions").delete().eq("owner_type", "device").eq("owner_id", deviceId);
    await this.sb.from("osmo_devices").delete().eq("id", deviceId);
    await this.sb.from("osmo_usage").delete().eq("device_id", deviceId);
    await this.sb.from("osmo_connections").delete().eq("device_id", deviceId);
  }
}
/* eslint-enable @typescript-eslint/no-explicit-any */

// ───────────────────────────────────────────────────────────────────────────
// Selector — one instance per process; Supabase when keyed, else in-memory.

const g = globalThis as unknown as { __osmoAccounts?: AccountsStore; __osmoAccountsMem?: Mem };

/** True when the real cloud DB is wired (both env vars present). */
export function accountsAreLive(): boolean {
  return !!(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);
}

export function getAccounts(): AccountsStore {
  if (g.__osmoAccounts) return g.__osmoAccounts;
  if (accountsAreLive()) {
    // Lazy require so the dependency isn't needed in the in-memory/test path.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { createClient } = require("@supabase/supabase-js");
    const sb = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    g.__osmoAccounts = new SupabaseAccountsStore(sb);
  } else {
    g.__osmoAccountsMem ??= freshMem();
    g.__osmoAccounts = new MemoryAccountsStore(g.__osmoAccountsMem);
  }
  return g.__osmoAccounts;
}

/** Test-only: wipe the in-memory accounts store. */
export function resetAccountsForTests(): void {
  g.__osmoAccountsMem = freshMem();
  g.__osmoAccounts = new MemoryAccountsStore(g.__osmoAccountsMem);
}
