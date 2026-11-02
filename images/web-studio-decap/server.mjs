// @trace order:1862-wrx5
// Decap CMS studio server. Serves the Decap admin UI and the vendored
// decap-cms bundle, and is the ONLY way in to decap-server, which it starts
// as a child bound to loopback (@decap/cli's dev server binds 127.0.0.1 and
// ::1 unless BIND_HOST is set; this never sets it). decap-server runs in its
// "fs" mode, writing entries straight into STUDIO_PROJECT, the forge's git
// checkout, so a save shows up as a repo diff. No network access is needed
// or attempted.
//
//   GET  /healthz            200 once decap-server answers
//   GET  /  /admin/          the admin page
//   GET  /admin/decap-cms.js the vendored bundle
//   GET  /admin/config.yml   the project's admin/config.yml, with its backend
//                            pointed at this server; a Hugo default otherwise
//   POST /api/v1             forwarded to decap-server on loopback
import { createServer, request } from "node:http";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const PROJECT = process.env.STUDIO_PROJECT || "/project";
const PORT = Number(process.env.STUDIO_PORT || 8090);
const DECAP_PORT = Number(process.env.STUDIO_DECAP_PORT || 8081);
const HERE = "/opt/studio";
const BUNDLE = join(HERE, "vendor", "decap-cms", "dist", "decap-cms.js");
const MAX_BODY = 32 * 1024 * 1024;

// The backend every config gets: decap's "proxy" backend, pointed at this
// server's /api/v1, so the browser never talks to decap-server directly.
const BACKEND = "backend:\n  name: proxy\n  proxy_url: /api/v1\n  branch: main\n";

// A Hugo default when the project has no admin/config.yml of its own.
const DEFAULT_CONFIG = `${BACKEND}media_folder: static/images
public_folder: /images
collections:
  - name: posts
    label: Posts
    folder: content/posts
    create: true
    extension: md
    format: frontmatter
    fields:
      - { label: Title, name: title, widget: string }
      - { label: Date, name: date, widget: datetime }
      - { label: Body, name: body, widget: markdown }
`;

// The project's config with any backend block replaced by BACKEND.
function withOurBackend(yml) {
  const lines = yml.split("\n");
  const out = [];
  let skipping = false;
  for (const line of lines) {
    if (/^(backend|local_backend):/.test(line)) {
      skipping = true;
      continue;
    }
    if (skipping && (/^\s/.test(line) || line === "")) continue;
    skipping = false;
    out.push(line);
  }
  return BACKEND + out.join("\n");
}

const ADMIN = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Decap CMS studio</title>
</head>
<body>
<script src="/admin/decap-cms.js"></script>
</body>
</html>
`;

const decap = spawn(
  process.execPath,
  [join(HERE, "node_modules", "decap-server", "dist", "index.js")],
  {
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      MODE: "fs",
      GIT_REPO_DIRECTORY: PROJECT,
      PORT: String(DECAP_PORT),
      LOG_LEVEL: "warn",
    },
    stdio: ["ignore", "inherit", "inherit"],
  },
);
decap.on("exit", (code) => {
  console.error(`decap-server exited (${code}); the studio stops with it`);
  process.exit(1);
});

function forward(req, res, body) {
  const up = request(
    {
      host: "127.0.0.1",
      port: DECAP_PORT,
      path: "/api/v1",
      method: "POST",
      // No Origin: decap-server's CORS allows localhost origins only, and
      // this hop is server-side.
      headers: { "content-type": "application/json", "content-length": body.length },
    },
    (r) => {
      res.writeHead(r.statusCode || 502, { "content-type": r.headers["content-type"] || "application/json" });
      r.pipe(res);
    },
  );
  up.on("error", (e) => {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: `decap-server unreachable: ${e.message}` }));
  });
  up.end(body);
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > MAX_BODY) throw Object.assign(new Error("body too large"), { status: 413 });
    chunks.push(c);
  }
  return Buffer.concat(chunks);
}

function decapAnswers() {
  return new Promise((resolve) => {
    const body = Buffer.from(JSON.stringify({ action: "info", params: {} }));
    const r = request(
      { host: "127.0.0.1", port: DECAP_PORT, path: "/api/v1", method: "POST",
        headers: { "content-type": "application/json", "content-length": body.length } },
      (res) => { res.resume(); resolve(res.statusCode === 200); },
    );
    r.on("error", () => resolve(false));
    r.end(body);
  });
}

createServer(async (req, res) => {
  try {
    const path = new URL(req.url, "http://studio").pathname;
    if (req.method === "GET" && path === "/healthz") {
      const ok = await decapAnswers();
      res.writeHead(ok ? 200 : 503, { "content-type": "text/plain" });
      return res.end(ok ? "ok\n" : "decap-server not ready\n");
    }
    if (req.method === "GET" && (path === "/" || path === "/admin" || path === "/admin/")) {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return res.end(ADMIN);
    }
    if (req.method === "GET" && path === "/admin/decap-cms.js") {
      res.writeHead(200, { "content-type": "text/javascript" });
      return res.end(await readFile(BUNDLE));
    }
    if (req.method === "GET" && path === "/admin/config.yml") {
      let yml;
      try {
        yml = withOurBackend(await readFile(join(PROJECT, "admin", "config.yml"), "utf8"));
      } catch {
        yml = DEFAULT_CONFIG;
      }
      res.writeHead(200, { "content-type": "text/yaml; charset=utf-8" });
      return res.end(yml);
    }
    if (req.method === "POST" && path === "/api/v1") {
      return forward(req, res, await readBody(req));
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found\n");
  } catch (e) {
    res.writeHead(e.status || 500, { "content-type": "text/plain" });
    res.end(`${e.message}\n`);
  }
}).listen(PORT, "0.0.0.0", () => console.log(`decap studio on :${PORT}, decap-server on 127.0.0.1:${DECAP_PORT}`));
