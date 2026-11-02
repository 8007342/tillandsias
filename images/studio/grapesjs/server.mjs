// @trace order:1861-nmpp
// GrapesJS studio server, the UPSTREAM behind the studio front
// (images/studio/studio-front.js). It serves the editor, the vendored core and
// the page to load, and writes nothing: every save goes through the front's
// /__studio/save, which guards the path and commits it. On a save the editor
// sends, one path at a time:
//   index.html                                 the page (body HTML, linking styles.css)
//   styles.css                                 the page CSS
//   .tillandsias/studio/grapesjs/project.json  GrapesJS project data, so a reload resumes
// No network access is needed or attempted.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, normalize, extname } from "node:path";

const PROJECT = process.env.STUDIO_PROJECT || "/project";
const HOST = process.env.STUDIO_HOST || "127.0.0.1";
const PORT = Number(process.env.STUDIO_PORT || 4097);
const HERE = "/opt/studio/grapesjs";
const VENDOR = join(HERE, "vendor");
const PROJECT_DATA = join(".tillandsias", "studio", "grapesjs", "project.json");
const TYPES = { ".js": "text/javascript", ".css": "text/css", ".html": "text/html; charset=utf-8" };

function send(res, status, body, type = "application/json") {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

async function load() {
  try {
    const projectData = JSON.parse(await readFile(join(PROJECT, PROJECT_DATA), "utf8"));
    // A project with no pages is not a project: fall back to the page itself.
    if (Array.isArray(projectData.pages) && projectData.pages.length > 0) return { projectData };
    throw new Error("no pages");
  } catch {
    let html = "";
    try {
      html = await readFile(join(PROJECT, "index.html"), "utf8");
    } catch {}
    const body = html.match(/<body[^>]*>([\s\S]*)<\/body>/i);
    return { html: body ? body[1] : html };
  }
}

async function staticFile(res, root, rel) {
  const path = normalize(join(root, rel));
  if (!path.startsWith(root + "/")) return send(res, 404, { error: "not found" });
  try {
    send(res, 200, await readFile(path, "utf8"), TYPES[extname(path)] || "application/octet-stream");
  } catch {
    send(res, 404, { error: "not found" });
  }
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://studio");
  try {
    if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
      return send(res, 200, await readFile(join(HERE, "editor.html"), "utf8"), TYPES[".html"]);
    }
    if (req.method === "GET" && url.pathname.startsWith("/vendor/")) {
      return staticFile(res, VENDOR, url.pathname.slice("/vendor/".length));
    }
    if (req.method === "GET" && url.pathname === "/load") return send(res, 200, await load());
    if (req.method === "GET" && url.pathname === "/healthz") return send(res, 200, { ok: true });
    send(res, 404, { error: "not found" });
  } catch (err) {
    send(res, err.status || 500, { error: String(err.message || err) });
  }
}).listen(PORT, HOST, () => console.log(`ok:studio-grapesjs:listening:${HOST}:${PORT}:project=${PROJECT}`));
