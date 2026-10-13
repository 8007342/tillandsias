// The WebKit engine window (order 1656-tjv4): Playwright's Linux WebKit,
// headful under Wayland, emulating one catalogue device, showing one URL.
// "WebKit (approximates Safari)": it is WebKit, not Safari.
//
// Configuration comes from the tray, as environment:
//   TILLANDSIAS_WEBKIT_URL     the project URL to open
//   TILLANDSIAS_WEBKIT_DEVICE  JSON: {viewport:{width,height}, deviceScaleFactor,
//                              isMobile, hasTouch, userAgent}
//   TILLANDSIAS_WEBKIT_RELAY   "<forwarder ip>:<port>[,<port>...]"
//
// THE LOOPBACK RELAY. WebKitGTK resolves names through GLib, which answers
// every `*.localhost` name with loopback and never reads /etc/hosts for them
// (measured 2026-10-13: with --add-host www.demo.localhost -> the forwarder,
// WebKit still got "Could not connect to www.demo.localhost: Connection
// refused"). So this process listens on the window's OWN loopback, on the
// given ports, and passes raw TCP to the per-window forwarder (1651-5t7n),
// unread. The project binding stays where it was: the forwarder admits only
// TLS whose SNI is this project's, and the router makes Host equal SNI. A
// name of another project reaches loopback, then the forwarder, which
// refuses it. Names outside .localhost resolve through /etc/hosts and the
// --internal network's DNS, which knows no outside name.
//
// TLS is always verified. The only trusted root is the enclave CA, which
// the tray bind-mounts read-only as this container's whole system bundle
// (/etc/ssl/certs/ca-certificates.crt). There is no ignoreHTTPSErrors.
//
// The window lives as long as its page: closing it, or the browser going
// away, ends this process and the container.
'use strict';
const { webkit } = require('/usr/local/lib/node_modules/playwright');

function fail(msg) {
  console.error(`webkit-window: ${msg}`);
  process.exit(2);
}

const url = process.env.TILLANDSIAS_WEBKIT_URL;
if (!url) fail('TILLANDSIAS_WEBKIT_URL is not set');
let device;
try {
  device = JSON.parse(process.env.TILLANDSIAS_WEBKIT_DEVICE || '{}');
} catch (e) {
  fail(`TILLANDSIAS_WEBKIT_DEVICE is not JSON: ${e.message}`);
}

function startRelay(spec) {
  const m = /^([0-9a-fA-F.:]+):([0-9,]+)$/.exec(spec || '');
  if (!m) fail(`TILLANDSIAS_WEBKIT_RELAY must be <ip>:<port>[,<port>]: ${spec}`);
  const net = require('net');
  const upstream = m[1];
  const ports = m[2].split(',').map(Number).filter((p) => p > 0 && p < 65536);
  const listening = [];
  for (const port of ports) {
    for (const host of ['127.0.0.1', '::1']) {
      listening.push(new Promise((ok) => {
        const server = net.createServer((client) => {
          const up = net.connect(port, upstream);
          client.pipe(up);
          up.pipe(client);
          const end = () => { client.destroy(); up.destroy(); };
          client.on('error', end);
          up.on('error', end);
          client.on('close', end);
          up.on('close', end);
        });
        // ::1 may not exist in the container; 127.0.0.1 must.
        server.on('error', (e) => (host === '::1' ? ok(null) : fail(`relay ${host}:${port}: ${e.message}`)));
        server.listen(port, host, () => ok(`${host}:${port}`));
      }));
    }
  }
  return Promise.all(listening).then((l) => {
    console.error(`webkit-window: loopback relay ${l.filter(Boolean).join(' ')} -> ${upstream}`);
  });
}

(async () => {
  await startRelay(process.env.TILLANDSIAS_WEBKIT_RELAY);
  const browser = await webkit.launch({ headless: false });
  const context = await browser.newContext({
    viewport: device.viewport,
    deviceScaleFactor: device.deviceScaleFactor,
    isMobile: device.isMobile,
    hasTouch: device.hasTouch,
    userAgent: device.userAgent,
  });
  const page = await context.newPage();
  const done = () => process.exit(0);
  page.on('close', done);
  browser.on('disconnected', done);
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => browser.close().finally(done));
  }
  try {
    const response = await page.goto(url, { waitUntil: 'load', timeout: 60000 });
    console.error(`webkit-window: loaded ${url} status=${response ? response.status() : 'none'}`);
  } catch (e) {
    // The window stays open on WebKit's own error page; the tray reads this line.
    console.error(`webkit-window: navigation to ${url} failed: ${String(e.message || e).split('\n')[0]}`);
  }
})().catch((e) => {
  // The whole message: Playwright puts the browser's own log after line 1.
  fail(String(e && e.message ? e.message : e).split('\n').slice(0, 40).join('\n'));
});
