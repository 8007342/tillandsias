// @trace order:2110-pk4s, spec:web-studio-lane
// Build the Puck editor against the SITE's own puck.config and deps, at studio
// start, entirely outside the checkout. Without a site config this does
// nothing and the studio serves the image's demo editor.
//
//   node build-site.mjs <checkout>     prints one verdict line:
//     ok:studio-puck:site-build:<public dir>
//     skip:studio-puck:site-build:no-site-config
//     refused:studio-puck:site-build:<why>          (the studio then serves the demo)
//
// Steps: copy the site's package.json (+ lockfile) to a cache dir keyed by
// their hash; install the site's deps there (npm ci when locked, scripts off);
// install the pinned bundler beside them (a separate prefix: the operator's
// 2026-11-02 ruling keeps esbuild out of the IMAGE, so it is fetched here, at
// build time of the editor, like the site's own deps); bundle editor.jsx with
// "studio-config" = the site's config and "studio-puck" = the site's Puck
// package. Nothing is written under the checkout.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync } from "node:fs";
import { join, resolve, isAbsolute, relative, sep } from "node:path";
import { homedir } from "node:os";
import { pathToFileURL } from "node:url";

export const ESBUILD = "esbuild@0.28.2";
export const CONFIG_CANDIDATES = [
  "src/puck.config.tsx", "src/puck.config.jsx", "src/puck.config.ts", "src/puck.config.js",
  "puck.config.tsx", "puck.config.jsx", "puck.config.ts", "puck.config.js",
];
export const PUCK_PACKAGES = ["@puckeditor/core", "@measured/puck"];
// The site's page CSS for the canvas: a site usually imports it from its render
// entry, not from its Puck config, so the config alone does not bring it.
// STUDIO_PUCK_CSS (comma-separated, inside the checkout) overrides.
export const CSS_CANDIDATES = ["src/styles.css", "src/index.css", "src/main.css", "src/global.css", "src/globals.css", "src/App.css"];
export function siteCss(checkout, env = process.env) {
  const list = env.STUDIO_PUCK_CSS ? env.STUDIO_PUCK_CSS.split(",").map((s) => s.trim()).filter(Boolean) : CSS_CANDIDATES;
  return list.filter((c) => {
    const rel = relative(checkout, resolve(checkout, c));
    return !isAbsolute(c) && !rel.startsWith("..") && existsSync(join(checkout, c));
  });
}

// The site's config, relative to the checkout, or null. STUDIO_PUCK_CONFIG
// overrides, held inside the checkout.
export function findConfig(checkout, env = process.env) {
  if (env.STUDIO_PUCK_CONFIG) {
    const p = env.STUDIO_PUCK_CONFIG;
    const abs = resolve(checkout, p);
    const rel = relative(checkout, abs);
    if (isAbsolute(p) || rel.startsWith("..") || !existsSync(abs)) return null;
    return rel.replace(/\\/g, "/");
  }
  return CONFIG_CANDIDATES.find((c) => existsSync(join(checkout, c))) || null;
}

// The site's Puck package name, from its package.json dependencies.
export function puckPackage(pkgJson) {
  const deps = { ...(pkgJson.dependencies || {}), ...(pkgJson.devDependencies || {}) };
  return PUCK_PACKAGES.find((p) => deps[p]) || null;
}

export function cacheDir(checkout, env = process.env) {
  const h = createHash("sha256");
  for (const f of ["package.json", "package-lock.json"]) {
    h.update(f + "\0");
    try { h.update(readFileSync(join(checkout, f))); } catch {}
  }
  const base = env.STUDIO_PUCK_CACHE || join(env.XDG_CACHE_HOME || join(homedir(), ".cache"), "tillandsias-studio", "puck");
  return join(base, h.digest("hex").slice(0, 16));
}

// Refuse a cache inside the checkout: the studio's build never lands there.
export function outsideCheckout(dir, checkout) {
  const rel = relative(resolve(checkout), resolve(dir));
  return rel.startsWith("..") || isAbsolute(rel);
}

export function puckCss(appModules, pkg) {
  for (const f of ["dist/index.css", "puck.css", "dist/puck.css"]) {
    const p = join(appModules, pkg, f);
    if (existsSync(p)) return p;
  }
  return null;
}

