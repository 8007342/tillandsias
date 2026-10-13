// The browser window's CDP relay (order 1655-urz9), run as the window
// container's entrypoint: `node -e <this> -- <chromium args>`.
//
// Chromium runs with --remote-debugging-pipe, so DevTools is the child's fds
// 3 (commands in) and 4 (replies and events out), NUL-framed JSON, and there
// is NO DevTools port, in the container or on the host. This relay serves
// that pipe on a Unix socket in a per-window directory only the tray mounts
// (TILLANDSIAS_CDP_SOCKET), for exactly ONE client: the tray's broker.
//
// - A second connection is refused while the first is attached.
// - The broker's session is the window's lifetime: when it disconnects, the
//   relay ends Chromium and the container exits, so emulation overrides can
//   never outlive the session that set them.
// - When Chromium exits, the relay exits with its status.
'use strict';
const net = require('net');
const fs = require('fs');
const { spawn } = require('child_process');

const SOCKET = process.env.TILLANDSIAS_CDP_SOCKET;
const LAUNCH = '/usr/local/bin/chromium-framework-launch.sh';
if (!SOCKET) {
  console.error('cdp relay: TILLANDSIAS_CDP_SOCKET is not set');
  process.exit(2);
}
let args = process.argv.slice(1);
if (args[0] === '--') args = args.slice(1);

const chromium = spawn(LAUNCH, [...args, '--remote-debugging-pipe'], {
  stdio: ['ignore', 'inherit', 'inherit', 'pipe', 'pipe'],
});
const toChromium = chromium.stdio[3];
const fromChromium = chromium.stdio[4];
// Nothing is read from Chromium until the broker attaches: the pipe buffers.
fromChromium.pause();

let client = null;
try { fs.unlinkSync(SOCKET); } catch (_) { /* absent */ }
const server = net.createServer((socket) => {
  if (client) {
    socket.destroy();
    return;
  }
  client = socket;
  server.close();
  try { fs.unlinkSync(SOCKET); } catch (_) { /* gone */ }
  fromChromium.pipe(socket);
  socket.pipe(toChromium);
  const end = () => {
    if (chromium.exitCode === null) chromium.kill('SIGTERM');
  };
  socket.on('close', end);
  socket.on('error', end);
});
server.listen(SOCKET, () => {
  fs.chmodSync(SOCKET, 0o600);
  console.error(`cdp relay: serving the DevTools pipe on ${SOCKET}`);
});

chromium.on('exit', (code, signal) => {
  if (client) client.destroy();
  server.close();
  try { fs.unlinkSync(SOCKET); } catch (_) { /* gone */ }
  process.exit(code === null ? (signal === 'SIGTERM' ? 0 : 1) : code);
});
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => chromium.kill('SIGTERM'));
}
