// Test helpers: a locally generated Access signing key, a stubbed certs
// endpoint, and a caller that goes through the Worker's real fetch handler.

import { env } from "cloudflare:test";
import { vi } from "vitest";
import { clearCertCache } from "../src/access";
import worker, { type Env } from "../src/index";

export const TEAM = "fleet-test.cloudflareaccess.com";
export const AUD = "test-aud";

const b64url = (b: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(b)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

let signer: CryptoKeyPair | null = null;
export let certFetches = 0;
// Durable Object storage outlives a single test, so each test gets its own
// default caller and therefore its own rate-limit bucket.
let defaultWho = "host-a";

export async function setupAccess(): Promise<void> {
  signer ??= (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const pub = (await crypto.subtle.exportKey("jwk", signer.publicKey)) as JsonWebKey;
  clearCertCache();
  certFetches = 0;
  defaultWho = `host-${crypto.randomUUID().slice(0, 8)}`;
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url === `https://${TEAM}/cdn-cgi/access/certs`) {
      certFetches++;
      return new Response(JSON.stringify({ keys: [{ kid: "k1", kty: "RSA", alg: "RS256", n: pub.n, e: pub.e }] }));
    }
    throw new Error(`unexpected outbound fetch: ${url}`);
  });
}

export async function jwt(claims: Record<string, unknown> = {}, kid = "k1"): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const head = enc({ alg: "RS256", kid, typ: "JWT" });
  const body = enc({ iss: `https://${TEAM}`, aud: [AUD], exp: now + 300, iat: now, sub: "host-a", ...claims });
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", signer!.privateKey, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(sig)}`;
}

export async function call(
  path: string,
  body: unknown,
  opts: { token?: string | null; method?: string; who?: string } = {},
): Promise<{ status: number; body: any }> {
  const token = opts.token === undefined ? await jwt({ sub: opts.who ?? defaultWho }) : opts.token;
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (token) headers["Cf-Access-Jwt-Assertion"] = token;
  const method = opts.method ?? "POST";
  const req = new Request(`https://coordinator.test${path}`, {
    method,
    headers,
    body: method === "GET" || method === "HEAD" ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, env as unknown as Env);
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

export const op = (o: Record<string, unknown>, opts?: { who?: string }) => call("/v1/op", o, opts);
export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** A namespace unique to one test, so tests never share a Durable Object. */
let n = 0;
export const freshNs = () => `owner/t-${Date.now().toString(36)}-${n++}`;
