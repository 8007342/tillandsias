// @trace order:1825-v37w, spec:fleet-coordinator
//
// The one SQLite-backed Durable Object class. Each namespace is its own
// instance (name "ns:<namespace>"). The per-identity rate limiter is the same
// class under a different name ("rl:<identity>"), so the Worker still has one
// binding and one migration.
//
// Store and return only. No folding, no model, no outbound fetch. Storage is
// bounded by caps on insert and by an alarm that wakes only at the next
// expiry. There is no fixed tick, so an idle namespace costs nothing.

import { DurableObject } from "cloudflare:workers";

export const MSG_TTL_DEFAULT_S = 6 * 3600;
export const MSG_TTL_MAX_S = 24 * 3600;
export const CLAIM_TTL_DEFAULT_S = 600;
export const CLAIM_TTL_MAX_S = 900;
export const MSG_BODY_MAX = 8 * 1024;
export const OVERVIEW_MAX = 256 * 1024;
export const MSGS_KEPT_MAX = 1000;
export const CLAIMS_KEPT_MAX = 500;
export const RECV_LIMIT_MAX = 100;

export interface Op {
  op: string;
  ns: string;
  [k: string]: unknown;
}

export interface OpResult {
  ok: boolean;
  status: number;
  error?: string;
  [k: string]: unknown;
}

export interface Freshness {
  synced_sha: string | null;
  synced_at: number | null;
  age_s: number | null;
  staleness: number;
  might_be_outdated: boolean;
}

interface CoordEnv {
  STALE_AFTER_S?: string;
}

const fail = (status: number, error: string, extra: Record<string, unknown> = {}): OpResult => ({
  ok: false,
  status,
  error,
  ...extra,
});
const done = (body: Record<string, unknown>): OpResult => ({ ok: true, status: 200, ...body });

function clampTtl(v: unknown, dflt: number, max: number): number {
  const n = typeof v === "number" && Number.isFinite(v) ? Math.floor(v) : dflt;
  return Math.min(Math.max(n, 1), max);
}

function str(v: unknown, max: number): string | null {
  return typeof v === "string" && v.length > 0 && v.length <= max ? v : null;
}

