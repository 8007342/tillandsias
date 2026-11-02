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
import { join, normalize, isAbsolute } from "node:path";

const PROJECT = process.env.STUDIO_PROJECT || "/project";
const HOST = process.env.STUDIO_HOST || "127.0.0.1";
const PORT = Number(process.env.STUDIO_PORT || 4097);
const HERE = "/opt/studio/puck";
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
    if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/editor.js" || url.pathname === "/editor.css")) {
      const file = url.pathname === "/" ? "editor.html" : url.pathname.slice(1);
      const body = await readFile(join(HERE, "public", file));
      const type = file.endsWith(".js") ? "text/javascript" : file.endsWith(".css") ? "text/css" : "text/html; charset=utf-8";
      res.writeHead(200, { "content-type": type });
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
