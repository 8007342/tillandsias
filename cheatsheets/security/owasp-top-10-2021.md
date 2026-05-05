---
tags: [security, owasp, web-security, threat-modeling, vulnerabilities]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://owasp.org/Top10/
  - https://owasp.org/www-project-top-ten/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# OWASP Top 10 — 2021 (current edition)

@trace spec:agent-cheatsheets

## Provenance

- OWASP Top 10 official landing: <https://owasp.org/Top10/>
  local: `cheatsheet-sources/owasp.org/Top10/index.html`
- OWASP Top Ten project page: <https://owasp.org/www-project-top-ten/>
  local: `cheatsheet-sources/owasp.org/www-project-top-ten`
- License: CC-BY-SA 4.0 (per OWASP project pages)
- **Last updated:** 2026-04-25 (next OWASP refresh announced for 2025; verify before 2026-Q3)

## Use when

You're writing or reviewing any web-facing software, APIs, or services that touch untrusted input. The Top 10 is a *risk-ranked starting checklist*, not an exhaustive standard — but if you can't articulate how your system addresses each item, you have homework.

## The Top 10 (2021 ranking)

| # | Code | Category | One-line fix |
|---|---|---|---|
| 1 | A01 | Broken Access Control | Enforce authorization checks server-side at every entry point; default-deny |
| 2 | A02 | Cryptographic Failures | Use established libraries (TLS 1.3, Argon2/bcrypt, AEAD); never roll your own crypto |
| 3 | A03 | Injection | Parameterise queries; use safe templating; validate at boundaries |
| 4 | A04 | Insecure Design | Threat-model BEFORE coding; design for least privilege from the start |
| 5 | A05 | Security Misconfiguration | Hardened defaults; disable unused features; minimal images; secret scanners |
| 6 | A06 | Vulnerable & Outdated Components | SBOM + dependency scanning (Dependabot, Renovate, npm audit, cargo audit) |
| 7 | A07 | Identification & Authentication Failures | MFA; rate-limit; session expiry; password policies that match NIST 800-63B |
| 8 | A08 | Software & Data Integrity Failures | Sign artifacts; verify signatures in CI; pin dependencies by hash |
| 9 | A09 | Security Logging & Monitoring Failures | Log auth events, access denials, integrity violations; centralise; alert |
| 10 | A10 | Server-Side Request Forgery (SSRF) | Allowlist outbound URLs; block 169.254/16, 127.0.0.0/8, RFC1918 by default |

## Common patterns

### A03 — Injection (concrete examples by stack)

| Stack | Anti-pattern | Safe |
|---|---|---|
| SQL (any) | `"SELECT * FROM u WHERE id = " + id` | Parameter binding: `WHERE id = ?` with prepared statement |
| OS shell | `Runtime.exec("rm " + filename)` | Pass argv array; never `sh -c` with concatenated input |
| LDAP | string-concat into filter | escape per RFC 4515 (use library) |
| HTML | `innerHTML = userInput` | `textContent = userInput`, or trusted templating with auto-escape |
| Headers | `setHeader("X-Foo", input)` with `\n` in input | reject CR/LF in header values |

### A07 — Authentication that doesn't suck

- Passwords: minimum 8 chars, no max, no complexity rules (per NIST 800-63B)
- Hash with Argon2id (preferred) or bcrypt (cost ≥ 12); NEVER MD5/SHA1/unsalted SHA-256
- Rate-limit by IP + by account: e.g., 5 failures/min/account
- MFA: TOTP (RFC 6238) or WebAuthn — SMS is fallback only
- Session tokens: 128 bits of entropy, expire on absolute (e.g., 24h) and idle (30min) timeouts

### A10 — SSRF default deny

```text
def is_safe_outbound(url):
    parsed = urlparse(url)
    ip = resolve(parsed.hostname)
    if ip in ip_network("127.0.0.0/8"):  return False
    if ip in ip_network("169.254.0.0/16"): return False  # link-local + cloud metadata
    if ip in ip_network("10.0.0.0/8"):    return False
    if ip in ip_network("172.16.0.0/12"): return False
    if ip in ip_network("192.168.0.0/16"): return False
    return True
```

The 169.254/16 check is the classic AWS metadata exfiltration block (EC2 IMDSv1 → IMDSv2 mitigates this server-side).

## Common pitfalls

- **Treating the Top 10 as exhaustive** — it's a starting checklist. The OWASP ASVS (Application Security Verification Standard) is the comprehensive document.
- **Client-side authorization** — JS that hides admin UI from non-admins doesn't enforce anything; the server must check. A01 is the #1 risk for a reason.
- **"We sanitise input"** — sanitising at the wrong layer (input filter vs output encoding vs query binding) creates a false sense of safety. Each context (HTML, SQL, shell) needs its own escape — output-time, not input-time.
- **Crypto from Stack Overflow** — even "small" mistakes (ECB mode, predictable IV, truncated MAC) make a working-looking system catastrophically broken. Use libsodium / OpenSSL EVP API / language-stdlib AEAD.
- **Audit logs that include the secrets** — passwords, tokens, full credit cards in the access log defeats the audit log entirely. Log discriminators (last 4 digits, hash prefix), never values.
- **Outdated SBOM** — `npm audit` was last run 6 months ago. Automate it (CI fails on critical CVE).

## See also

- `privacy/data-minimization.md` — privacy-side counterpart
- `web/http.md` (DRAFT) — security headers (HSTS, CSP, X-Frame-Options)
- `data/postgresql-indexing-basics.md` — column-level encryption for sensitive fields
- OWASP ASVS for the comprehensive checklist (out of scope for this 1-page cheatsheet)