const HTML = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Puck studio</title>
<link rel="stylesheet" href="/puck.css">
<script>window.__STUDIO_SITE_CSS = ["/editor.css", "/site.css"];</script>
</head>
<body>
<div id="puck"></div>
<script src="/editor.js"></script>
</body>
</html>
`;

export async function build(checkout, env = process.env, run = execFileSync) {
  const config = findConfig(checkout, env);
  if (!config) return "skip:studio-puck:site-build:no-site-config";
  let pkgJson;
  try { pkgJson = JSON.parse(readFileSync(join(checkout, "package.json"), "utf8")); } catch {
    return "refused:studio-puck:site-build:no-package-json";
  }
  const pkg = puckPackage(pkgJson);
  if (!pkg) return `refused:studio-puck:site-build:no-puck-dependency:want-one-of:${PUCK_PACKAGES.join(",")}`;
  const dir = cacheDir(checkout, env);
  if (!outsideCheckout(dir, checkout)) return "refused:studio-puck:site-build:cache-inside-checkout";
  const app = join(dir, "app");
  const tools = join(dir, "tools");
  const pub = join(dir, "public");
  const npm = (cwd, args) => run("npm", args, { cwd, stdio: ["ignore", "ignore", "inherit"], env: { ...env, npm_config_update_notifier: "false" } });
  if (!existsSync(join(app, "node_modules", pkg))) {
    mkdirSync(app, { recursive: true });
    copyFileSync(join(checkout, "package.json"), join(app, "package.json"));
    const locked = existsSync(join(checkout, "package-lock.json"));
    if (locked) copyFileSync(join(checkout, "package-lock.json"), join(app, "package-lock.json"));
    npm(app, [locked ? "ci" : "install", "--ignore-scripts", "--no-audit", "--no-fund"]);
  }
  if (!existsSync(join(tools, "node_modules", "esbuild"))) {
    mkdirSync(tools, { recursive: true });
    writeFileSync(join(tools, "package.json"), '{"private":true}\n');
    npm(tools, ["install", "--no-audit", "--no-fund", "--no-save", ESBUILD]);
  }
  const esbuild = await import(pathToFileURL(join(tools, "node_modules", "esbuild", "lib", "main.js")).href);
  // The entry sits inside app/, so every bare import (React above all) has one
  // resolution: the site's own node_modules. The site's config resolves its
  // imports from the checkout, falling back to the same node_modules.
  const entry = join(app, "studio-editor.jsx");
  copyFileSync(env.STUDIO_PUCK_EDITOR || "/opt/studio/puck/editor.jsx", entry);
  rmSync(pub, { recursive: true, force: true });
  mkdirSync(pub, { recursive: true });
  await esbuild.build({
    entryPoints: [entry],
    bundle: true,
    minify: true,
    format: "iife",
    jsx: "automatic",
    outdir: pub,
    entryNames: "editor",
    assetNames: "assets/[name]-[hash]",
    loader: { ".png": "file", ".jpg": "file", ".jpeg": "file", ".gif": "file", ".svg": "file", ".webp": "file", ".avif": "file", ".woff": "file", ".woff2": "file", ".ttf": "file" },
    publicPath: "/",
    define: { "process.env.NODE_ENV": '"production"' },
    alias: { "studio-config": join(checkout, config), "studio-puck": pkg },
    nodePaths: [join(app, "node_modules")],
    logLevel: "warning",
  });
  // The page's own stylesheets, bundled (their url()s resolved) into site.css.
  const pageCss = siteCss(checkout, env);
  const cssEntry = join(app, "studio-site.css");
  writeFileSync(cssEntry, pageCss.map((c) => `@import ${JSON.stringify("./" + relative(app, join(checkout, c)).split(sep).join("/"))};\n`).join(""));
  await esbuild.build({
    entryPoints: [cssEntry], bundle: true, minify: true, outfile: join(pub, "site.css"),
    loader: { ".png": "file", ".jpg": "file", ".jpeg": "file", ".gif": "file", ".svg": "file", ".webp": "file", ".avif": "file", ".woff": "file", ".woff2": "file", ".ttf": "file" },
    assetNames: "assets/[name]-[hash]", publicPath: "/", logLevel: "warning",
    // Root-absolute url()s name the site's public dir (served by server.mjs as
    // it is on the live site), not files to bundle. A plugin, not external:
    // ["/*"]: esbuild matches that pattern after resolution too, so it also
    // externalised the @import of the stylesheet itself (measured: 54 bytes).
    plugins: [{
      name: "site-root-urls",
      setup(b) {
        b.onResolve({ filter: /^\// }, (a) => (a.kind === "url-token" ? { path: a.path, external: true } : undefined));
      },
    }],
  });
  const css = puckCss(join(app, "node_modules"), pkg);
  if (css) copyFileSync(css, join(pub, "puck.css"));
  else writeFileSync(join(pub, "puck.css"), "");
  if (!existsSync(join(pub, "editor.css"))) writeFileSync(join(pub, "editor.css"), "");
  writeFileSync(join(pub, "editor.html"), HTML);
  return `ok:studio-puck:site-build:${pub}`;
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  const checkout = process.argv[2];
  if (!checkout) {
    console.error("usage: node build-site.mjs <checkout>");
    process.exit(2);
  }
  let line;
  try { line = await build(checkout); } catch (e) {
    line = `refused:studio-puck:site-build:${String(e.message || e).split("\n")[0].replace(/\s+/g, "_").slice(0, 200)}`;
  }
  console.log(line);
  process.exit(line.startsWith("refused:") ? 1 : 0);
}
