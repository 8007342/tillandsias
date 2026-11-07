# Addendum — the public login relay: threat model, controls, and a login that finishes by itself

Status: **proposed, research and design only** (orders 2013-rlsc and
2013-rlcd). Nothing is changed in the relay, deployed, or created on
Cloudflare. Relay deploys go through the coordinator and the operator.

@trace order:2013-rlsc, order:2013-rlcd

Sources were read on 2026-11-06 and are cited inline. The technical controls
are summarised in `cheatsheets/security/oauth-callback-relay.md`.

## 1. What exists today

All of the following is **[code]**, verified in this repository.

**The relay page** is `assets/cloudflare-relay/index.html`.
- It removes the query at once (`history.replaceState`, :87).
- It never calls out: "no fetch, no XHR, no beacon, no form" (:16).
- It shows `code=…&state=…` with `textContent` inside a collapsed "Finish by
  hand" section (:72-73, :105-107).
- Its CSP is set by a meta tag only (:24):
  `default-src 'none'; script-src 'unsafe-inline'; … frame-ancestors 'none'`.
  The page also sets `referrer` to `no-referrer` and `robots` to
  `noindex, nofollow` (:25-26).

**The Copy button does not work reliably.**
- `navigator.clipboard.writeText(line)` is neither awaited nor caught.
- There is no fallback and no feedback (:108-112).
- Where the API is missing, or the write is refused (an insecure context, or a
  denied permission), the click does nothing.

**The relay Worker** lives in the private sibling repo
`8007342/cloudflare.tillandsias.org` and is **not deployed**.
- Its callback stores `code` under `state` in KV with `expirationTtl 120`, then
  303s to `?done=1`.
- Its `/poll?state=` answers 204 until the code is stored, then "deletes and
  answers 200 {state, code} exactly once"
  (`plan/index.d/20261102t003504z-1955-cfhf-*.yaml:27`).
- The client keeps polling gated off: `RELAY_POLL_DEFAULT_ON = false`
  (`cloudflare_login.rs:304`).

**The login** (`cloudflare_login.rs`, `cloudflare_oauth.rs`):
- It tries the **device grant first** (`:982-990`). That is the Cloudflare
  equivalent of `--github-login`, which completes by itself through GitHub's
  device flow (RFC 8628; `main.rs:14714-14718`).
- **[unproven]** "whether Cloudflare grants device_code to THIS client"
  (`1758-wdvf`). If it refuses, the login falls back to the browser.
- `state` and a PKCE S256 verifier are random. `state` is checked in constant
  time. The verifier is never `pub`, never printed, and is sent only to the
  token endpoint.

## 2. Threat model

The relay is a public hostname. Anyone can request any path.

| # | Threat | Today | Control |
|---|---|---|---|
| T1 | **Someone who sees the QR or the URL polls first.** `state` is in the authorize URL, which is on screen, in the browser history and in the QR. With `/poll?state=`, they receive the code and the poll deletes it. | Not deployed; the design is vulnerable | §3: the poll needs a secret only the terminal holds |
| T2 | **A stolen code is exchanged for a token.** | **Already blocked by PKCE.** The token endpoint needs the verifier, which only the terminal has. [doc] RFC 7636 exists for "the authorization code interception attack", and RFC 9700 §2.1.1 says "Public clients MUST use PKCE". | Keep PKCE S256. Never log, echo or store the verifier. |
| T3 | **Denial: an attacker consumes or overwrites a session.** | A first-read delete lets T1 deny the login | §3: a poll without the secret gets nothing and deletes nothing; the result is written once and never overwritten |
| T4 | **The code in URLs, logs, Referer or browser history.** | The page strips the query and sets no-referrer by meta tag | Headers in §4. Workers logs and analytics record URLs ([unproven] whether full query strings are kept), so the Worker must store the code and redirect **before** logging, and never log the query. |
| T5 | **An open redirect or a mix-up.** | No redirect parameter exists | [doc] RFC 9700 §2.1: servers "MUST utilize exact string matching" and "MUST NOT expose URLs that forward the user's browser to arbitrary URIs". No `next` or `return` parameter, ever. Check `iss` if Cloudflare sends it (RFC 9207, [unproven]). |
| T6 | **Clickjacking, injection, or a hostile query.** | A meta CSP with `frame-ancestors 'none'` and `textContent` | The same as **headers** (§4), since a meta CSP cannot set `frame-ancestors`. Never echo input. One generic error page. |
| T7 | **Scraping or flooding the poll endpoint.** | — | One Free WAF rate-limit rule on `/poll` (§4), plus the client's backoff. A wrong secret costs the attacker a request and gives nothing. |
| T8 | **A curious visitor with no session, a malformed callback, or an expired link.** | A "bad" section | A friendly page that reveals nothing and offers a next step ("start the sign-in again from your terminal"). A test covers each bad input. |

