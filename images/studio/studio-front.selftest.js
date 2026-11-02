// @trace order:1860-auhm, spec:web-studio-lane
//
// Arms for studio-front.js, run INSIDE the forge image (its node and git), never
// on the host: node studio-front.selftest.js <studios.json>
// Prints one verdict line on stdout: ok:studio-front:<n>-arms, or
// refused:studio-front:<arm>:<why>.

'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { execFileSync } = require('node:child_process');
const front = require('./studio-front.js');

let arms = 0;
function fail(arm, why) {
    process.stdout.write(`refused:studio-front:${arm}:${String(why).replace(/\s+/g, '_')}\n`);
    process.exit(1);
}
function check(arm, cond, why) { if (!cond) fail(arm, why); }

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-front-'));
const checkout = path.join(tmp, 'site');
fs.mkdirSync(checkout);
const g = (args) => execFileSync('git', ['-C', checkout, ...args], {
    encoding: 'utf8',
    env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1',
           GIT_AUTHOR_NAME: 'user', GIT_AUTHOR_EMAIL: 'u@example.invalid',
           GIT_COMMITTER_NAME: 'user', GIT_COMMITTER_EMAIL: 'u@example.invalid' },
});
process.env.GIT_CONFIG_GLOBAL = '/dev/null';
process.env.GIT_CONFIG_NOSYSTEM = '1';
process.env.GIT_AUTHOR_NAME = 'user'; process.env.GIT_AUTHOR_EMAIL = 'u@example.invalid';
process.env.GIT_COMMITTER_NAME = 'user'; process.env.GIT_COMMITTER_EMAIL = 'u@example.invalid';
g(['init', '-q', '-b', 'main']);
fs.writeFileSync(path.join(checkout, 'index.html'), '<h1>a</h1>\n');
// A tracked symlink inside the checkout that points out of it.
fs.mkdirSync(path.join(tmp, 'outside'));
fs.symlinkSync(path.join(tmp, 'outside'), path.join(checkout, 'escape'));
g(['add', '.']); g(['commit', '-q', '-m', 'init']);

const registry = process.argv[2];
const cfg = front.loadConfig({ TILLANDSIAS_STUDIO: 'grapesjs', STUDIO_REGISTRY: registry, STUDIO_CHECKOUT: checkout });
const events = [];
const realWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (s) => { events.push(String(s)); return true; };
const restore = () => { process.stdout.write = realWrite; };

// 1 guard refusals: traversal, .git, absolute, symlink escape, not allowlisted.
const refusals = {
    '../../etc/x': 'outside-checkout',
    '.git/config': 'git-dir',
    'sub/.GIT/hooks/pre-commit': 'git-dir',
    '/etc/passwd': 'absolute',
    'escape/x.html': 'outside-checkout',
    'secrets.env': 'not-allowlisted',
};
for (const [p, reason] of Object.entries(refusals)) {
    const before = g(['rev-parse', 'HEAD']);
    const r = front.save(cfg, p, 'pwned');
    restore();
    check(1, r.status === 403 && r.body.refused === reason, `${p}:got-${JSON.stringify(r)}`);
    check(1, g(['rev-parse', 'HEAD']) === before, `${p}:committed`);
    process.stdout.write = (s) => { events.push(String(s)); return true; };
}
check(1, !fs.existsSync('/etc/x') && !fs.existsSync(path.join(tmp, 'outside', 'x.html')), 'a refused save wrote');
restore();
check(1, events.filter((e) => e.startsWith('event:studio.save_refused ')).length === Object.keys(refusals).length,
      `refusals-not-evented:${events.length}`);
arms++;

// 2 an allowlisted save is written, committed as studio(<id>): save <path>, evented.
events.length = 0;
process.stdout.write = (s) => { events.push(String(s)); return true; };
const ok = front.save(cfg, 'index.html', '<h1>b</h1>\n');
const nested = front.save(cfg, 'pages/about.html', '<p>x</p>\n');
restore();
check(2, ok.status === 200 && /^[0-9a-f]{40}$/.test(ok.body.sha || ''), JSON.stringify(ok));
check(2, nested.status === 200, JSON.stringify(nested));
const log = g(['log', '--format=%s', '-n', '2']).trim().split('\n');
check(2, log[1] === 'studio(grapesjs): save index.html' && log[0] === 'studio(grapesjs): save pages/about.html', log.join('|'));
check(2, events.filter((e) => e.startsWith('event:studio.save ')).length === 2, events.join(''));
check(2, g(['status', '--porcelain']).trim() === '', 'tree-dirty-after-save');
arms++;

