#!/usr/bin/env node
// @trace order:1860-auhm, spec:web-studio-lane
//
// The studio front: the one process the router reaches for studio.<label>.
// It runs inside the forge, next to the checkout it guards.
//
//   POST /__studio/save   {"path": "<relative>", "content": "<utf-8>"}
//       Every studio write that comes through the shared endpoint (GrapesJS
//       remote storage, Puck onChange/onPublish). The path passes ONE guard:
//       inside the checkout after canonicalisation (symlinks included), never
//       under .git/, and matching the studio's write_allowlist. An accepted
//       write is committed as `studio(<id>): save <path>` and emits one
//       `event:studio.save`; a refused one writes nothing and emits one
//       `event:studio.save_refused`.
//   everything else       proxied to the studio's own server (UPSTREAM), with
//       SSE keepalive comments, WebSocket upgrades passed through for hot
//       reload, and the PWA kill paths 404'd (the ephemeral contract).
//
// Config (env): LISTEN_HOST, LISTEN_PORT (4096), UPSTREAM (127.0.0.1:4097),
// KEEPALIVE_MS, TILLANDSIAS_STUDIO (the registry id), TILLANDSIAS_PROJECT,
// STUDIO_CHECKOUT (default /home/forge/src/$TILLANDSIAS_PROJECT),
// STUDIO_REGISTRY (default /usr/local/share/tillandsias/studios.json).

'use strict';
const http = require('node:http');
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const SAVE_PATH = '/__studio/save';
const MAX_SAVE_BYTES = 8 * 1024 * 1024;
const PWA_KILL_PATHS = new Set([
    '/site.webmanifest', '/manifest.json', '/manifest.webmanifest',
    '/sw.js', '/service-worker.js', '/worker.js',
]);

function event(kind, fields) {
    const body = Object.entries(fields)
        .map(([k, v]) => `${k}=${String(v).replace(/\s+/g, '_')}`)
        .join(' ');
    process.stdout.write(`event:${kind} ${body}\n`);
}

// A glob over '/'-separated relative paths: '**' crosses directories, '*'
// and '?' do not.
function globToRegExp(glob) {
    let re = '^';
    for (let i = 0; i < glob.length; i++) {
        const c = glob[i];
        if (c === '*' && glob[i + 1] === '*') {
            i++;
            if (glob[i + 1] === '/') { i++; re += '(?:.*/)?'; } else { re += '.*'; }
        } else if (c === '*') {
            re += '[^/]*';
        } else if (c === '?') {
            re += '[^/]';
        } else {
            re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
        }
    }
    return new RegExp(re + '$');
}

// The deepest existing ancestor of `p`, canonicalised; the missing tail is
// appended as-is (it cannot be a symlink: it does not exist yet).
function canonicalOf(p) {
    let head = p;
    const tail = [];
    for (;;) {
        try {
            return path.join(fs.realpathSync(head), ...tail.reverse());
        } catch (e) {
            if (e.code !== 'ENOENT' && e.code !== 'ENOTDIR') throw e;
            const parent = path.dirname(head);
            if (parent === head) throw e;
            tail.push(path.basename(head));
            head = parent;
        }
    }
}

// The guard. Returns {ok:true, rel, abs} or {ok:false, reason}.
function guard(checkout, requested, allowlist) {
    if (typeof requested !== 'string' || requested === '' || requested.includes('\0')) {
        return { ok: false, reason: 'not-a-path' };
    }
    if (path.isAbsolute(requested) || /^[A-Za-z]:/.test(requested)) {
        return { ok: false, reason: 'absolute' };
    }
    const root = fs.realpathSync(checkout);
    let abs;
    try {
        abs = canonicalOf(path.resolve(root, requested));
    } catch (_) {
        return { ok: false, reason: 'unresolvable' };
    }
    const rel = path.relative(root, abs);
    if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) {
        return { ok: false, reason: 'outside-checkout' };
    }
    const parts = rel.split(path.sep);
    if (parts.some((p) => p.toLowerCase() === '.git')) {
        return { ok: false, reason: 'git-dir' };
    }
    const posix = parts.join('/');
    if (!allowlist.some((g) => globToRegExp(g).test(posix))) {
        return { ok: false, reason: 'not-allowlisted' };
    }
    return { ok: true, rel: posix, abs };
}

