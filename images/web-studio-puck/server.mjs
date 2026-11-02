// @trace order:1864-ay3x
// Puck studio server. Puck is a React component with no server of its own;
// its editor's onPublish hands the page data (JSON) to this server's shared
// write-back endpoint, which writes it into STUDIO_PROJECT, the forge's git
// checkout, ONLY under the lane's write allowlist (the studio registry's
// write_allowlist for puck, .tillandsias/studio/puck/**). A write anywhere
// else is refused with the rule that refused it. No network access.
//
//   GET  /healthz                 200
//   GET  /                        the editor page (when the bundle is built)
//   GET  /__studio/load?path=P    the stored page data at P, or {} when none
//   POST /__studio/save           {path, data}: write data as JSON at path
import { createServer } from "node:http";
import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { join, dirname, normalize, isAbsolute } from "node:path";

const PROJECT = process.env.STUDIO_PROJECT || "/project";
const PORT = Number(process.env.STUDIO_PORT || 8090);
const HERE = "/opt/studio";
const MAX_BODY = 8 * 1024 * 1024;
// The registry's allowlist for this lane; overridable so the launcher can
// pass the registry row instead of this copy.
const ALLOW = JSON.parse(process.env.STUDIO_WRITE_ALLOWLIST || '[".tillandsias/studio/puck/**"]');

// Glob over a checkout-relative path: ** spans directories, * stays in one.
function globRe(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") { re += ".*"; i++; }
    else if (c === "*") re += "[^/]*";
    else re += c.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}
const ALLOW_RE = ALLOW.map(globRe);

// The checkout-relative path a request may write, or the reason it may not.
export function allowed(path) {
  if (typeof path !== "string" || path === "") return { ok: false, why: "no path" };
  if (isAbsolute(path)) return { ok: false, why: "absolute path" };
  const n = normalize(path);
  if (n.startsWith("..") || n.split("/").includes("..")) return { ok: false, why: "path escapes the checkout" };
  if (!n.endsWith(".json")) return { ok: false, why: "page data is .json" };
  if (!ALLOW_RE.some((r) => r.test(n))) return { ok: false, why: `outside the lane allowlist ${JSON.stringify(ALLOW)}` };
  return { ok: true, rel: n };
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
      try {
        const body = await readFile(join(HERE, "public", file));
        const type = file.endsWith(".js") ? "text/javascript" : file.endsWith(".css") ? "text/css" : "text/html; charset=utf-8";
        res.writeHead(200, { "content-type": type });
        return res.end(body);
      } catch {
        res.writeHead(404, { "content-type": "text/plain" });
        return res.end("editor bundle not built in this image\n");
      }
    }
    if (req.method === "GET" && url.pathname === "/__studio/load") {
      const a = allowed(url.searchParams.get("path") || "");
      if (!a.ok) return send(res, 403, { error: `refused: ${a.why}` });
      try {
        return send(res, 200, JSON.parse(await readFile(join(PROJECT, a.rel), "utf8")));
      } catch {
        return send(res, 200, {});
      }
    }
    if (req.method === "POST" && url.pathname === "/__studio/save") {
      let msg;
      try {
        msg = JSON.parse(await readBody(req));
      } catch (e) {
        return send(res, e.status || 400, { error: e.status ? e.message : "body is not JSON" });
      }
      const a = allowed(msg?.path);
      if (!a.ok) return send(res, 403, { error: `refused: ${a.why}` });
      if (msg.data === undefined) return send(res, 400, { error: "no data" });
      const dest = join(PROJECT, a.rel);
      await mkdir(dirname(dest), { recursive: true });
      const tmp = `${dest}.studio-tmp`;
      await writeFile(tmp, `${JSON.stringify(msg.data, null, 2)}\n`);
      await rename(tmp, dest);
      return send(res, 200, { saved: a.rel });
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found\n");
  } catch (e) {
    send(res, e.status || 500, { error: e.message });
  }
}).listen(PORT, "0.0.0.0", () => console.log(`puck studio on :${PORT}, allowlist ${JSON.stringify(ALLOW)}`));
