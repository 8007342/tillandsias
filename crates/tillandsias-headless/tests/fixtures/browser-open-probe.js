// Order 1649-xqet live probe, run INSIDE a browser.open window container by
// `browser_open::tests::live_browser_open_runs_the_container_on_its_own_network`
// (`podman exec -i <window> node -`). Prints one `<label> <verdict>` line per
// check. Inputs come from the environment the test passes with `-e`.
'use strict';
const net = require('net');
const dns = require('dns');
const https = require('https');

const PORT = process.env.PROBE_PREVIEW_PORT;
const HOST_IP = process.env.PROBE_HOST_IP;
const OTHER_UPSTREAM = process.env.PROBE_OTHER_UPSTREAM;

const fs = require('fs');
const { spawnSync } = require('child_process');

// The window has no DevTools port (no host listener, by design). Chromium-
// level checks run a headless Chromium IN THIS container with the WINDOW'S
// OWN resolver rules and CA pin, read from its command line.
function windowFlags() {
  for (const pid of fs.readdirSync('/proc').filter((p) => /^\d+$/.test(p))) {
    let argv;
    try { argv = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0'); } catch { continue; }
    const rules = argv.find((a) => a.startsWith('--host-resolver-rules='));
    const pin = argv.find((a) => a.startsWith('--ignore-certificate-errors-spki-list='));
    if (rules && pin) return [rules, pin];
  }
  return [];
}
const FLAGS = windowFlags();

function tcp(label, host, port) {
  return new Promise((resolve) => {
    const done = (v) => { console.log(`${label} ${v}`); resolve(); };
    dns.lookup(host, (err, addr) => {
      if (err) return done(`unresolved:${err.code}`);
      const s = net.connect({ host: addr, port: Number(port), timeout: 3000 });
      s.on('connect', () => { s.destroy(); done(`reach:${addr}`); });
      s.on('timeout', () => { s.destroy(); done(`timeout:${addr}`); });
      s.on('error', (e) => done(`unreachable:${addr}:${e.code}`));
    });
  });
}


// Order 1651-5t7n: a process in this container that bypasses Chromium's
// resolver must still reach only its own project. `sni` is the TLS server
// name, `host` the HTTP Host header; the router routes by Host across every
// project, so both must be bound to this window's project.
function rawRouter(label, sni, host) {
  return new Promise((resolve) => {
    const req = https.request({ host: 'router', port: 8443, path: '/', servername: sni,
      headers: { host }, rejectUnauthorized: false, timeout: 4000 }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => {
        const m = body.match(/<title>([^<]*)<\/title>/);
        console.log(`${label} status=${res.statusCode} title=${JSON.stringify(m ? m[1] : null)}`);
        resolve();
      });
    });
    req.on('error', (e) => { console.log(`${label} error=${e.code}`); resolve(); });
    req.end();
  });
}


function browse(label, url) {
  const r = spawnSync('/usr/local/bin/chromium-framework-launch.sh',
    ['--headless=new', '--disable-gpu', `--user-data-dir=/tmp/probe-${label}`, ...FLAGS,
     '--virtual-time-budget=4000', '--dump-dom', url], { encoding: 'utf8', timeout: 40000 });
  const m = (r.stdout || '').match(/<title>([^<]*)<\/title>/);
  const err = ((r.stderr || '').match(/ERR_[A-Z_]+/) || [null])[0];
  console.log(`${label} title=${JSON.stringify(m ? m[1] : null)} error=${err}`);
}

(async () => {
  console.log(`window-flags ${FLAGS.length === 2 ? 'found' : 'MISSING'}`);
  browse('chromium-preview-route', `https://www.demo.localhost:${PORT}/`);
  browse('chromium-http-route', 'http://web.demo.localhost:8080/');
  browse('chromium-other-project', `https://www.other.localhost:${PORT}/`);
  browse('chromium-external-name', 'https://example.com/');
  browse('chromium-external-ip', 'http://1.1.1.1/');
  browse('chromium-host-ip', `http://${HOST_IP}:5355/`);
  await tcp('net-route', 'router', 8443);
  await tcp('net-other-project-upstream', OTHER_UPSTREAM, 3000);
  await tcp('net-external-name', 'example.com', 443);
  await tcp('net-external-ip', '1.1.1.1', 443);
  await tcp('net-host-lan', HOST_IP, 5355);
  await tcp('net-host-containers-internal', 'host.containers.internal', 8080);
  await rawRouter('raw-own-project', 'www.demo.localhost', 'www.demo.localhost');
  await rawRouter('raw-sni-other-project', 'www.other.localhost', 'www.other.localhost');
  await rawRouter('raw-host-other-project', 'www.demo.localhost', 'www.other.localhost');
  await tcp('net-router-plaintext', 'router', 8080);
})();
