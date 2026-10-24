// @trace order:1825-v37w, spec:fleet-coordinator
//
// The exit criteria of 1825-v37w, one test each, plus the batch and
// freshness rules from the change's contract.md.

import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import wranglerToml from "../wrangler.toml?raw";
import { beforeEach, describe, expect, it } from "vitest";
import type { Coordinator } from "../src/coordinator";
import type { Env } from "../src/index";
import { call, certFetches, freshNs, jwt, op, setupAccess, sleep } from "./helpers";

beforeEach(async () => {
  await setupAccess();
});

describe("Access", () => {
  it("refuses a request with no JWT, before any Durable Object", async () => {
    const r = await call("/v1/op", { op: "join", ns: "owner/a" }, { token: null });
    expect(r.status).toBe(401);
  });

  it("refuses a bad signature, a wrong aud, a wrong issuer, an expired token and an unknown kid", async () => {
    const good = await jwt();
    const [h, p] = good.split(".");
    const forged = `${h}.${p}.${"A".repeat(342)}`;
    const cases = [
      forged,
      await jwt({ aud: ["other-app"] }),
      await jwt({ iss: "https://evil.cloudflareaccess.com" }),
      await jwt({ exp: Math.floor(Date.now() / 1000) - 10 }),
      await jwt({}, "k-unknown"),
      "not-a-jwt",
    ];
    for (const token of cases) {
      const r = await call("/v1/op", { op: "join", ns: "owner/a" }, { token });
      expect(r.status, token.slice(0, 40)).toBe(401);
    }
  });

  it("caches the certs instead of fetching them per request", async () => {
    await op({ op: "join", ns: freshNs() });
    await op({ op: "join", ns: freshNs() });
    expect(certFetches).toBe(1);
  });
});

describe("routes", () => {
  it("serves no list-like path: every one is 404 for an authenticated caller", async () => {
    await op({ op: "join", ns: "owner/listed" });
    for (const [method, path] of [
      ["GET", "/v1/namespaces"],
      ["GET", "/v1/ns"],
      ["GET", "/v1/list"],
      ["POST", "/v1/namespaces"],
      ["GET", "/v1/batch"],
      ["GET", "/"],
      ["GET", "/v1/op"],
    ]) {
      const r = await call(path, {}, { method });
      expect(r.status, `${method} ${path}`).toBe(404);
    }
  });

  it("has no namespace-listing op either", async () => {
    for (const name of ["list", "namespaces", "enumerate"]) {
      const r = await op({ op: name, ns: "global" });
      expect(r.status).not.toBe(200);
    }
  });

  it("refuses invalid namespace names", async () => {
    for (const ns of ["", "UPPER/x", "a/b/c", "../x", "x".repeat(129)]) {
      expect((await op({ op: "join", ns })).status).toBe(400);
    }
  });
});

describe("namespaces", () => {
  it("join creates a missing namespace, and a second join does not", async () => {
    const ns = freshNs();
    const first = await op({ op: "join", ns });
    expect(first.status).toBe(200);
    expect(first.body.created).toBe(true);
    const second = await op({ op: "join", ns });
    expect(second.body.created).toBe(false);
  });

  it("refuses every other op on a namespace nobody joined", async () => {
    const ns = freshNs();
    for (const o of ["send", "recv", "overview.get", "claims"]) {
      const r = await op({ op: o, ns, body: "x", provider: "claude" });
      expect(r.status, o).toBe(404);
      expect(r.body.error).toBe("not-joined");
    }
  });
});

describe("messages", () => {
  it("round-trips a message and stamps the sender from the JWT", async () => {
    const ns = freshNs();
    await op({ op: "join", ns });
    const sent = await op({ op: "send", ns, body: "hello fleet", provider: "claude", sender: "spoofed" }, { who: "host-b" });
    expect(sent.status).toBe(200);
    const got = await op({ op: "recv", ns, since: 0 });
    expect(got.body.msgs).toHaveLength(1);
    expect(got.body.msgs[0]).toMatchObject({ body: "hello fleet", provider: "claude", sender: "host-b" });
    expect(got.body.next).toBe(sent.body.seq);
    expect((await op({ op: "recv", ns, since: got.body.next })).body.msgs).toHaveLength(0);
  });

  it("defaults the TTL to 6 h and clamps a TTL over 24 h", async () => {
    const ns = freshNs();
    await op({ op: "join", ns });
    expect((await op({ op: "send", ns, body: "a", provider: "p" })).body.ttl_s).toBe(6 * 3600);
    expect((await op({ op: "send", ns, body: "b", provider: "p", ttl_s: 7 * 24 * 3600 })).body.ttl_s).toBe(24 * 3600);
  });

  it("never returns a message past its TTL, and the alarm deletes it", async () => {
    const ns = freshNs();
    await op({ op: "join", ns });
    await op({ op: "send", ns, body: "short", provider: "p", ttl_s: 1 });
    await op({ op: "send", ns, body: "long", provider: "p" });
    await sleep(1100);
    const got = await op({ op: "recv", ns });
    expect(got.body.msgs.map((m: any) => m.body)).toEqual(["long"]);

    const stub: DurableObjectStub = (env as unknown as Env).COORD.getByName(`ns:${ns}`);
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const counts: { messages: number } = await runInDurableObject(stub, (o) => (o as Coordinator).counts());
    expect(counts.messages).toBe(1);
  });
});