// 3 the same bytes again is accepted and makes no empty commit.
const head = g(['rev-parse', 'HEAD']);
process.stdout.write = () => true;
const same = front.save(cfg, 'index.html', '<h1>b</h1>\n');
restore();
check(3, same.status === 200 && same.body.sha === null && g(['rev-parse', 'HEAD']) === head, JSON.stringify(same));
arms++;

// 4 the HTTP front: a traversal POST is refused with 403, an allowlisted one
// commits, and a PWA path is 404 — through the real server.
const server = front.start({
    TILLANDSIAS_STUDIO: 'grapesjs', STUDIO_REGISTRY: registry, STUDIO_CHECKOUT: checkout,
    LISTEN_HOST: '127.0.0.1', LISTEN_PORT: '0', UPSTREAM: '127.0.0.1:9',
});
server.on('listening', async () => {
    const port = server.address().port;
    const req = (method, p, body) => new Promise((resolve) => {
        const r = http.request({ host: '127.0.0.1', port, method, path: p, headers: { 'content-type': 'application/json' } },
            (res) => { let d = ''; res.on('data', (c) => { d += c; }); res.on('end', () => resolve({ status: res.statusCode, body: d })); });
        r.on('error', (e) => resolve({ status: 0, body: String(e) }));
        if (body) r.write(body);
        r.end();
    });
    process.stdout.write = () => true;
    const bad = await req('POST', '/__studio/save', JSON.stringify({ path: '../../etc/x', content: 'x' }));
    const good = await req('POST', '/__studio/save', JSON.stringify({ path: 'style.css', content: 'h1{}\n' }));
    const pwa = await req('GET', '/sw.js');
    const junk = await req('POST', '/__studio/save', 'not json');
    restore();
    server.close();
    check(4, bad.status === 403, `traversal:${bad.status}`);
    check(4, good.status === 200 && g(['log', '-1', '--format=%s']).trim() === 'studio(grapesjs): save style.css', `save:${good.status}:${good.body}`);
    check(4, pwa.status === 404, `pwa:${pwa.status}`);
    check(4, junk.status === 400, `junk:${junk.status}`);
    arms++;
    await ownWriterArm();
    fs.rmSync(tmp, { recursive: true, force: true });
    process.stdout.write(`ok:studio-front:${arms}-arms\n`);
});

// 5 an own-writer studio (decap): a write request the front proxies is
// bracketed. The allowlisted file it wrote is committed, the off-allowlist one
// is removed and evented, and the agent's edit made before it is untouched.
async function ownWriterArm() {
    fs.writeFileSync(path.join(checkout, 'agent-notes.txt'), 'work in progress\n');
    const upstream = http.createServer((req, res) => {
        fs.mkdirSync(path.join(checkout, 'content', 'posts'), { recursive: true });
        fs.writeFileSync(path.join(checkout, 'content', 'posts', 'hello.md'), '# hello\n');
        fs.writeFileSync(path.join(checkout, 'secrets.env'), 'TOKEN=x\n');
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end('{}');
    });
    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const ev = [];
    process.stdout.write = (s) => { ev.push(String(s)); return true; };
    const srv = front.start({
        TILLANDSIAS_STUDIO: 'decap', STUDIO_REGISTRY: registry, STUDIO_CHECKOUT: checkout,
        LISTEN_HOST: '127.0.0.1', LISTEN_PORT: '0', UPSTREAM: `127.0.0.1:${upstream.address().port}`,
    });
    await new Promise((r) => srv.on('listening', r));
    const status = await new Promise((resolve) => {
        const r = http.request({ host: '127.0.0.1', port: srv.address().port, method: 'POST', path: '/api/v1',
            headers: { 'content-type': 'application/json' } }, (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
        r.on('error', () => resolve(0));
        r.end('{"action":"persistEntry"}');
    });
    restore();
    srv.close(); upstream.close();
    check(5, status === 403, `refused-write-reported:${status}`);
    check(5, g(['log', '-1', '--format=%s']).trim() === 'studio(decap): save content/posts/hello.md', g(['log', '-1', '--format=%s']));
    check(5, !fs.existsSync(path.join(checkout, 'secrets.env')), 'off-allowlist-write-kept');
    check(5, ev.some((e) => e.startsWith('event:studio.save_refused ') && e.includes('path=secrets.env')), ev.join(''));
    check(5, fs.readFileSync(path.join(checkout, 'agent-notes.txt'), 'utf8') === 'work in progress\n', 'agent-edit-touched');
    check(5, g(['status', '--porcelain']).trim() === '?? agent-notes.txt', g(['status', '--porcelain']));
    arms++;
}
