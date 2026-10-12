// @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration
// Order 1649-xqet: entry point for browser.open windows.
//
// A browser.open window runs on a per-launch --internal network, so the host
// can reach its DevTools port only through a port published from this
// container. Chromium binds that port to 127.0.0.1 inside the container
// whatever --remote-debugging-address says (measured 2026-10-12: listener
// 127.0.0.1:9222 with --remote-debugging-address=0.0.0.0). This relays
// 0.0.0.0:$TILLANDSIAS_CDP_RELAY_PORT to 127.0.0.1:$TILLANDSIAS_CDP_PORT, then
// runs the normal launcher with the same arguments and exits with it.
'use strict';
const net = require('net');
const { spawn } = require('child_process');

const relayPort = Number(process.env.TILLANDSIAS_CDP_RELAY_PORT || 0);
const cdpPort = Number(process.env.TILLANDSIAS_CDP_PORT || 9222);

if (relayPort > 0) {
  net
    .createServer((client) => {
      const upstream = net.connect(cdpPort, '127.0.0.1');
      client.pipe(upstream);
      upstream.pipe(client);
      client.on('error', () => upstream.destroy());
      upstream.on('error', () => client.destroy());
    })
    .listen(relayPort, '0.0.0.0');
}

const child = spawn('/usr/local/bin/chromium-framework-launch.sh', process.argv.slice(2), {
  stdio: 'inherit',
});
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => child.kill(signal));
}
child.on('exit', (code, signal) => process.exit(code === null ? (signal ? 143 : 1) : code));
