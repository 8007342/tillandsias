// @trace order:1861-nmpp
// GrapesJS studio server: serves the editor and the vendored core, and is the
// editor's remote storage endpoint. Writes only inside STUDIO_PROJECT:
//   index.html               the page (body HTML, linking styles.css)
//   styles.css               the page CSS
//   .grapesjs/project.json   GrapesJS project data, so a reload resumes
// The checkout is a git work tree, so a store shows up as a repo diff.
// No network access is needed or attempted.
import { createServer } from "node:http";
import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { join, normalize, extname } from "node:path";

const PROJECT = process.env.STUDIO_PROJECT || "/project";
const PORT = Number(process.env.STUDIO_PORT || 8090);
const HERE = "/opt/studio";
const VENDOR = join(HERE, "vendor", "grapesjs");
const MAX_BODY = 8 * 1024 * 1024;
const TYPES = { ".js": "text/javascript", ".css": "text/css", ".html": "text/html; charset=utf-8" };

async function atomicWrite(path, text) {
  const tmp = `${path}.studio-tmp`;
  await writeFile(tmp, text);
  await rename(tmp, path);
}

function page(html) {
  return `<!doctype html>\n<html>\n<head>\n<meta charset="utf-8">\n<link rel="stylesheet" href="styles.css">\n</head>\n<body>\n${html}\n</body>\n</html>\n`;
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > MAX_BODY) throw Object.assign(new Error("body too large"), { status: 413 });
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function send(res, status, body, type = "application/json") {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

async function load() {
  try {
    const projectData = JSON.parse(await readFile(join(PROJECT, ".grapesjs", "project.json"), "utf8"));
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

async function store(raw) {
  const data = JSON.parse(raw);
  if (typeof data.html !== "string" || typeof data.css !== "string") {
    throw Object.assign(new Error("store wants {html, css, projectData}"), { status: 400 });
  }
  await mkdir(join(PROJECT, ".grapesjs"), { recursive: true });
  await atomicWrite(join(PROJECT, "index.html"), page(data.html));
  await atomicWrite(join(PROJECT, "styles.css"), data.css.endsWith("\n") ? data.css : data.css + "\n");
  await atomicWrite(join(PROJECT, ".grapesjs", "project.json"), JSON.stringify(data.projectData ?? {}, null, 2) + "\n");
  return { ok: true, wrote: ["index.html", "styles.css", ".grapesjs/project.json"] };
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
    if (req.method === "POST" && url.pathname === "/store") return send(res, 200, await store(await readBody(req)));
    if (req.method === "GET" && url.pathname === "/healthz") return send(res, 200, { ok: true });
    send(res, 404, { error: "not found" });
  } catch (err) {
    send(res, err.status || 500, { error: String(err.message || err) });
  }
}).listen(PORT, "0.0.0.0", () => console.log(`ok:web-studio-grapesjs:listening:${PORT}:project=${PROJECT}`));
