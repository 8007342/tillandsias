# OpenCode CSP Hash Injection — Cheatsheet

@trace spec:opencode-web-session

## Problem

`opencode serve` emits an inline `<script id="oc-theme-preload-script">` in its index.html AND ships a strict `Content-Security-Policy` header:

```
default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; ...
```

The CSP has no `'unsafe-inline'`, no hash, no nonce → browsers block the inline script → theme never applies → console shows:

> Executing inline script violates the following Content Security Policy directive 'script-src 'self' 'wasm-unsafe-eval''. Either the 'unsafe-inline' keyword, a hash ('sha256-QI23YWMJrD/tljM6/82tpL8EwqdBoptwZfycFHA9IiQ='), or a nonce ('nonce-...') is required to enable inline execution.

## Upstream status

- [anomalyco/opencode#21088](https://github.com/anomalyco/opencode/issues/21088) — OPEN. Embedded web UI CSP blocks inline theme preload.
- [anomalyco/opencode#21089](https://github.com/anomalyco/opencode/pull/21089) — CLOSED (bot auto-close on template non-compliance). The fix itself was correct: mirror the proxied path's `csp(sha256(scriptBody))` helper on the embedded branch.

Source of truth: `packages/opencode/src/server/routes/ui.ts` — embedded branch returns `DEFAULT_CSP` unchanged; proxied branch (app.opencode.ai) already computes the hash correctly.

## Canonical fix (per CSP3 spec + OWASP)

1. **Move inline scripts to external files** — best. Then `script-src 'self'` covers them with no hashes needed.
2. **Hash the inline script** — `script-src 'self' 'sha256-<b64>'`. Fine for static inline content. Must re-hash on every edit.
3. **Nonce per request** — `script-src 'self' 'nonce-<random>'`. Required only for server-generated inline content.
4. ~~`'unsafe-inline'`~~ — never. Defeats the whole point of CSP.

Until upstream ships (1) or (2) on the embedded branch, we mirror their own proxied-branch approach via our `sse-keepalive-proxy.js`.

## Our workaround — dynamic hash in the proxy

`images/default/sse-keepalive-proxy.js` intercepts every HTML response on its way from opencode to the webview:

```
webview → proxy (127.0.0.1:4096) → opencode (127.0.0.1:4097)
                ↑
       [HTML response]
       1. Buffer body.
       2. Scan for <script> tags without src=.
       3. sha256 + base64 each body.
       4. Append `'sha256-<b64>'` entries to the CSP's
          script-src directive.
       5. Forward with patched CSP.
```

Key properties:

- **No hardcoded hash** — proxy computes dynamically on every request. Opencode version bumps that change the theme script are handled transparently.
- **No `'unsafe-inline'`** — we keep the strongest possible CSP posture.
- **Scoped** — only inline scripts in the response get their hashes added; external scripts (`<script src="…">`) are already allowed by `'self'`.

## How to verify

```bash
# From the host, curl the forge (through the proxy — host_port is the proxy)
curl -s -i http://127.0.0.1:$(podman port tillandsias-<proj>-forge | awk -F: '{print $NF}')/ \
    | grep -i content-security-policy
```

Expected: `script-src 'self' 'wasm-unsafe-eval' 'sha256-<b64>'` (with at least one sha256 entry). In Chrome devtools → Console, no red CSP violation lines during initial paint.

## When to revisit

Delete this workaround and the proxy code block once one of:

- OpenCode merges a PR that hashes the inline script on the embedded branch (check issue #21088).
- OpenCode moves the theme preload to an external file (`/theme-preload.js`).
- OpenCode exposes a `server.csp` config key (none exists today — verified against the live schema 2026-04-24).

Drop-in deletion path: remove `injectCspHashesInHtml()` and the `isHtml` branch in the proxy's response handler. Leave the SSE-keepalive logic — that's orthogonal.

## References

- [OpenCode issue #21088](https://github.com/anomalyco/opencode/issues/21088) — root cause + repro
- [OpenCode PR #21089](https://github.com/anomalyco/opencode/pull/21089) — pending fix
- [CSP Level 3 spec](https://www.w3.org/TR/CSP3/#security-inline) — why `'unsafe-inline'` is the worst option
- [OWASP CSP cheatsheet](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html) — external-file-first guidance

Related cheatsheets: `opencode-proxy-egress.md`, `opencode-web.md`.
