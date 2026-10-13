// Development / portable container server. Enclave publication must use
// host-browser publish_local, which owns sibling lifecycle and local routing.
import { createServer } from 'node:http';
import { readFile, stat, realpath } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = await realpath(resolve(fileURLToPath(new URL('..', import.meta.url)), 'build/web'));
const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf', '.woff2': 'font/woff2', '.ico': 'image/x-icon' };
createServer(async (req, res) => {
  if (!['GET', 'HEAD'].includes(req.method)) { res.writeHead(405); res.end(); return; }
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://preview').pathname);
    let path = resolve(root, `.${pathname}`);
    if (path !== root && !path.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
    try { if ((await stat(path)).isDirectory()) path = resolve(path, 'index.html'); }
    catch {
      if (!req.headers.accept?.includes('text/html')) { res.writeHead(404); res.end(); return; }
      path = resolve(root, 'index.html');
    }
    const canonical = await realpath(path);
    if (!canonical.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
    const body = await readFile(canonical);
    res.writeHead(200, { 'Content-Type': types[extname(path)] || 'application/octet-stream',
      'Cache-Control': pathname.startsWith('/data/') ? 'public, max-age=60, must-revalidate' : 'no-cache' });
    res.end(req.method === 'HEAD' ? undefined : body);
  } catch { res.writeHead(404); res.end(); }
}).listen(Number(process.env.PORT || 8080), '0.0.0.0');
