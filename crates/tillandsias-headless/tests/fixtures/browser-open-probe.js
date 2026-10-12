// Order 1649-xqet live probe, run INSIDE a browser.open window container by
// `browser_open::tests::live_browser_open_runs_the_container_on_its_own_network`
// (`podman exec -i <window> node -`). Prints one `<label> <verdict>` line per
// check. Inputs come from the environment the test passes with `-e`.
'use strict';
const net = require('net');
const dns = require('dns');
const http = require('http');
const https = require('https');

const PORT = process.env.PROBE_PREVIEW_PORT;
const HOST_IP = process.env.PROBE_HOST_IP;
const OTHER_UPSTREAM = process.env.PROBE_OTHER_UPSTREAM;

function devtools(method, path) {
  return new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port: 9222, method, path }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => {
        try { resolve(JSON.parse(body)); } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.end();
  });
}

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


// RESIDUAL, reported not asserted: a process in this container that bypasses
// Chromium's resolver can still name another project to the router, which
// routes by Host/SNI across every project.
function rawRouter(label, host) {
  return new Promise((resolve) => {
    const req = https.request({ host: 'router', port: 8443, path: '/', servername: host,
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Open a tab in THIS browser and report what it rendered: the title is the
// page's <title> when the route loaded, Chromium's error page otherwise.
async function browse(label, url) {
  const target = await devtools('PUT', `/json/new?${url}`);
  await sleep(4000);
  const list = (await devtools('GET', '/json/list')) || [];
  const seen = list.find((t) => target && t.id === target.id);
  console.log(`${label} title=${JSON.stringify(seen ? seen.title : null)}`);
}

(async () => {
  const pages = (await devtools('GET', '/json/list')) || [];
  const first = pages.find((t) => t.type === 'page');
  console.log(`window title=${JSON.stringify(first ? first.title : null)} url=${first ? first.url : null}`);
  await browse('chromium-http-route', 'http://web.demo.localhost:8080/');
  await browse('chromium-other-project', `https://www.other.localhost:${PORT}/`);
  await browse('chromium-external-name', 'https://example.com/');
  await browse('chromium-external-ip', 'http://1.1.1.1/');
  await browse('chromium-host-ip', `http://${HOST_IP}:5355/`);
  await tcp('net-route', 'router', 8443);
  await tcp('net-other-project-upstream', OTHER_UPSTREAM, 3000);
  await tcp('net-external-name', 'example.com', 443);
  await tcp('net-external-ip', '1.1.1.1', 443);
  await tcp('net-host-lan', HOST_IP, 5355);
  await tcp('net-host-containers-internal', 'host.containers.internal', 8080);
  await rawRouter('residual-raw-router-other-project', `www.other.localhost`);
})();
