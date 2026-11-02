// @trace order:1863-dmke
// TinaCMS studio server: starts `tinacms dev` in LOCAL mode (no Tina Cloud
// account, no telemetry) on the forge checkout at STUDIO_PROJECT, and is the
// only way in to it. tinacms dev binds its GraphQL server and data layer to
// loopback ([::1]:4001 and [::1]:9000, measured on yoga 2026-11-02); this
// front listens on STUDIO_PORT and forwards every request there. A save
// through the GraphQL endpoint writes the markdown file in the checkout, so
// it shows up as a repo diff. No network access is needed or attempted.
//
//   GET  /healthz   200 once Tina's GraphQL answers
//   *    anything   forwarded to tinacms dev (GraphQL at /graphql, the admin
//                   UI it serves at /admin/)
import { createServer, request } from "node:http";
import { spawn } from "node:child_process";
import { join } from "node:path";

const PROJECT = process.env.STUDIO_PROJECT || "/project";
const PORT = Number(process.env.STUDIO_PORT || 8090);
const TINA_PORT = Number(process.env.STUDIO_TINA_PORT || 4001);
const TINA_HOST = "::1";
const HERE = "/opt/studio";

const tina = spawn(
  process.execPath,
  [
    join(HERE, "node_modules", "@tinacms", "cli", "bin", "tinacms"),
    "dev",
    "--rootPath", PROJECT,
    "--noTelemetry",
    "--noWatch",
    "-p", String(TINA_PORT),
  ],
  {
    cwd: PROJECT,
    env: { PATH: process.env.PATH, HOME: process.env.HOME, NODE_ENV: "development" },
    stdio: ["ignore", "inherit", "inherit"],
  },
);
tina.on("exit", (code) => {
  console.error(`tinacms dev exited (${code}); the studio stops with it`);
  process.exit(1);
});

function tinaAnswers() {
  return new Promise((resolve) => {
    const body = Buffer.from(JSON.stringify({ query: "{__typename}" }));
    const r = request(
      { host: TINA_HOST, port: TINA_PORT, path: "/graphql", method: "POST",
        headers: { "content-type": "application/json", "content-length": body.length } },
      (res) => { res.resume(); resolve(res.statusCode === 200); },
    );
    r.on("error", () => resolve(false));
    r.end(body);
  });
}

createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    const ok = await tinaAnswers();
    res.writeHead(ok ? 200 : 503, { "content-type": "text/plain" });
    return res.end(ok ? "ok\n" : "tinacms dev not ready\n");
  }
  const headers = { ...req.headers, host: `[${TINA_HOST}]:${TINA_PORT}` };
  delete headers.origin;
  const up = request(
    { host: TINA_HOST, port: TINA_PORT, path: req.url, method: req.method, headers },
    (r) => {
      res.writeHead(r.statusCode || 502, r.headers);
      r.pipe(res);
    },
  );
  up.on("error", (e) => {
    res.writeHead(502, { "content-type": "text/plain" });
    res.end(`tinacms dev unreachable: ${e.message}\n`);
  });
  req.pipe(up);
}).listen(PORT, "0.0.0.0", () => console.log(`tina studio on :${PORT}, tinacms dev on [${TINA_HOST}]:${TINA_PORT}`));
