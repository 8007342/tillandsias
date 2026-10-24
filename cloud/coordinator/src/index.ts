// @trace order:1825-v37w, spec:fleet-coordinator
//
// The Worker: authenticate, rate-limit, then route ops to one Durable Object
// per namespace. The contract is openspec/changes/fleet-coordinator-warm-cache/contract.md.

import { verifyAccess } from "./access";
import type { Coordinator, Op, OpResult } from "./coordinator";

export { Coordinator } from "./coordinator";

export interface Env {
  COORD: DurableObjectNamespace<Coordinator>;
  ACCESS_TEAM_DOMAIN: string;
  ACCESS_AUD: string;
  RATE_LIMIT_PER_MIN?: string;
  STALE_AFTER_S?: string;
}

export const BATCH_MAX = 20;
const BODY_MAX = 512 * 1024;
const NS_RE = /^[a-z0-9][a-z0-9._-]*(\/[a-z0-9][a-z0-9._-]*)?$/;

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

export function validNamespace(ns: unknown): ns is string {
  return typeof ns === "string" && ns.length <= 128 && NS_RE.test(ns);
}

function shapeError(o: unknown): OpResult | null {
  if (!o || typeof o !== "object") return { ok: false, status: 400, error: "op must be an object" };
  const op = o as Op;
  if (typeof op.op !== "string") return { ok: false, status: 400, error: "op required" };
  if (!validNamespace(op.ns)) return { ok: false, status: 400, error: "invalid namespace" };
  return null;
}

async function run(ops: unknown[], env: Env, identity: string): Promise<OpResult[] | Response> {
  const results: (OpResult | null)[] = ops.map(shapeError);
  const byNs = new Map<string, number[]>();
  ops.forEach((o, i) => {
    if (results[i]) return;
    const ns = (o as Op).ns;
    byNs.set(ns, [...(byNs.get(ns) ?? []), i]);
  });

  // One token per Durable Object this request touches. Refuse before any
  // namespace object is called.
  const cost = Math.max(1, byNs.size);
  const perMin = Number(env.RATE_LIMIT_PER_MIN ?? "120") || 120;
  const limit = await env.COORD.getByName(`rl:${identity}`).take(cost, perMin);
  if (!limit.allowed) {
    return json(429, { error: "rate-limited", retry_after_s: limit.retry_after_s }, {
      "retry-after": String(limit.retry_after_s),
    });
  }

  await Promise.all(
    [...byNs.entries()].map(async ([ns, idx]) => {
      const out = await env.COORD.getByName(`ns:${ns}`).applyMany(
        idx.map((i) => ops[i] as Op),
        identity,
      );
      idx.forEach((i, k) => (results[i] = out[k]));
    }),
  );
  return results as OpResult[];
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    // Auth comes before routing, so an unauthenticated caller learns nothing,
    // not even which paths exist.
    const who = await verifyAccess(req, { teamDomain: env.ACCESS_TEAM_DOMAIN, aud: env.ACCESS_AUD });
    if (!who) return json(401, { error: "unauthenticated" });

    const path = new URL(req.url).pathname;
    if (req.method !== "POST" || (path !== "/v1/batch" && path !== "/v1/op")) {
      return json(404, { error: "not-found" });
    }
    const raw = await req.text();
    if (raw.length > BODY_MAX) return json(413, { error: "body-too-large" });
    let body: unknown;
    try {
      body = JSON.parse(raw);
    } catch {
      return json(400, { error: "invalid-json" });
    }

    if (path === "/v1/op") {
      const out = await run([body], env, who.id);
      if (out instanceof Response) return out;
      const [r] = out;
      return json(r.status, r);
    }
    const ops = (body as { ops?: unknown }).ops;
    if (!Array.isArray(ops) || ops.length === 0) return json(400, { error: "ops must be a non-empty array" });
    if (ops.length > BATCH_MAX) return json(400, { error: `at most ${BATCH_MAX} ops per batch` });
    const out = await run(ops, env, who.id);
    if (out instanceof Response) return out;
    return json(200, { results: out });
  },
} satisfies ExportedHandler<Env>;
