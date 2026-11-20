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
const BRANCH_PATH = '/__studio/branch';
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

// 2108-dptd: the project's default branch, as the checkout knows it: the
// remote's HEAD, else init.defaultBranch, else main or master if present.
function defaultBranch(checkout) {
    try {
        return git(checkout, ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD']).trim().replace(/^origin\//, '');
    } catch (_) { /* no remote HEAD */ }
    try {
        const d = git(checkout, ['config', '--get', 'init.defaultBranch']).trim();
        if (d) return d;
    } catch (_) { /* unset */ }
    for (const b of ['main', 'master']) {
        try { git(checkout, ['rev-parse', '--verify', '--quiet', `refs/heads/${b}`]); return b; } catch (_) { /* absent */ }
    }
    return 'main';
}

function currentBranch(checkout) {
    try { return git(checkout, ['symbolic-ref', '--short', 'HEAD']).trim(); } catch (_) { return ''; }
}

function slug(s) {
    return String(s || 'site').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'site';
}

// The studio never commits on the default branch (operator ruling: main
// changes only through a PR). On it, or detached, the checkout switches to
// the studio's work branch, `<studio>/<project>-work/<date>` (2095-6cwr), or
// STUDIO_WORK_BRANCH when the launcher names one. Uncommitted work moves with
// the switch, so nothing the agent had in progress is lost.
function ensureWorkBranch(cfg) {
    const cur = currentBranch(cfg.checkout);
    if (cur && cur !== defaultBranch(cfg.checkout)) return cur;
    const name = cfg.workBranch;
    let exists = true;
    try { git(cfg.checkout, ['rev-parse', '--verify', '--quiet', `refs/heads/${name}`]); } catch (_) { exists = false; }
    git(cfg.checkout, exists ? ['switch', '-q', name] : ['switch', '-q', '-c', name]);
    event('studio.work_branch', { studio: cfg.id, branch: name, from: cur || 'detached' });
    return name;
}

// 2120-sv7m: a save reaches origin. In a forge, origin is the project's git
// mirror, which relays each push to the cloud remote synchronously, so the
// studio pushes credential-free and never holds a token. Only the studio's own
// work branch is pushed, never the default branch: main changes only through a
// PR the operator opens. An unreachable or refusing origin never loses the
// save: it stays committed, the body says pushed:false, and the next save
// pushes it, because every save pushes HEAD (a no-op when origin has it).
function relay(cfg, branch) {
    if (!branch || branch === defaultBranch(cfg.checkout)) return false;
    try { if (!git(cfg.checkout, ['remote', 'get-url', 'origin']).trim()) return false; } catch (_) { return false; }
    const head = git(cfg.checkout, ['rev-parse', 'HEAD']).trim();
    try {
        execFileSync('git', ['-C', cfg.checkout, 'push', '-q', 'origin', `HEAD:refs/heads/${branch}`], {
            encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: cfg.pushTimeoutMs,
            env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
        });
    } catch (e) {
        const why = String(e.stderr || e.message || '').trim().split('\n').pop() || 'push-failed';
        event('studio.push_failed', { studio: cfg.id, branch, sha: head, why });
        return false;
    }
    event('studio.push', { studio: cfg.id, branch, sha: head });
    return true;
}

// 2120-sv7m: GET /__studio/branch, for the editors' "Open PR" link. The PR is
// opened by the operator, signed in as themselves, from GitHub's compare page
// (which links the PR once one exists); no token is held. repoWeb is the bare
// https://github.com/<owner>/<repo> the launcher passes as STUDIO_REPO_WEB.
function compareUrl(repoWeb, base, branch) {
    if (!/^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repoWeb || '')) return null;
    const seg = /^[A-Za-z0-9._/-]+$/;
    if (!seg.test(base) || !seg.test(branch) || branch.includes('..')) return null;
    return `${repoWeb}/compare/${base}...${branch}?expand=1`;
}

