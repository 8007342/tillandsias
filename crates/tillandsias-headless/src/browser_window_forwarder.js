// @trace spec:host-browser-mcp, spec:local-web-preview
// Order 1651-5t7n: the only thing a browser.open window's network can reach.
//
// It answers as `router` on the window's --internal network and passes a
// connection on ONLY when it opens with a TLS ClientHello whose SNI is a host
// of this window's project (*.<project>.localhost). The bytes then go,
// untouched, to the router's :8443 on the enclave network, and the router's
// strict_sni_host makes the Host header match that SNI. Plaintext, a missing
// SNI, another project's SNI or a malformed hello closes the connection.
// Run as `node -e` from the chromium-framework image; inputs come from env.
'use strict';
const net = require('net');

const suffix = `.${process.env.TILLANDSIAS_FWD_PROJECT}.localhost`.toLowerCase();
const upstreamHost = process.env.TILLANDSIAS_FWD_UPSTREAM_HOST;
const upstreamPort = Number(process.env.TILLANDSIAS_FWD_UPSTREAM_PORT || 8443);
const MAX_HELLO = 5 + 16384;

// null: need more bytes. { name }: the SNI host name, or undefined if none.
function serverName(buf) {
  if (buf.length < 5) return null;
  if (buf[0] !== 0x16) return { name: undefined };
  const recordEnd = 5 + buf.readUInt16BE(3);
  if (buf.length < recordEnd) return null;
  const rec = buf.subarray(0, recordEnd);
  let p = 5;
  if (rec[p] !== 0x01) return { name: undefined };
  p += 4 + 2 + 32;
  p += 1 + rec[p];
  p += 2 + rec.readUInt16BE(p);
  p += 1 + rec[p];
  const extEnd = p + 2 + rec.readUInt16BE(p);
  p += 2;
  while (p + 4 <= extEnd) {
    const type = rec.readUInt16BE(p);
    const len = rec.readUInt16BE(p + 2);
    p += 4;
    if (type === 0) {
      const listEnd = p + 2 + rec.readUInt16BE(p);
      let q = p + 2;
      while (q + 3 <= listEnd) {
        const nameType = rec[q];
        const nameLen = rec.readUInt16BE(q + 1);
        q += 3;
        if (nameType === 0) return { name: rec.toString('ascii', q, q + nameLen) };
        q += nameLen;
      }
    }
    p += len;
  }
  return { name: undefined };
}

net
  .createServer((client) => {
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => client.destroy(), 5000);
    client.on('error', () => client.destroy());
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      let hello;
      try {
        hello = serverName(buf);
      } catch {
        hello = { name: undefined };
      }
      if (hello === null) {
        if (buf.length > MAX_HELLO) client.destroy();
        return;
      }
      client.removeListener('data', onData);
      client.pause();
      clearTimeout(timer);
      const name = (hello.name || '').toLowerCase();
      if (!name.endsWith(suffix)) {
        console.log(`refused sni=${JSON.stringify(hello.name === undefined ? null : hello.name)}`);
        client.destroy();
        return;
      }
      const upstream = net.connect(upstreamPort, upstreamHost, () => {
        upstream.write(buf);
        client.pipe(upstream);
        upstream.pipe(client);
      });
      upstream.on('error', () => client.destroy());
      upstream.on('close', () => client.destroy());
      client.on('close', () => upstream.destroy());
    };
    client.on('data', onData);
  })
  .listen(8443, '0.0.0.0', () => console.log(`forwarder ${suffix} -> ${upstreamHost}:${upstreamPort}`));