export class Coordinator extends DurableObject<CoordEnv> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: CoordEnv) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS overview(
        id INTEGER PRIMARY KEY CHECK (id = 1),
        body TEXT, overview_sha TEXT, synced_sha TEXT, synced_at INTEGER,
        staleness INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS messages(
        seq INTEGER PRIMARY KEY AUTOINCREMENT, sender TEXT NOT NULL, provider TEXT NOT NULL,
        body TEXT NOT NULL, sent_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS messages_exp ON messages(expires_at);
      CREATE TABLE IF NOT EXISTS claims(
        ord TEXT PRIMARY KEY, holder TEXT NOT NULL, token TEXT NOT NULL, until INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS bucket(id INTEGER PRIMARY KEY CHECK (id = 1),
        tokens REAL NOT NULL, at INTEGER NOT NULL);
    `);
  }

  // ── rate limiter role ────────────────────────────────────────────────────

  /** Token bucket: `perMin` capacity, refilled continuously. */
  take(cost: number, perMin: number): { allowed: boolean; retry_after_s: number } {
    const now = Date.now();
    const row = this.sql.exec<{ tokens: number; at: number }>(`SELECT tokens, at FROM bucket WHERE id = 1`).toArray()[0];
    const rate = perMin / 60_000;
    let tokens = row ? Math.min(perMin, row.tokens + (now - row.at) * rate) : perMin;
    const allowed = tokens >= cost;
    if (allowed) tokens -= cost;
    this.sql.exec(
      `INSERT INTO bucket(id, tokens, at) VALUES (1, ?, ?)
       ON CONFLICT(id) DO UPDATE SET tokens = excluded.tokens, at = excluded.at`,
      tokens,
      now,
    );
    const retry_after_s = allowed ? 0 : Math.ceil((cost - tokens) / rate / 1000);
    return { allowed, retry_after_s };
  }

  // ── namespace role ───────────────────────────────────────────────────────

  /** Applies a namespace's ops in order. One DO call per namespace per request. */
  async applyMany(ops: Op[], identity: string): Promise<OpResult[]> {
    const out = ops.map((o) => this.apply(o, identity));
    await this.scheduleSweep();
    return out;
  }

  private joined(): boolean {
    return this.sql.exec(`SELECT 1 FROM meta WHERE k = 'created_at'`).toArray().length > 0;
  }

  private freshness(clientHead?: unknown): Freshness {
    const row = this.sql
      .exec<{ synced_sha: string | null; synced_at: number | null; overview_sha: string | null; staleness: number }>(
        `SELECT synced_sha, synced_at, overview_sha, staleness FROM overview WHERE id = 1`,
      )
      .toArray()[0];
    const staleAfter = Number(this.env.STALE_AFTER_S ?? "900") || 900;
    const synced_sha = row?.synced_sha ?? null;
    const synced_at = row?.synced_at ?? null;
    const age_s = synced_at === null ? null : Math.max(0, Math.floor((Date.now() - synced_at) / 1000));
    const might_be_outdated =
      synced_at === null ||
      (age_s ?? 0) > staleAfter ||
      (row?.overview_sha ?? null) !== synced_sha ||
      (typeof clientHead === "string" && clientHead !== "" && clientHead !== synced_sha);
    return { synced_sha, synced_at, age_s, staleness: row?.staleness ?? 0, might_be_outdated };
  }

  private putOverview(overview: unknown, sha: string): OpResult | null {
    const body = JSON.stringify(overview ?? null);
    if (body.length > OVERVIEW_MAX) return fail(413, "overview-too-large");
    this.sql.exec(
      `INSERT INTO overview(id, body, overview_sha, synced_sha, synced_at, staleness) VALUES (1, ?, ?, ?, ?, 0)
       ON CONFLICT(id) DO UPDATE SET body = excluded.body, overview_sha = excluded.overview_sha,
         synced_sha = excluded.synced_sha, synced_at = excluded.synced_at, staleness = 0`,
      body,
      sha,
      sha,
      Date.now(),
    );
    return null;
  }

  private apply(o: Op, identity: string): OpResult {
    const now = Date.now();
    if (o.op === "join") {
      const created = !this.joined();
      if (created) {
        this.sql.exec(`INSERT INTO meta(k, v) VALUES ('created_at', ?), ('ns', ?)`, String(now), o.ns);
      }
      return done({ created, freshness: this.freshness() });
    }
    if (!this.joined()) return fail(404, "not-joined");

    switch (o.op) {
      case "send": {
        const body = str(o.body, MSG_BODY_MAX);
        const provider = str(o.provider, 64);
        if (body === null) return fail(400, "body must be a non-empty string of at most 8 KiB");
        if (provider === null) return fail(400, "provider must be a non-empty string of at most 64 chars");
        const ttl = clampTtl(o.ttl_s, MSG_TTL_DEFAULT_S, MSG_TTL_MAX_S);
        const expires_at = now + ttl * 1000;
        const seq = this.sql
          .exec<{ seq: number }>(
            `INSERT INTO messages(sender, provider, body, sent_at, expires_at) VALUES (?, ?, ?, ?, ?) RETURNING seq`,
            identity,
            provider,
            body,
            now,
            expires_at,
          )
          .one().seq;
        this.sql.exec(
          `DELETE FROM messages WHERE seq <= (SELECT seq FROM messages ORDER BY seq DESC LIMIT 1 OFFSET ?)`,
          MSGS_KEPT_MAX,
        );
        return done({ seq, expires_at, ttl_s: ttl });
      }
      case "recv": {
        const since = typeof o.since === "number" ? o.since : 0;
        const limit = Math.min(Math.max(typeof o.limit === "number" ? Math.floor(o.limit) : RECV_LIMIT_MAX, 1), RECV_LIMIT_MAX);
        const msgs = this.sql
          .exec(
            `SELECT seq, sender, provider, body, sent_at, expires_at FROM messages
             WHERE seq > ? AND expires_at > ? ORDER BY seq LIMIT ?`,
            since,
            now,
            limit,
          )
          .toArray();
        const next = msgs.length ? (msgs[msgs.length - 1].seq as number) : since;
        return done({ msgs, next, freshness: this.freshness() });
      }
      case "overview.put": {
        const sha = str(o.sha, 64);
        if (sha === null) return fail(400, "sha required");
        const err = this.putOverview(o.overview, sha);
        return err ?? done({ freshness: this.freshness() });
      }
      case "overview.get": {
        const row = this.sql
          .exec<{ body: string | null; overview_sha: string | null }>(`SELECT body, overview_sha FROM overview WHERE id = 1`)
          .toArray()[0];
        return done({
          overview: row?.body ? JSON.parse(row.body) : null,
          overview_sha: row?.overview_sha ?? null,
          freshness: this.freshness(o.client_head),
        });
      }
      case "bump": {
        const head = str(o.head_sha, 64);
        if (head === null) return fail(400, "head_sha required");
        if (o.overview !== undefined) {
          const err = this.putOverview(o.overview, head);
          if (err) return err;
          this.sql.exec(`UPDATE overview SET staleness = staleness + 1 WHERE id = 1`);
        } else {
          this.sql.exec(
            `INSERT INTO overview(id, synced_sha, synced_at, staleness) VALUES (1, ?, ?, 1)
             ON CONFLICT(id) DO UPDATE SET synced_sha = excluded.synced_sha, synced_at = excluded.synced_at,
               staleness = staleness + 1`,
            head,
            now,
          );
        }
        return done({ freshness: this.freshness() });
      }
      case "claim": {
        const ord = str(o.order, 128);
        if (ord === null) return fail(400, "order required");
        const ttl = clampTtl(o.ttl_s, CLAIM_TTL_DEFAULT_S, CLAIM_TTL_MAX_S);
        const held = this.sql
          .exec<{ holder: string; until: number }>(`SELECT holder, until FROM claims WHERE ord = ? AND until > ?`, ord, now)
          .toArray()[0];
        if (held && held.holder !== identity) return fail(409, "held", { holder: held.holder, until: held.until });
        const live = this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM claims WHERE until > ?`, now).one().n;
        if (!held && live >= CLAIMS_KEPT_MAX) return fail(507, "too-many-claims");
        const token = crypto.randomUUID();
        const until = now + ttl * 1000;
        this.sql.exec(
          `INSERT INTO claims(ord, holder, token, until) VALUES (?, ?, ?, ?)
           ON CONFLICT(ord) DO UPDATE SET holder = excluded.holder, token = excluded.token, until = excluded.until`,
          ord,
          identity,
          token,
          until,
        );
        return done({ token, until, ttl_s: ttl });
      }
      case "release": {
        const ord = str(o.order, 128);
        const token = str(o.token, 64);
        if (ord === null || token === null) return fail(400, "order and token required");
        const n = this.sql.exec(`DELETE FROM claims WHERE ord = ? AND token = ?`, ord, token).rowsWritten;
        return done({ released: n > 0 });
      }
      case "claims": {
        const claims = this.sql
          .exec(`SELECT ord AS "order", holder, until FROM claims WHERE until > ? ORDER BY ord`, now)
          .toArray();
        return done({ claims, freshness: this.freshness() });
      }
      default:
        return fail(400, `unknown op ${JSON.stringify(o.op)}`);
    }
  }

  /** Wake at the next expiry, never on a fixed tick. */
  private async scheduleSweep(): Promise<void> {
    const next = this.sql
      .exec<{ t: number | null }>(
        `SELECT min(t) AS t FROM (SELECT min(expires_at) AS t FROM messages UNION ALL SELECT min(until) FROM claims)`,
      )
      .one().t;
    if (next === null) return;
    const current = await this.ctx.storage.getAlarm();
    if (current === null || next < current) await this.ctx.storage.setAlarm(next);
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    this.sql.exec(`DELETE FROM messages WHERE expires_at <= ?`, now);
    this.sql.exec(`DELETE FROM claims WHERE until <= ?`, now);
    await this.scheduleSweep();
  }

  /** Test seam: row counts, so a test can see the sweep actually deleted. */
  counts(): { messages: number; claims: number } {
    return {
      messages: this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM messages`).one().n,
      claims: this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM claims`).one().n,
    };
  }
}