## 3. The login that finishes by itself (2013-rlcd)

**First:** measure the device grant (row j of the 2011 work, or a short probe in
rlcd). If Cloudflare grants `device_code` to our client, the login finishes by
itself with no relay, exactly as `--github-login` does, and the relay is only
for clients that cannot use it.

**Otherwise, the relay with a terminal-held secret.** Two schemes were weighed,
as the operator asked:

| | **A. Hashed poll secret** | **B. Asymmetric: the result is encrypted to the terminal's key** |
|---|---|---|
| Terminal generates | 32 random bytes `s` | an X25519 key pair |
| Travels in `state` | `nonce . H(s)` | `nonce . pubkey` |
| Relay stores, for 120 s | `code` under `H(nonce)`, released only to a poll presenting `s` with `H(s)` matching | `seal(pubkey, code)`, the ciphertext only |
| A poller who saw `state` | gets nothing (no `s`), and deletes nothing | gets ciphertext it cannot open; **unless the poll is also gated, it can still delete the result (T3)** |
| What a relay breach exposes | codes for 120 s, which are useless without the PKCE verifier (T2) | ciphertext only |
| Complexity | a hash; no new crypto in the Worker | sealed-box crypto in the Worker and in Rust ([code] X25519 exists only in `tillandsias-secure-channel`) |

**Recommendation: A, plus PKCE, with B only if the operator wants "the relay
never holds even a code" as a stated property.**
- A alone defeats T1 and T3, because a poll without `s` neither reads nor
  deletes.
- PKCE already makes a leaked code worthless for a token (T2).
- B on its own does **not** stop the delete-on-read denial. It would need A's
  gate as well, so B adds crypto for a property PKCE largely provides already.
- If B is wanted, use both: `state = nonce . H(s) . pubkey`, so the store holds
  ciphertext and the poll needs `s`.