describe("claim overlay", () => {
  it("hides a row from other claimers, then vanishes after its TTL", async () => {
    const ns = freshNs();
    await op({ op: "join", ns });
    const a = await op({ op: "claim", ns, order: "1825-v37w", ttl_s: 1 }, { who: "host-a" });
    expect(a.status).toBe(200);
    const b = await op({ op: "claim", ns, order: "1825-v37w" }, { who: "host-b" });
    expect(b.status).toBe(409);
    expect(b.body.holder).toBe("host-a");
    expect((await op({ op: "claims", ns })).body.claims.map((c: any) => c.order)).toEqual(["1825-v37w"]);

    await sleep(1100);
    expect((await op({ op: "claims", ns })).body.claims).toEqual([]);
    expect((await op({ op: "claim", ns, order: "1825-v37w" }, { who: "host-b" })).status).toBe(200);
  });

  it("clamps the claim TTL to 15 min and releases only with the token", async () => {
    const ns = freshNs();
    await op({ op: "join", ns });
    const a = await op({ op: "claim", ns, order: "x", ttl_s: 99999 });
    expect(a.body.ttl_s).toBe(900);
    expect((await op({ op: "release", ns, order: "x", token: "wrong" })).body.released).toBe(false);
    expect((await op({ op: "release", ns, order: "x", token: a.body.token })).body.released).toBe(true);
  });
});

describe("overview and freshness", () => {
  it("returns freshness fields on every read", async () => {
    const ns = freshNs();
    const joined = await op({ op: "join", ns });
    for (const r of [
      joined,
      await op({ op: "recv", ns }),
      await op({ op: "claims", ns }),
      await op({ op: "overview.get", ns }),
    ]) {
      expect(Object.keys(r.body.freshness).sort()).toEqual(
        ["age_s", "might_be_outdated", "staleness", "synced_at", "synced_sha"].sort(),
      );
    }
    expect(joined.body.freshness.might_be_outdated).toBe(true);
  });

  it("stores the client-folded overview unchanged, and a bump moves synced_sha", async () => {
    const ns = freshNs();
    await op({ op: "join", ns });
    const overview = { ready: [{ order: "1826-gi8e", title: "client" }], folded_by: "forge" };
    await op({ op: "overview.put", ns, overview, sha: "aaa111" });
    let got = await op({ op: "overview.get", ns, client_head: "aaa111" });
    expect(got.body.overview).toEqual(overview);
    expect(got.body.freshness).toMatchObject({ synced_sha: "aaa111", staleness: 0, might_be_outdated: false });

    await op({ op: "bump", ns, head_sha: "bbb222" });
    got = await op({ op: "overview.get", ns });
    expect(got.body.freshness).toMatchObject({ synced_sha: "bbb222", staleness: 1, might_be_outdated: true });
    expect(got.body.overview_sha).toBe("aaa111");

    got = await op({ op: "overview.get", ns, client_head: "ccc333" });
    expect(got.body.freshness.might_be_outdated).toBe(true);
  });
});

describe("rate limit and batch", () => {
  it("answers 429 past the per-identity budget", async () => {
    const ns = freshNs();
    let last = 200;
    for (let i = 0; i < 40 && last !== 429; i++) {
      last = (await op({ op: "join", ns }, { who: "noisy-host" })).status;
    }
    expect(last).toBe(429);
    // Another identity has its own bucket.
    expect((await op({ op: "join", ns }, { who: "quiet-host" })).status).toBe(200);
  });

  it("runs a batch in op order, with a result per op, as one request", async () => {
    const ns = freshNs();
    const r = await call("/v1/batch", {
      ops: [
        { op: "join", ns },
        { op: "send", ns, body: "b1", provider: "p" },
        { op: "recv", ns },
        { op: "join", ns: "BAD NAME" },
        { op: "join", ns: "global" },
      ],
    });
    expect(r.status).toBe(200);
    expect(r.body.results.map((x: any) => x.status)).toEqual([200, 200, 200, 400, 200]);
    expect(r.body.results[2].msgs.map((m: any) => m.body)).toEqual(["b1"]);
  });

  it("refuses a batch over 20 ops", async () => {
    const ops = Array.from({ length: 21 }, () => ({ op: "join", ns: "global" }));
    expect((await call("/v1/batch", { ops })).status).toBe(400);
  });
});

describe("wrangler.toml", () => {
  it("declares no routes, custom domain or secrets", () => {
    const toml = wranglerToml
      .split("\n")
      .filter((l) => !l.trimStart().startsWith("#"))
      .join("\n");
    for (const forbidden of [/^\s*routes?\s*=/m, /^\s*\[\[?routes?\]?\]/m, /custom_domain/, /^\s*\[secrets/m, /secrets_store/]) {
      expect(toml).not.toMatch(forbidden);
    }
  });
});