function git(checkout, args) {
    return execFileSync('git', ['-C', checkout, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

// Guard, write, commit. Every accepted save is a commit (operator ruling
// 2026-10-25): concurrent edits are ordered by commit, never last-write-wins.
function save(cfg, requested, content) {
    const g = guard(cfg.checkout, requested, cfg.allowlist);
    if (!g.ok) {
        event('studio.save_refused', { studio: cfg.id, path: requested, reason: g.reason });
        return { status: 403, body: { refused: g.reason } };
    }
    fs.mkdirSync(path.dirname(g.abs), { recursive: true });
    fs.writeFileSync(g.abs, content);
    git(cfg.checkout, ['add', '--', g.rel]);
    let sha = '';
    const staged = git(cfg.checkout, ['diff', '--cached', '--name-only', '--', g.rel]).trim();
    if (staged) {
        git(cfg.checkout, ['commit', '-q', '-m', `studio(${cfg.id}): save ${g.rel}`, '--', g.rel]);
        sha = git(cfg.checkout, ['rev-parse', 'HEAD']).trim();
    }
    event('studio.save', { studio: cfg.id, path: g.rel, sha: sha || 'unchanged' });
    return { status: 200, body: { path: g.rel, sha: sha || null } };
}

// Own-writer studios (Decap, Tina) write the checkout themselves, through
// their own servers. Every write request the front proxies to such a studio is
// bracketed: the checkout's changed paths are read before it and after its
// response, and each path the request changed passes the same guard as a
// save. An allowlisted path is committed (`studio(<id>): save|delete <path>`,
// one `event:studio.save`); any other is put back as it was and evented
// `event:studio.save_refused`. Paths the request did not change, such as the
// agent's own work in progress, are never touched (1862-wrx5).
function changedPaths(checkout) {
    const out = git(checkout, ['status', '--porcelain=v1', '-z', '--untracked-files=all']);
    const sigs = new Map();
    const entries = out.split('\0');
    for (let i = 0; i < entries.length; i++) {
        const e = entries[i];
        if (e.length < 4) continue;
        const code = e.slice(0, 2);
        const rel = e.slice(3);
        if (code[0] === 'R' || code[0] === 'C') i++; // the source path follows
        let st = 'gone';
        try {
            const s = fs.lstatSync(path.join(checkout, rel));
            st = `${s.size}:${s.mtimeMs}`;
        } catch (_) { /* deleted */ }
        sigs.set(rel, `${code}:${st}`);
    }
    return sigs;
}

function tracked(checkout, rel) {
    try {
        git(checkout, ['ls-files', '--error-unmatch', '--', rel]);
        return true;
    } catch (_) {
        return false;
    }
}

// Returns the paths it put back, so the front can tell the browser.
function sweep(cfg, before) {
    const refused = [];
    const after = changedPaths(cfg.checkout);
    const touched = [...after.keys()].filter((p) => after.get(p) !== before.get(p));
    for (const p of [...before.keys()]) if (!after.has(p)) touched.push(p);
    for (const rel of touched) {
        const g = guard(cfg.checkout, rel, cfg.allowlist);
        if (!g.ok) {
            if (tracked(cfg.checkout, rel)) {
                git(cfg.checkout, ['checkout', 'HEAD', '--', rel]);
            } else {
                fs.rmSync(path.join(cfg.checkout, rel), { force: true });
            }
            event('studio.save_refused', { studio: cfg.id, path: rel, reason: g.reason });
            refused.push(rel);
            continue;
        }
        git(cfg.checkout, ['add', '-A', '--', g.rel]);
        const staged = git(cfg.checkout, ['diff', '--cached', '--name-only', '--', g.rel]).trim();
        if (!staged) continue;
        const verb = fs.existsSync(g.abs) ? 'save' : 'delete';
        git(cfg.checkout, ['commit', '-q', '-m', `studio(${cfg.id}): ${verb} ${g.rel}`, '--', g.rel]);
        event('studio.save', { studio: cfg.id, path: g.rel, sha: git(cfg.checkout, ['rev-parse', 'HEAD']).trim() });
    }
    return refused;
}

const READ_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

function loadConfig(env) {
    const id = env.TILLANDSIAS_STUDIO || '';
    const registry = JSON.parse(fs.readFileSync(
        env.STUDIO_REGISTRY || '/usr/local/share/tillandsias/studios.json', 'utf8'));
    const studio = (registry.studios || []).find((s) => s.id === id);
    if (!studio) throw new Error(`studio ${JSON.stringify(id)} is not in the registry`);
    return {
        id,
        allowlist: studio.write_allowlist,
        ownWriter: studio.save_adapter === 'own-writer',
        checkout: env.STUDIO_CHECKOUT || `/home/forge/src/${env.TILLANDSIAS_PROJECT || ''}`,
    };
}

function readBody(req, limit) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let n = 0;
        req.on('data', (c) => {
            n += c.length;
            if (n > limit) { reject(new Error('too-large')); req.destroy(); return; }
            chunks.push(c);
        });
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

function start(env) {
    const cfg = loadConfig(env);
    const [upHost, upPortStr] = (env.UPSTREAM || '127.0.0.1:4097').split(':');
    const upPort = Number(upPortStr);
    const keepaliveMs = Number(env.KEEPALIVE_MS || 5000);

    const server = http.createServer(async (req, res) => {
        const url = new URL(req.url, 'http://front');
        if (PWA_KILL_PATHS.has(url.pathname)) { res.writeHead(404); res.end(); return; }
        if (url.pathname === SAVE_PATH) {
            if (req.method !== 'POST') { res.writeHead(405); res.end(); return; }
            let out;
            try {
                const body = JSON.parse(await readBody(req, MAX_SAVE_BYTES));
                out = save(cfg, body.path, typeof body.content === 'string' ? body.content : '');
            } catch (e) {
                event('studio.save_refused', { studio: cfg.id, path: '-', reason: 'bad-request' });
                out = { status: 400, body: { refused: 'bad-request' } };
            }
            res.writeHead(out.status, { 'content-type': 'application/json' });
            res.end(JSON.stringify(out.body));
            return;
        }
        const bracket = cfg.ownWriter && !READ_METHODS.has(req.method);
        const before = bracket ? changedPaths(cfg.checkout) : null;
        const up = http.request({ host: upHost, port: upPort, method: req.method, path: req.url, headers: req.headers }, (ur) => {
            if (bracket) {
                // The studio has written by the time it answers; guard before
                // the browser hears back, so a refused write is never reported
                // saved: the studio's answer is replaced by the refusal.
                let refused;
                try { refused = sweep(cfg, before); } catch (e) { refused = ['-']; event('studio.save_refused', { studio: cfg.id, path: '-', reason: 'sweep-failed' }); }
                if (refused.length) {
                    ur.resume();
                    res.writeHead(403, { 'content-type': 'application/json' });
                    res.end(JSON.stringify({ refused: 'not-allowlisted', paths: refused }));
                    return;
                }
            }
            res.writeHead(ur.statusCode, ur.headers);
            const sse = String(ur.headers['content-type'] || '').startsWith('text/event-stream');
            let timer = null;
            if (sse) timer = setInterval(() => res.write(':\n\n'), keepaliveMs);
            ur.pipe(res);
            ur.on('end', () => timer && clearInterval(timer));
            res.on('close', () => timer && clearInterval(timer));
        });
        up.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
        req.pipe(up);
    });

    // Hot reload: pass WebSocket upgrades through untouched.
    server.on('upgrade', (req, socket, head) => {
        const upstream = net.connect(upPort, upHost, () => {
            const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
            for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
            upstream.write(lines.join('\r\n') + '\r\n\r\n');
            if (head && head.length) upstream.write(head);
            upstream.pipe(socket);
            socket.pipe(upstream);
        });
        upstream.on('error', () => socket.destroy());
        socket.on('error', () => upstream.destroy());
    });

    server.listen(Number(env.LISTEN_PORT || 4096), env.LISTEN_HOST || '0.0.0.0');
    return server;
}

module.exports = { guard, save, sweep, changedPaths, globToRegExp, loadConfig, start };

if (require.main === module) start(process.env);
