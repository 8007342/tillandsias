// @trace order:1861-nmpp, order:2108-dptd
// GrapesJS studio server, the UPSTREAM behind the studio front
// (images/studio/studio-front.js). It serves the editor, the vendored core and
// the page to load, and writes nothing: every save goes through the front's
// /__studio/save, which guards the path and commits it.
//
// 2108-dptd: the page is the SITE's page, not a root index.html. Its directory
// (the document root) is, in order: wrangler's assets.directory
// (wrangler.jsonc / wrangler.json), else STUDIO_APP_DIR (the preview's
// app_dir), else the repo root. /load answers the root and the page's full
// text, so the editor replaces only what is inside <body> and keeps every byte
// outside it. On a save the editor sends, one path at a time:
//   <root>/index.html                          the page, outside <body> unchanged
//   <root>/studio.css                          only when the editor's CSS changed
//   .tillandsias/studio/grapesjs/project.json  GrapesJS project data
// No network access is needed or attempted.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { join, normalize, extname, posix } from "node:path";

const PROJECT = process.env.STUDIO_PROJECT || "/project";
const HOST = process.env.STUDIO_HOST || "127.0.0.1";
const PORT = Number(process.env.STUDIO_PORT || 4097);
const HERE = process.env.STUDIO_HERE || "/opt/studio/grapesjs";
const VENDOR = join(HERE, "vendor");
const TYPES = {
  ".js": "text/javascript", ".css": "text/css", ".html": "text/html; charset=utf-8",
  ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".eot": "application/vnd.ms-fontobject",
  ".svg": "image/svg+xml", ".otf": "font/otf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".gif": "image/gif", ".webp": "image/webp", ".avif": "image/avif", ".ico": "image/x-icon", ".json": "application/json",
};

// JSONC: drop // and /* */ comments outside strings, then trailing commas.
export function stripJsonc(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j;
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      out += "\n";
    } else if (c === "/" && text[i + 1] === "*") {
      i += 2;
      while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++;
      i++;
    } else {
      out += c;
    }
  }
  return out.replace(/,(\s*[}\]])/g, "$1");
}

// A relative, inside-the-repo directory, '/'-separated, or null.
function cleanDir(d) {
  if (typeof d !== "string" || d === "") return null;
  const p = posix.normalize(d.replace(/\\/g, "/")).replace(/^\.\/+/, "").replace(/\/+$/, "");
  if (p === "." || p === "") return ".";
  if (p.startsWith("/") || p === ".." || p.startsWith("../") || /^[A-Za-z]:/.test(p)) return null;
  return p;
}

export function resolveRoot(project, env = process.env) {
  for (const name of ["wrangler.jsonc", "wrangler.json"]) {
    let text;
    try { text = readFileSync(join(project, name), "utf8"); } catch { continue; }
    try {
      const dir = cleanDir(JSON.parse(stripJsonc(text))?.assets?.directory);
      if (dir) return { root: dir, from: name };
    } catch {}
  }
  const app = cleanDir(env.STUDIO_APP_DIR);
  if (app) return { root: app, from: "app_dir" };
  return { root: ".", from: "repo-root" };
}

export const pagePath = (root) => (root === "." ? "index.html" : `${root}/index.html`);

// The page split at its <body>: everything before the open tag's end, the
// inner HTML, and everything from </body> on. A page with no <body> is all body.
export function splitPage(doc) {
  const open = doc.match(/<body\b[^>]*>/i);
  const close = doc.match(/<\/body\s*>(?![\s\S]*<\/body\s*>)/i);
  if (!open || !close || close.index < open.index + open[0].length) return { before: "", inner: doc, after: "", whole: false };
  const start = open.index + open[0].length;
  return { before: doc.slice(0, start), inner: doc.slice(start, close.index), after: doc.slice(close.index), whole: true };
}

export async function load(project = PROJECT, env = process.env) {
  const { root, from } = resolveRoot(project, env);
  const page = pagePath(root);
  let doc = null;
  try { doc = await readFile(join(project, page), "utf8"); } catch {}
  if (doc === null) return { root, root_from: from, page, exists: false, html: "", doc: "" };
  return { root, root_from: from, page, exists: true, html: splitPage(doc).inner, doc };
}

async function staticFile(res, root, rel) {
  const path = normalize(join(root, rel));
  if (!path.startsWith(root + "/")) return send(res, 404, { error: "not found" });
  try {
    const bytes = await readFile(path);
    res.writeHead(200, { "content-type": TYPES[extname(path)] || "application/octet-stream", "cache-control": "no-store" });
    res.end(bytes);
  } catch {
    send(res, 404, { error: "not found" });
  }
}

function send(res, status, body, type = "application/json") {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

export function start() {
  return createServer(async (req, res) => {
    const url = new URL(req.url, "http://studio");
    try {
      if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
        return send(res, 200, await readFile(join(HERE, "editor.html"), "utf8"), TYPES[".html"]);
      }
      if (req.method === "GET" && url.pathname === "/studio-page.js") {
        return send(res, 200, await readFile(join(HERE, "studio-page.js"), "utf8"), TYPES[".js"]);
      }
      // 2108-dptd: the site's own files (its stylesheets, images, fonts),
      // read-only from the document root, so the canvas renders the page as
      // it looks; the canvas resolves the page's relative URLs against /site/.
      if (req.method === "GET" && url.pathname.startsWith("/site/")) {
        const { root } = resolveRoot(PROJECT);
        const base = normalize(join(PROJECT, root));
        return staticFile(res, base, decodeURIComponent(url.pathname.slice("/site/".length)));
      }
      if (req.method === "GET" && url.pathname.startsWith("/vendor/")) {
        return staticFile(res, VENDOR, url.pathname.slice("/vendor/".length));
      }
      if (req.method === "GET" && url.pathname === "/load") return send(res, 200, await load());
      if (req.method === "GET" && url.pathname === "/healthz") return send(res, 200, { ok: true });
      // 2108-dptd: anything else GET is the site's own file at its own path,
      // read-only from the document root, so the canvas resolves the page's
      // relative AND root-absolute URLs (url("/assets/x.png")) as the live
      // site does. The editor's routes above always win.
      if (req.method === "GET") {
        const { root } = resolveRoot(PROJECT);
        return staticFile(res, normalize(join(PROJECT, root)), decodeURIComponent(url.pathname.slice(1)));
      }
      send(res, 404, { error: "not found" });
    } catch (err) {
      send(res, err.status || 500, { error: String(err.message || err) });
    }
  }).listen(PORT, HOST, () => console.log(`ok:studio-grapesjs:listening:${HOST}:${PORT}:project=${PROJECT}`));
}

if (import.meta.url === `file://${process.argv[1]}`) start();
