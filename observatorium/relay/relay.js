// @trace order:1757-n45b, order:1505-kc5f
//
// The Cloudflare sign-in relay, served by the observatorium Worker at
//   /tillandsias/cloudflare/callback   the OAuth redirect a phone lands on
//   /tillandsias/cloudflare/poll       what the waiting tillandsias polls
// (wrangler.jsonc runs this Worker first ONLY for /tillandsias/cloudflare/*;
// every other path is the observatorium's static site, unchanged).
//
// The login (crates/tillandsias-headless/src/cloudflare_login.rs, poll_relay)
// polls `GET <poll>?state=<state>` every 2 s: 200 with {state, code} or
// {state, error} ends it, 404 means "not yet".
//
// WHAT IT HOLDS AND FOR HOW LONG. One {state, code|error} per state, in a
// Durable Object named by the state (strongly consistent: the phone and the
// host reach different colos, and KV's eventual consistency would make the
// poll lag), for at most TTL_MS, handed back ONCE and then deleted. The code
// is single-use and bound to a PKCE verifier that never leaves the host
// process, so a compromised relay can at most deny a login. It sees no token
// and no verifier. Nothing here logs a query string.
//
// Pure module: no `cloudflare:*` import, so node --test can run it with a
// fake namespace (relay.test.mjs). worker.js binds it to the real page.

export const CALLBACK_PATH = "/tillandsias/cloudflare/callback";
export const POLL_PATH = "/tillandsias/cloudflare/poll";
export const TTL_MS = 600_000;
// The same grammar the static page applies before it shows anything.
const SAFE = /^[A-Za-z0-9._~-]{1,2048}$/;
const SAFE_ERROR = /^[a-z_]{1,64}$/;

const NO_STORE = {
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-robots-tag": "noindex, nofollow",
};

function json(status, body) {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: { ...NO_STORE, "content-type": "application/json" },
  });
}

/** The record a callback carries, or null when it is unusable. */
export function callbackRecord(params) {
  const state = params.get("state");
  if (state === null || !SAFE.test(state)) return null;
  const error = params.get("error");
  if (error !== null) {
    return { state, error: SAFE_ERROR.test(error) ? error : "error" };
  }
  const code = params.get("code");
  if (code === null || !SAFE.test(code)) return null;
  return { state, code };
}

/**
 * The Worker's fetch handler over `page` (the relay HTML) and an env with
 * RELAY, a Durable Object namespace of RelayState.
 */
export function makeHandler(page) {
  return {
    async fetch(request, env) {
      const url = new URL(request.url);
      if (request.method !== "GET") return json(405, { error: "method" });
      if (url.pathname === CALLBACK_PATH) {
        const rec = callbackRecord(url.searchParams);
        if (rec !== null) {
          const stub = env.RELAY.get(env.RELAY.idFromName(rec.state));
          await stub.fetch("https://relay/put", { method: "POST", body: JSON.stringify(rec) });
        }
        // The page is served either way: it shows the paste line as the
        // fallback, or says the sign-in was unusable. It reads its own query.
        return new Response(page, {
          status: 200,
          headers: { ...NO_STORE, "content-type": "text/html; charset=utf-8" },
        });
      }
      if (url.pathname === POLL_PATH) {
        const state = url.searchParams.get("state");
        if (state === null || !SAFE.test(state)) return json(404);
        const stub = env.RELAY.get(env.RELAY.idFromName(state));
        const r = await stub.fetch("https://relay/take", { method: "POST", body: state });
        if (r.status !== 200) return json(404);
        return json(200, await r.json());
      }
      return json(404);
    },
  };
}

/**
 * One instance per state. `put` stores the record with its expiry and an
 * alarm; `take` returns it once (only for the same state) and deletes it.
 */
export class RelayState {
  constructor(state, _env, now = () => Date.now()) {
    this.storage = state.storage;
    this.now = now;
  }

  async fetch(request) {
    const op = new URL(request.url).pathname;
    if (op === "/put") {
      const rec = JSON.parse(await request.text());
      const expires = this.now() + TTL_MS;
      await this.storage.put("rec", { rec, expires });
      if (this.storage.setAlarm) await this.storage.setAlarm(expires);
      return new Response(null, { status: 204 });
    }
    if (op === "/take") {
      const state = await request.text();
      const held = await this.storage.get("rec");
      if (!held) return new Response(null, { status: 404 });
      if (held.expires <= this.now() || held.rec.state !== state) {
        if (held.expires <= this.now()) await this.storage.delete("rec");
        return new Response(null, { status: 404 });
      }
      await this.storage.delete("rec");
      return new Response(JSON.stringify(held.rec), { status: 200 });
    }
    return new Response(null, { status: 404 });
  }

  async alarm() {
    await this.storage.delete("rec");
  }
}
