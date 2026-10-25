// @trace spec:opencode-web-session-otp, spec:browser-isolation-tray-integration
// Order 1802-9xix: the OpenCode Web window must open on the forge's checkout.
// Run: node --test images/default/sse-keepalive-proxy.test.js
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const vm = require('node:vm');
const path = require('node:path');

process.env.LISTEN_PORT = '0';
process.env.LISTEN_HOST = '127.0.0.1';
const proxy = require(path.join(__dirname, 'sse-keepalive-proxy.js'));

function fakeStorage(initial) {
    const m = new Map(Object.entries(initial || {}));
    return {
        getItem: (k) => (m.has(k) ? m.get(k) : null),
        setItem: (k, v) => m.set(k, String(v)),
        dump: () => Object.fromEntries(m),
    };
}

function runBootstrap(dir, initial) {
    const localStorage = fakeStorage(initial);
    vm.runInNewContext(proxy.buildBootstrapScript(dir), { localStorage, JSON });
    const server = JSON.parse(localStorage.getItem('opencode.global.dat:server'));
    return { server, storage: localStorage };
}

test('the proxy is a module and does not listen when required', () => {
    assert.strictEqual(typeof proxy.buildBootstrapScript, 'function');
    assert.strictEqual(typeof proxy.rootRedirectTarget, 'function');
});

test('the project route is the web app slug of the server cwd', () => {
    assert.strictEqual(
        proxy.projectRoute('/home/forge/src/tillandsias'),
        '/L2hvbWUvZm9yZ2Uvc3JjL3RpbGxhbmRzaWFz/session'
    );
    assert.strictEqual(proxy.normalizeProjectDir('/home/forge/src/tillandsias/'), '/home/forge/src/tillandsias');
});

test('a page load of / redirects to the checkout, for dotted names too', () => {
    for (const dir of ['/home/forge/src/tillandsias', '/home/forge/src/macron.dev']) {
        const to = proxy.rootRedirectTarget('GET', '/', 'text/html,application/xhtml+xml', dir);
        assert.strictEqual(to, proxy.projectRoute(dir));
        assert.strictEqual(Buffer.from(to.split('/')[1], 'base64url').toString('utf8'), dir);
    }
    const d = '/home/forge/src/tillandsias';
    assert.strictEqual(proxy.rootRedirectTarget('GET', '/?x=1', 'text/html', d), proxy.projectRoute(d) + '?x=1');
    assert.strictEqual(proxy.rootRedirectTarget('GET', '/', 'application/json', d), null);
    assert.strictEqual(proxy.rootRedirectTarget('POST', '/', 'text/html', d), null);
    assert.strictEqual(proxy.rootRedirectTarget('GET', '/session', 'text/html', d), null);
});

test('the bootstrap opens the checkout in a fresh profile', () => {
    const { server, storage } = runBootstrap('/home/forge/src/macron.dev');
    assert.deepStrictEqual(server.projects.local, [{ worktree: '/home/forge/src/macron.dev', expanded: true }]);
    assert.strictEqual(server.lastProject.local, '/home/forge/src/macron.dev');
    assert.strictEqual(storage.getItem('opencode-color-scheme'), 'dark');
});

test('the bootstrap merges into an existing list and is idempotent', () => {
    const initial = {
        'opencode.global.dat:server': JSON.stringify({
            list: ['x'], projects: { local: [{ worktree: '/other', expanded: false }] },
            lastProject: { local: '/other' }, recentlyClosed: {},
        }),
    };
    const once = runBootstrap('/home/forge/src/tillandsias', initial);
    const twice = runBootstrap('/home/forge/src/tillandsias', once.storage.dump());
    assert.deepStrictEqual(twice.server.projects.local.map((p) => p.worktree), ['/home/forge/src/tillandsias', '/other']);
    assert.deepStrictEqual(twice.server.list, ['x']);
    assert.strictEqual(twice.server.lastProject.local, '/other');
});

test('a directory cannot close the injected script tag', () => {
    const script = proxy.buildBootstrapScript('/home/forge/src/</script><b>');
    assert.ok(!script.includes('</script>'));
    const html = proxy.rewriteHtmlBody(Buffer.from('<html><head></head></html>')).toString();
    assert.ok(html.includes('opencode.global.dat:server'));
});
