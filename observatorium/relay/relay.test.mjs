// @trace order:1757-n45b
// node --test observatorium/relay/relay.test.mjs
//
// The relay's contract, over a fake Durable Object namespace whose instances
// are the REAL RelayState class with an in-memory storage. The poll grammar is
// the one cloudflare_login.rs::poll_relay speaks: 200 {state, code|error}
// ends it, 404 means "not yet".
import test from "node:test";
import assert from "node:assert/strict";
import { makeHandler, RelayState, CALLBACK_PATH, POLL_PATH, TTL_MS } from "./relay.js";

const PAGE = "<!doctype html><title>relay page</title>";
const BASE = "https://observatorium.tillandsias.org";

function fakeEnv(clock) {
  const instances = new Map();
  return {
    instances,
    RELAY: {
      idFromName: (n) => n,
      get(id) {
        if (!instances.has(id)) {
          const mem = new Map();
          const storage = {
            get: async (k) => mem.get(k),
            put: async (k, v) => void mem.set(k, structuredClone(v)),
            delete: async (k) => void mem.delete(k),
            setAlarm: async () => {},
            mem,
          };
          instances.set(id, new RelayState({ storage }, {}, () => clock.now));
        }
        const obj = instances.get(id);
        return { fetch: (u, init) => obj.fetch(new Request(u, init)) };
      },
    },
  };
}

function setup() {
  const clock = { now: 1_000_000 };
  const env = fakeEnv(clock);
  const h = makeHandler(PAGE);
  const get = (path) => h.fetch(new Request(BASE + path), env);
  return { clock, env, get };
}

test("callback stores the code and serves the relay page, no-store", async () => {
  const { get } = setup();
  const r = await get(`${CALLBACK_PATH}?code=abc.DEF-1&state=s1`);
  assert.equal(r.status, 200);
  assert.equal(await r.text(), PAGE);
  assert.match(r.headers.get("content-type"), /^text\/html/);
  assert.equal(r.headers.get("cache-control"), "no-store");
});

test("poll hands the code back ONCE, then 404", async () => {
  const { get } = setup();
  await get(`${CALLBACK_PATH}?code=abc&state=s1`);
  const first = await get(`${POLL_PATH}?state=s1`);
  assert.equal(first.status, 200);
  assert.deepEqual(await first.json(), { state: "s1", code: "abc" });
  const second = await get(`${POLL_PATH}?state=s1`);
  assert.equal(second.status, 404);
});

test("poll before any callback is 404 (not yet)", async () => {
  const { get } = setup();
  assert.equal((await get(`${POLL_PATH}?state=nobody`)).status, 404);
});

test("a denied consent round-trips as {state, error}", async () => {
  const { get } = setup();
  await get(`${CALLBACK_PATH}?error=access_denied&state=s2`);
  const r = await get(`${POLL_PATH}?state=s2`);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { state: "s2", error: "access_denied" });
});

test("an entry older than the TTL is 404 and is deleted", async () => {
  const { clock, env, get } = setup();
  await get(`${CALLBACK_PATH}?code=abc&state=s3`);
  clock.now += TTL_MS;
  assert.equal((await get(`${POLL_PATH}?state=s3`)).status, 404);
  assert.equal(env.instances.get("s3").storage.mem.size, 0);
});

test("a state or code outside the page's grammar stores nothing", async () => {
  const { env, get } = setup();
  for (const q of ["code=a%20b&state=s4", "code=abc&state=s%3C4", "code=abc", "state=s4"]) {
    const r = await get(`${CALLBACK_PATH}?${q}`);
    assert.equal(r.status, 200, "the page is still served, and says the sign-in was unusable");
  }
  for (const [, obj] of env.instances) assert.equal(obj.storage.mem.size, 0);
  assert.equal((await get(`${POLL_PATH}?state=s4`)).status, 404);
});

test("NEGATIVE CONTROL: a poll for another state never sees this state's code", async () => {
  const { get } = setup();
  await get(`${CALLBACK_PATH}?code=secret&state=mine`);
  const other = await get(`${POLL_PATH}?state=theirs`);
  assert.equal(other.status, 404);
  const mine = await get(`${POLL_PATH}?state=mine`);
  assert.deepEqual(await mine.json(), { state: "mine", code: "secret" });
});

test("only GET is served, and only the two relay paths", async () => {
  const { env } = setup();
  const h = makeHandler(PAGE);
  const post = await h.fetch(new Request(BASE + POLL_PATH + "?state=x", { method: "POST" }), env);
  assert.equal(post.status, 405);
  const other = await h.fetch(new Request(BASE + "/tillandsias/cloudflare/other"), env);
  assert.equal(other.status, 404);
});
