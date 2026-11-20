// @trace order:1864-ay3x
// Puck studio server, the UPSTREAM behind the studio front
// (images/studio/studio-front.js). Puck is a React component with no server
// of its own; this serves the editor bundle and the stored page data, and
// writes nothing: the editor's onPublish posts the page data to the front's
// /__studio/save, which guards the path against the registry allowlist for
// puck (.tillandsias/studio/puck/**) and commits it. No network access.
//
//   GET  /healthz                 200
//   GET  /                        the editor page
//   GET  /editor.js, /editor.css  the bundle built in the discarded builder stage
//   GET  /__studio/load?path=P    the stored page data at P, or {} when none;
//                                 P must be a .json under .tillandsias/studio/puck/
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, normalize, isAbsolute, extname, sep } from "node:path";
import { existsSync } from "node:fs";

const PROJECT = process.env.STUDIO_PROJECT || "/project";
const HOST = process.env.STUDIO_HOST || "127.0.0.1";
const PORT = Number(process.env.STUDIO_PORT || 4097);
const HERE = process.env.STUDIO_HERE || "/opt/studio/puck";
const SITE_PUBLIC = process.env.STUDIO_PUCK_PUBLIC;
const PUBLIC = normalize(SITE_PUBLIC && existsSync(join(SITE_PUBLIC, "editor.html")) ? SITE_PUBLIC : join(HERE, "public"));
const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".json": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
  ".webp": "image/webp", ".avif": "image/avif", ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf",
};
const PAGES = ".tillandsias/studio/puck/";

// A load reads the checkout, so it is held to the lane's own data.
function loadable(path) {
  if (typeof path !== "string" || path === "" || isAbsolute(path)) return null;
  const n = normalize(path);
  if (n.split("/").includes("..") || !n.startsWith(PAGES) || !n.endsWith(".json")) return null;
  return n;
}

function send(res, status, obj) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(obj));
}

createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://studio");
    if (req.method === "GET" && url.pathname === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      return res.end("ok\n");
    }
    // 2110-pk4s: the editor built against the site's config (build-site.mjs,
    // outside the checkout) when there is one, else the image's demo editor.
    // Any file of that build (editor.js/.css, puck.css, assets/) is served.
    if (req.method === "GET" && url.pathname !== "/__studio/load") {
      const file = url.pathname === "/" ? "editor.html" : decodeURIComponent(url.pathname.slice(1));
      const full = normalize(join(PUBLIC, file));
      if (!full.startsWith(PUBLIC + sep)) return send(res, 404, { error: "not found" });
      let body;
      try { body = await readFile(full); } catch {
        // The site's own public files (its url("/assets/…")), read-only, as the
        // live site serves them; the editor build always wins.
        const site = normalize(join(PROJECT, "public"));
        const alt = normalize(join(site, file));
        if (!alt.startsWith(site + sep)) return send(res, 404, { error: "not found" });
        try { body = await readFile(alt); } catch { return send(res, 404, { error: "not found" }); }
        res.writeHead(200, { "content-type": TYPES[extname(alt)] || "application/octet-stream", "cache-control": "no-store" });
        return res.end(body);
      }
      res.writeHead(200, { "content-type": TYPES[extname(full)] || "application/octet-stream", "cache-control": "no-store" });
      return res.end(body);
    }
    if (req.method === "GET" && url.pathname === "/__studio/load") {
      const rel = loadable(url.searchParams.get("path") || "");
      if (!rel) return send(res, 403, { error: `refused: loads are .json under ${PAGES}` });
      try {
        return send(res, 200, JSON.parse(await readFile(join(PROJECT, rel), "utf8")));
      } catch {
        return send(res, 200, {});
      }
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found\n");
  } catch (e) {
    send(res, e.status || 500, { error: e.message });
  }
}).listen(PORT, HOST, () => console.log(`puck studio on ${HOST}:${PORT}`));