**The flow, scheme A:**
1. The terminal makes the verifier, `nonce` and `s`, and sends
   `state = nonce . H(s)` (all base64url, within the provider's `state` length).
2. The callback stores `{code}` under `H(nonce)` with a TTL of 120 s, **write
   once**. It strips the query, then 303s to `?done=1`.
3. The page shows "Signed in — your terminal is finishing" and, after the
   terminal acknowledges, "you can close this page". Because the page never
   calls out, the acknowledgement is reflected by the page polling `/status`
   with only `H(nonce)`, which reveals nothing.
4. The terminal polls `POST /poll {nonce, s}`. The body is not a URL, so it is
   never logged as a query. Backoff runs 1 s → 8 s with jitter, honouring 429
   and Retry-After, within a stated budget of at most 60 requests per login.
   - The relay checks `H(s)` in constant time, releases the code once and
     deletes it.
   - A wrong `s` gives 404, the same answer as no session, so nothing leaks.
5. The terminal checks `state`, then exchanges the code with the verifier.
6. **Fallback:** the manual code, shown only when the terminal cannot reach the
   relay, with a **Copy button that works**:
   - await `clipboard.writeText`;
   - on failure, select the text in a read-only field and say "press Ctrl+C";
   - show "Copied" or the failure.

**Single-use, short-lived, nothing usable at rest:** the stored code is useless
without the verifier, expires in 120 s, is written once, and is deleted on
release. With B, it is also ciphertext.

## 4. Free-plan controls for the relay (2013-rlsc)

| Control | Setting | Source |
|---|---|---|
| Security headers on every response (Worker or Transform Rules: Free has "Active Transform Rules \| 10") | `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; form-action 'none'; base-uri 'none'`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Strict-Transport-Security: max-age=31536000` | OWASP HTTP Headers and Clickjacking cheat sheets; MDN; RFC 9700 §4.2.4 |
| A first-party-only callback page | no third-party resources or links, so **no Turnstile and no Google script on `/callback`** | RFC 9700 §4.2.4: it "SHOULD NOT include third-party resources or links to external sites" |
| Rate limiting | the single Free WAF rule on path `/poll`, counted by IP, 10 s period, 10 s mitigation | [doc] Free: "1" rule, Path, IP, 10 s |
| Bot Fight Mode | **off**: it "may challenge API or mobile app traffic" and "cannot be bypassed" by WAF rules, so it would break the CLI's poll | Cloudflare bots docs |
| Turnstile | **not used on the login path.** It is optional, Managed mode with Siteverify, only on a page a human uses, and never on `/poll` | [doc] free, "Unlimited challenges"; tokens "valid for 300 seconds", "single-use" |
| Errors | one generic page, no input echoed, nothing in logs beyond a fixed reason word | OWASP Error Handling and Logging |
| Redirects | exact redirect URIs registered, no redirect parameters | RFC 9700 §2.1 |

**Google sign-in in front of the relay, the operator's idea: not recommended.**
[code] No Google OAuth app exists for tillandsias.org; the only one is for
another project.
- **It adds no cryptographic protection:** the result is already single-use,
  bound to the terminal's secret and useless without the PKCE verifier.
- **It requires every user,** including those with nothing to do with our
  infrastructure, to have a Google account and to share their identity with us.
- **It adds a sign-in before Cloudflare's,** and Google's scripts on a page
  RFC 9700 asks to keep first-party.
- **It brings upkeep:** brand verification ("typically takes 2-3 business
  days"; "the homepage must be hosted on a verified domain you own"), and a
  100-user cap unless only basic scopes are used.

**What does protect the relay:** the hashed poll secret (§3), the headers, one
rate-limit rule, and generic errors. Together they mean a wanderer sees a
friendly page, an attacker gets nothing, and a breach yields only codes that
need a verifier.

## 5. Implementation rows (small)

| # | Row | Repo | Needs |
|---|---|---|---|
| a | Measure Cloudflare's device grant for our client; record the result | this repo | one real login, operator present |
| b | Terminal side of scheme A: generate `s`; `state = nonce . H(s)`; `POST /poll` with backoff and budget; check state; tests against a fake relay | this repo | local |
| c | Relay side of scheme A: write-once store, `H(s)` check, 404 for wrong and missing alike, `/status` for the page; a fixture of hostile requests | sibling relay repo | local `wrangler dev` |
| d | Relay page: a working Copy button (await, select fallback, feedback), the "close this page" step, friendly bad-input pages; a test per bad input | both | local |
| e | Headers on every response, and the one WAF rule, as a deploy checklist | sibling repo | **operator deploy** |
| f | Optional scheme B (sealed box) on top of A, if the operator asks for ciphertext at rest | both | local |

## 6. Questions for the operator

1. Is scheme A plus PKCE enough, or should the relay hold only ciphertext
   (A + B)?
2. Should Google sign-in be dropped from consideration, as recommended?
3. Is the Free WAF rule (one rule) acceptable for `/poll`, with Bot Fight Mode
   off?

**Not settled on an official page:**
- whether the Workers Rate Limiting binding is available on Free;
- whether Cloudflare returns `iss`;
- whether Workers logs keep full query strings;
- whether Cloudflare grants a device code to our client.
