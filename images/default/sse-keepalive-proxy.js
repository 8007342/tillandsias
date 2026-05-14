#!/usr/bin/env node
// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
//
// SSE keepalive proxy. Fronts opencode serve so Bun's default 10s idleTimeout
// doesn't drop `/event` and `/global/event` streams when the session is idle.
// Every KEEPALIVE_MS of wall-clock time the proxy injects a `:\n\n` SSE
// comment into the response stream — bytes flow through the socket,
// idleTimeout never trips, the client stays connected.
//
// Config (env): LISTEN_HOST, LISTEN_PORT, UPSTREAM, KEEPALIVE_MS.

const http = require('node:http');
const crypto = require('node:crypto');

const LISTEN_HOST = process.env.LISTEN_HOST || '0.0.0.0';
const LISTEN_PORT = Number(process.env.LISTEN_PORT || 4096);
const [UP_HOST, UP_PORT_STR] = (process.env.UPSTREAM || '127.0.0.1:4097').split(':');
const UP_PORT = Number(UP_PORT_STR);
const KEEPALIVE_MS = Number(process.env.KEEPALIVE_MS || 5000);

const SSE_PATHS = new Set(['/event', '/global/event']);

// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
// Paths that get a hard 404 at the proxy to disable PWA "Install as app"
// and service-worker registration. Upstream opencode ships a web manifest
// and an installable icon set; the ephemeral contract forbids installed
// PWAs (they'd retain IndexedDB / SW / cache state across container
// lifetimes). 404ing the paths is stricter than rewriting the manifest's
// `display: browser` — no caching layer can undo it.
const PWA_KILL_PATHS = new Set([
    '/site.webmanifest',
    '/manifest.json',
    '/manifest.webmanifest',
    '/sw.js',
    '/service-worker.js',
    '/worker.js',
]);

// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
// Bootstrap script injected as the first child of <head> on every HTML
// response. Seeds `localStorage.opencode-color-scheme = 'dark'` before
// opencode's `/oc-theme-preload.js` external script reads localStorage,
// so the dark palette paints on first frame with no light flash.
//
// Constraints per browser-isolation-tray-integration + opencode-web-session-otp:
//   - Classic script only (no type=module, defer, async) — must run
//     synchronously before any other script on the page.
//   - Side-effect-only. Do NOT override Notification.permission or
//     requestPermission: the spec mandates a user gesture for permission
//     grants; any monkey-patching pollutes the console and hides bugs.
//   - UTF-8 body bytes are hashed exactly; whitespace matters for the
//     sha256 computation that feeds the CSP.
const BOOTSTRAP_SCRIPT = ";(function(){try{if(!localStorage.getItem('opencode-color-scheme')){localStorage.setItem('opencode-color-scheme','dark');}}catch(_){}})();";

// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
// CSP-hash injector for opencode's index.html. Upstream opencode ships a
// strict Content-Security-Policy of `script-src 'self' 'wasm-unsafe-eval'`
// but also emits an inline <script id="oc-theme-preload-script"> in the
// HTML body. Chrome / WebKit block the inline script — theme never applies,
// UI may mis-render. This is tracked upstream at anomalyco/opencode#21088
// (PR #21089 pending). The proxied path at app.opencode.ai already fixes
// this by computing the sha256 of the inline script and adding it to CSP;
// the embedded-serve path used by Tillandsias returns DEFAULT_CSP unchanged.
//
// We rewrite the CSP exactly the way opencode itself does on the proxied
// path: scan the HTML response for inline <script> tags, compute each
// script body's sha256, and append `'sha256-<b64>'` entries to the
// `script-src` directive. No content rewriting, no `'unsafe-inline'`
// relaxation — just the specific hashes needed.
function injectCspHashesInHtml(htmlBuffer, cspHeader, extraHashes) {
    const html = htmlBuffer.toString('utf8');
    // Collect the body of every inline <script>…</script> (tags without a
    // `src=` attribute) that opencode ships. Upstream sometimes ships the
    // theme preload inline, sometimes as an external src — we cover both
    // cases uniformly.
    const scriptRe = /<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/g;
    const hashes = new Set(extraHashes || []);
    let match;
    while ((match = scriptRe.exec(html)) !== null) {
        const body = match[2];
        if (!body || !body.trim()) continue;
        const digest = crypto.createHash('sha256').update(body, 'utf8').digest('base64');
        hashes.add(`'sha256-${digest}'`);
    }
    if (hashes.size === 0) return cspHeader;
    const hashList = Array.from(hashes).join(' ');
    if (/\bscript-src\b/.test(cspHeader)) {
        return cspHeader.replace(/(\bscript-src\b)([^;]*)/, (_, key, rest) => {
            return `${key}${rest.trimEnd()} ${hashList}`;
        });
    }
    return `${cspHeader.replace(/;?\s*$/, '')}; script-src 'self' ${hashList}`;
}

// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
// Rewrite an HTML body: strip <link rel="manifest">, then inject the
// bootstrap <script> as the first child of <head>. Returns the new body
// as a Buffer. We do this in two regexes instead of parsing HTML; the
// input is opencode's deterministic index.html, not arbitrary user
// content.
function rewriteHtmlBody(htmlBuffer) {
    let html = htmlBuffer.toString('utf8');
    // 1. Strip PWA manifest link — kills the install button.
    html = html.replace(/<link\b[^>]*\brel=(['"])manifest\1[^>]*>\s*/gi, '');
    // 2. Inject the bootstrap script right after <head ...>.
    const injected = `<script>${BOOTSTRAP_SCRIPT}</script>`;
    if (/<head\b[^>]*>/i.test(html)) {
        html = html.replace(/<head\b[^>]*>/i, (m) => m + injected);
    } else {
        // Extremely unlikely for opencode's HTML, but fall back to
        // prepending so the seed still runs.
        html = injected + html;
    }
    return Buffer.from(html, 'utf8');
}

// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
// Precomputed sha256 for our bootstrap script body — this is the hash
// the browser expects to see in `script-src` for the <script>BOOTSTRAP</script>
// we inject. Computed once at module load; if BOOTSTRAP_SCRIPT ever changes
// we'll get a fresh hash on process restart automatically.
const BOOTSTRAP_SCRIPT_SHA256 = crypto
    .createHash('sha256')
    .update(BOOTSTRAP_SCRIPT, 'utf8')
    .digest('base64');

function log(level, msg, extra) {
    const line = JSON.stringify({ ts: new Date().toISOString(), level, msg, ...extra });
    process.stderr.write(line + '\n');
}

const server = http.createServer((req, res) => {
    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    // PWA-kill short-circuit: 404 the manifest and service-worker entry
    // points BEFORE forwarding upstream. Avoids any chance of the browser
    // installing or registering them, even if opencode's response changed.
    const reqPathOnly = req.url.split('?')[0];
    if (PWA_KILL_PATHS.has(reqPathOnly)) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        res.end('disabled by tillandsias');
        return;
    }

    const accept = req.headers['accept'] || '';
    const sse = SSE_PATHS.has(req.url) || accept.includes('text/event-stream');

    const headers = { ...req.headers, host: `${UP_HOST}:${UP_PORT}` };
    delete headers['connection'];
    delete headers['keep-alive'];
    delete headers['transfer-encoding'];
    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    // Drop the `Origin` header so opencode's CorsMiddleware (strict-exact
    // allowlist: localhost:<port>, 127.0.0.1:<port>, app.opencode.ai) never
    // sees our `*.localhost:<port>` origin. Without this the proxy would
    // have to inject `server.cors` entries for every dynamic project name
    // — fragile and per-attach. Dropping Origin sidesteps the allowlist
    // entirely and is how the upstream proxied path handles it too.
    delete headers['origin'];
    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    // Strip Accept-Encoding so opencode sends plain UTF-8 HTML (no gzip,
    // no brotli). Otherwise our HTML rewrite (manifest-link strip +
    // bootstrap-script inject) operates on compressed bytes and produces
    // garbage; Chrome then reports ERR_CONTENT_DECODING_FAILED because
    // the Content-Encoding header still says gzip while the body is our
    // rewritten plain text. Strip here is the simplest correct fix —
    // the alternative (decode, rewrite, re-encode, repair content-length
    // + trailers) adds a gzip dep and multiplies failure modes for zero
    // user-visible benefit on loopback traffic.
    delete headers['accept-encoding'];

    const upReq = http.request(
        { host: UP_HOST, port: UP_PORT, method: req.method, path: req.url, headers },
        (upRes) => {
            // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
            // HTML rewrite branch: buffer the body so we can compute the
            // sha256 of each inline <script> and add it to the
            // Content-Security-Policy header. Opencode's DEFAULT_CSP blocks
            // its own inline oc-theme-preload-script; without this the UI
            // loads with a CSP violation and the theme never applies.
            const isHtml =
                !sse &&
                typeof upRes.headers['content-type'] === 'string' &&
                upRes.headers['content-type'].includes('text/html') &&
                upRes.statusCode === 200 &&
                upRes.headers['content-security-policy'];
            if (isHtml) {
                const chunks = [];
                upRes.on('data', (c) => chunks.push(c));
                upRes.on('end', () => {
                    const originalBody = Buffer.concat(chunks);
                    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
                    // Strip <link rel=manifest> + inject bootstrap <script>
                    // as first child of <head>. The bootstrap's sha256 is
                    // added to script-src so the browser executes it under
                    // opencode's otherwise-strict CSP.
                    const newBody = rewriteHtmlBody(originalBody);
                    const patchedCsp = injectCspHashesInHtml(
                        newBody,
                        upRes.headers['content-security-policy'],
                        [`'sha256-${BOOTSTRAP_SCRIPT_SHA256}'`]
                    );
                    const outHeaders = { ...upRes.headers };
                    outHeaders['content-security-policy'] = patchedCsp;
                    outHeaders['content-length'] = String(newBody.length);
                    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
                    // Belt-and-braces: even if opencode adds a service-worker
                    // registration script in a future release, this header
                    // causes the browser to reject any SW scope.
                    outHeaders['service-worker-allowed'] = 'none';
                    delete outHeaders['transfer-encoding'];
                    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
                    // Strip content-encoding from the rewritten HTML response:
                    // our body is always plain UTF-8. Accept-Encoding was
                    // dropped on the upstream request so opencode should be
                    // sending plain already, but we defend against any
                    // upstream that ignores Accept-Encoding. If we left a
                    // stale `content-encoding: gzip` on a plain body, Chrome
                    // would hit ERR_CONTENT_DECODING_FAILED and show a blank
                    // page with no console message beyond that.
                    delete outHeaders['content-encoding'];
                    res.writeHead(upRes.statusCode, outHeaders);
                    res.end(newBody);
                });
                upRes.on('error', (e) => {
                    log('warn', 'html buffering error', { error: e.message });
                    if (!res.writableEnded) res.end();
                });
                return;
            }

            res.writeHead(upRes.statusCode, upRes.headers);

            if (sse && upRes.statusCode === 200) {
                // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
                // Keep-alive injector: if the upstream has been silent for
                // KEEPALIVE_MS, write a `:\n\n` SSE comment to the client.
                // This is a WHATWG-compliant SSE comment and is invisible to
                // correct clients; the bytes flow through the socket so
                // Bun's idleTimeout never trips.
                //
                // CRITICAL: only inject when upstream is silent — never during
                // an in-flight event. If we interleaved `:\n\n` mid-event the
                // blank line would split the event and corrupt its payload
                // (UI would see two broken messages instead of one). We track
                // `lastUpstreamChunk` and only fire when the gap since the
                // last upstream byte exceeds KEEPALIVE_MS.
                let lastUpstreamChunk = Date.now();
                const tick = setInterval(() => {
                    if (res.writableEnded) return;
                    if (Date.now() - lastUpstreamChunk < KEEPALIVE_MS) return;
                    try {
                        res.write(':\n\n');
                        lastUpstreamChunk = Date.now();
                    } catch (_) {}
                }, Math.max(500, Math.floor(KEEPALIVE_MS / 2)));
                upRes.on('data', (chunk) => {
                    lastUpstreamChunk = Date.now();
                    res.write(chunk);
                });
                upRes.on('end', () => { clearInterval(tick); res.end(); });
                upRes.on('error', () => clearInterval(tick));
                upRes.on('close', () => clearInterval(tick));
                res.on('close', () => clearInterval(tick));
                return;
            }

            upRes.pipe(res);
        }
    );

    upReq.on('error', (e) => {
        log('warn', 'upstream error', { error: e.message, code: e.code, path: req.url });
        if (!res.writableEnded) {
            res.writeHead(502, { 'content-type': 'text/plain' });
            res.end(`upstream error: ${e.message}`);
        }
    });

    req.pipe(upReq);
});

server.on('clientError', (err, socket) => {
    try { socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'); } catch (_) {}
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
    log('info', 'sse-keepalive-proxy listening', {
        listen: `${LISTEN_HOST}:${LISTEN_PORT}`,
        upstream: `${UP_HOST}:${UP_PORT}`,
        keepalive_ms: KEEPALIVE_MS,
    });
});

server.on('error', (e) => {
    log('fatal', 'listener error', { error: e.message });
    process.exit(1);
});

for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
        log('info', `received ${sig} — shutting down`);
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 1000).unref();
    });
}
