// @trace order:1825-v37w, spec:fleet-coordinator
//
// Cloudflare Access JWT verification. The only outbound fetch the Worker
// makes is the team domain's public certificate set, cached per isolate.
// Nothing secret is configured: the team domain and AUD tag are plain vars.

export interface AccessConfig {
  teamDomain: string;
  aud: string;
}

export interface Identity {
  id: string;
}

interface Jwk {
  kid: string;
  kty: string;
  n: string;
  e: string;
  alg?: string;
}

const CERT_TTL_MS = 60 * 60 * 1000;
// A token naming an unknown kid triggers at most one refetch per minute, so a
// stream of garbage tokens cannot turn into a stream of cert fetches.
const REFETCH_FLOOR_MS = 60 * 1000;

const certCache = new Map<string, { keys: Map<string, CryptoKey>; at: number }>();

function b64urlBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64urlJson(s: string): Record<string, unknown> | null {
  try {
    const v = JSON.parse(new TextDecoder().decode(b64urlBytes(s)));
    return v && typeof v === "object" ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

async function fetchKeys(teamDomain: string): Promise<Map<string, CryptoKey>> {
  const res = await fetch(`https://${teamDomain}/cdn-cgi/access/certs`);
  if (!res.ok) throw new Error(`certs ${res.status}`);
  const body = (await res.json()) as { keys?: Jwk[] };
  const keys = new Map<string, CryptoKey>();
  for (const k of body.keys ?? []) {
    if (k.kty !== "RSA" || !k.kid) continue;
    const key = await crypto.subtle.importKey(
      "jwk",
      { kty: "RSA", n: k.n, e: k.e, alg: "RS256", ext: true },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    keys.set(k.kid, key);
  }
  return keys;
}

async function keyFor(teamDomain: string, kid: string): Promise<CryptoKey | undefined> {
  const now = Date.now();
  let entry = certCache.get(teamDomain);
  const fresh = entry && now - entry.at < CERT_TTL_MS;
  const mayRefetch = !entry || now - entry.at >= REFETCH_FLOOR_MS;
  if (!fresh || (!entry!.keys.has(kid) && mayRefetch)) {
    try {
      entry = { keys: await fetchKeys(teamDomain), at: now };
      certCache.set(teamDomain, entry);
    } catch {
      // Keep serving the cached set if the refetch failed.
    }
  }
  return entry?.keys.get(kid);
}

/** Test seam: forget cached certificates. Not reachable over HTTP. */
export function clearCertCache(): void {
  certCache.clear();
}

/** Verifies the Access JWT on a request. Returns null on any failure. */
export async function verifyAccess(req: Request, cfg: AccessConfig): Promise<Identity | null> {
  if (!cfg.teamDomain || !cfg.aud) return null;
  const token = req.headers.get("Cf-Access-Jwt-Assertion");
  if (!token) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const header = b64urlJson(parts[0]);
  const claims = b64urlJson(parts[1]);
  if (!header || !claims || header.alg !== "RS256" || typeof header.kid !== "string") return null;

  const key = await keyFor(cfg.teamDomain, header.kid);
  if (!key) return null;
  let valid = false;
  try {
    valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      b64urlBytes(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    );
  } catch {
    return null;
  }
  if (!valid) return null;

  const nowS = Date.now() / 1000;
  if (typeof claims.exp !== "number" || claims.exp <= nowS) return null;
  if (typeof claims.nbf === "number" && claims.nbf > nowS + 60) return null;
  if (claims.iss !== `https://${cfg.teamDomain}`) return null;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(cfg.aud)) return null;

  for (const field of ["email", "common_name", "sub"]) {
    const v = claims[field];
    if (typeof v === "string" && v) return { id: v };
  }
  return null;
}