function branchState(cfg) {
    const branch = currentBranch(cfg.checkout);
    const base = defaultBranch(cfg.checkout);
    if (!branch || branch === base) return { branch: branch || null, pushed: false, compare_url: null };
    const head = git(cfg.checkout, ['rev-parse', 'HEAD']).trim();
    let tracked = '';
    try { tracked = git(cfg.checkout, ['rev-parse', '--verify', '--quiet', `refs/remotes/origin/${branch}`]).trim(); } catch (_) { /* never pushed */ }
    return { branch, pushed: tracked === head, compare_url: tracked ? compareUrl(cfg.repoWeb, base, branch) : null };
}

// Guard, write, commit. Every accepted save is a commit (operator ruling
// 2026-10-25): concurrent edits are ordered by commit, never last-write-wins.
function save(cfg, requested, content) {
    const g = guard(cfg.checkout, requested, cfg.allowlist);
    if (!g.ok) {
        event('studio.save_refused', { studio: cfg.id, path: requested, reason: g.reason });
        return { status: 403, body: { refused: g.reason } };
    }
    const branch = ensureWorkBranch(cfg);
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
    const pushed = relay(cfg, branch);
    return { status: 200, body: { path: g.rel, sha: sha || null, branch, pushed } };
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
    let committed = false;
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
        ensureWorkBranch(cfg);
        git(cfg.checkout, ['add', '-A', '--', g.rel]);
        const staged = git(cfg.checkout, ['diff', '--cached', '--name-only', '--', g.rel]).trim();
        if (!staged) continue;
        const verb = fs.existsSync(g.abs) ? 'save' : 'delete';
        git(cfg.checkout, ['commit', '-q', '-m', `studio(${cfg.id}): ${verb} ${g.rel}`, '--', g.rel]);
        event('studio.save', { studio: cfg.id, path: g.rel, sha: git(cfg.checkout, ['rev-parse', 'HEAD']).trim() });
        committed = true;
    }
    if (committed) relay(cfg, currentBranch(cfg.checkout));
    return refused;
}

const READ_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

function loadConfig(env) {
    const id = env.TILLANDSIAS_STUDIO || '';
    const registry = JSON.parse(fs.readFileSync(
        env.STUDIO_REGISTRY || '/usr/local/share/tillandsias/studios.json', 'utf8'));
    const studio = (registry.studios || []).find((s) => s.id === id);
    if (!studio) throw new Error(`studio ${JSON.stringify(id)} is not in the registry`);
    const day = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    return {
        id,
        allowlist: studio.write_allowlist,
        ownWriter: studio.save_adapter === 'own-writer',
        checkout: env.STUDIO_CHECKOUT || `/home/forge/src/${env.TILLANDSIAS_PROJECT || ''}`,
        pushTimeoutMs: Number(env.STUDIO_PUSH_TIMEOUT_MS || 30000),
        repoWeb: env.STUDIO_REPO_WEB || '',
        workBranch: env.STUDIO_WORK_BRANCH || `${slug(id)}/${slug(env.TILLANDSIAS_PROJECT)}-work/${day}`,
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
    // Off the default branch before the editor loads, so even the first
    // save cannot land there (2108-dptd).
    try { ensureWorkBranch(cfg); } catch (e) { event('studio.work_branch_failed', { studio: cfg.id, why: e.message }); }
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
        if (url.pathname === BRANCH_PATH) {
            if (req.method !== 'GET') { res.writeHead(405); res.end(); return; }
            let body;
            try { body = branchState(cfg); } catch (e) { body = { branch: null, pushed: false, compare_url: null }; }
            res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
            res.end(JSON.stringify(body));
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

module.exports = { guard, save, sweep, changedPaths, globToRegExp, loadConfig, start, ensureWorkBranch, defaultBranch, relay, branchState, compareUrl };

if (require.main === module) start(process.env);
