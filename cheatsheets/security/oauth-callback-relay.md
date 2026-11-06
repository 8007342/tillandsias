---
tags: [oauth, pkce, relay, callback, security-headers, csp, rate-limiting, turnstile, cloudflare]
languages: [http]
since: 2026-11-06
last_verified: 2026-11-06
sources:
  - https://www.rfc-editor.org/rfc/rfc8252.txt
  - https://www.rfc-editor.org/rfc/rfc9700.txt
  - https://www.rfc-editor.org/rfc/rfc7636.txt
  - https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html
  - https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Headers_Cheat_Sheet.html
  - https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html
  - https://cheatsheetseries.owasp.org/cheatsheets/Error_Handling_Cheat_Sheet.html
  - https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Referrer-Policy
  - https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cache-Control
  - https://developers.cloudflare.com/turnstile/plans/
  - https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
  - https://developers.cloudflare.com/waf/rate-limiting-rules/
  - https://developers.cloudflare.com/bots/get-started/bot-fight-mode/
  - https://developers.cloudflare.com/rules/transform/
  - https://support.google.com/cloud/answer/15549945
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Hardening a public OAuth callback relay for a native or CLI client

@trace spec:agent-cheatsheets, order:2013-rlsc

Use this cheatsheet when a native or CLI app signs in with OAuth through a
public web page that receives the authorization code, and the page has to stay
safe with anyone on the internet able to request it. All sources were read on
2026-11-06.

## Provenance

- IETF:
  - RFC 8252, OAuth for native apps: <https://www.rfc-editor.org/rfc/rfc8252.txt>
  - RFC 9700, the OAuth 2.0 Security BCP: <https://www.rfc-editor.org/rfc/rfc9700.txt>
  - RFC 7636, PKCE: <https://www.rfc-editor.org/rfc/rfc7636.txt>
- OWASP cheat sheets: Clickjacking Defense, HTTP Headers, Logging, Error
  Handling (URLs in the frontmatter).
- MDN: Referrer-Policy, Cache-Control.
- Cloudflare:
  - Turnstile plans and server-side validation;
  - WAF rate limiting rules;
  - Bot Fight Mode;
  - Transform Rules.
- Google Cloud: OAuth publishing status (answer 15549945).

## Rules that are not optional

- **PKCE with S256 for every public client.** RFC 9700 §2.1.1: "Public clients
  MUST use PKCE". A code without its verifier is useless at the token endpoint,
  so code interception (RFC 7636) gives an attacker nothing.
- **Exact redirect URIs, and no forwarding.** RFC 9700 §2.1: servers "MUST
  utilize exact string matching" and "MUST NOT expose URLs that forward the
  user's browser to arbitrary URIs". A callback never takes a `next` or
  `return` parameter.
- **First-party only on the callback page.** RFC 9700 §4.2.4: it "SHOULD NOT
  include third-party resources or links to external sites". That means no
  analytics, no CAPTCHA script and no social sign-in script there.
- **Nothing secret in URLs, logs or Referer.** OWASP Logging lists access
  tokens and session identifiers as things that "should usually not be recorded
  directly in the logs". Store the code first, strip the query, then redirect.
  A poller sends its secret in a POST body, never in a query string.
- **Generic errors.** OWASP Error Handling: return "a generic response". Never
  echo input back.

## Headers for every response

```http
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; form-action 'none'; base-uri 'none'
X-Frame-Options: DENY
Referrer-Policy: no-referrer
Cache-Control: no-store
X-Content-Type-Options: nosniff
Strict-Transport-Security: max-age=31536000
```

`frame-ancestors` only works as a header, not in a `<meta>` CSP. On the
Cloudflare Free plan you can set these in the Worker itself, or with Transform
Rules ("Active Transform Rules | 10").

## Binding the result to the terminal

The terminal generates a secret `s` and sends `state = nonce . H(s)`. The relay
stores the code once, under `H(nonce)`, with a short TTL. It releases the code
only to `POST /poll {nonce, s}` where `H(s)` matches, comparing in constant
time.

- A poller that has only seen the QR code or the URL gets **nothing and
  deletes nothing**.
- Encrypting the code to a terminal public key on top is optional. On its own,
  encryption does not stop a denial attack, where someone reads and deletes the
  result first.

## Cloudflare Free-plan controls

| Control | Free plan | Use for a relay |
|---|---|---|
| WAF rate limiting rule | "1" rule; Path; counted by IP; 10 s period and timeout | one rule on `/poll` |
| Bot Fight Mode | "may challenge API or mobile app traffic"; WAF rules cannot bypass it | keep it **off**: it breaks CLI polling |
| Turnstile | free, "Unlimited challenges"; tokens "valid for 300 seconds", "single-use"; requires server-side Siteverify | only on pages a human uses, never on the callback or the poll |
| Transform Rules | available; 10 active rules | the security headers |

## Google sign-in as a gate

Google sign-in in front of a relay costs a lot for little:

- every user needs a Google account and shares their identity with you;
- brand verification ("typically takes 2-3 business days") on a verified
  domain;
- a 100-user Testing cap unless only basic scopes are requested.

It adds nothing to a result that is already single-use, bound to the terminal
and useless without the PKCE verifier.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

### Source

- **Upstream URL(s):** the RFCs and pages under Provenance.
- **Archive type:** `single-html`
- **Expected size:** `~2 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/oauth-relay/`
- **License:** see-license-allowlist
- **License URL:** https://www.rfc-editor.org/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
BASE="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/oauth-relay"
mkdir -p "$BASE"
for r in 8252 9700 7636; do
  curl -fsSL "https://www.rfc-editor.org/rfc/rfc$r.txt" -o "$BASE/rfc$r.txt"
done
```

### Generation guidelines (after pull)

1. Quote the RFC section you rely on. RFC 9700 supersedes older security advice.
2. Re-read the Cloudflare plan pages before quoting a Free-plan limit; they change.
