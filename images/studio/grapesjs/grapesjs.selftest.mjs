// @trace order:2108-dptd, spec:web-studio-lane
//
// Arms for the GrapesJS studio's page handling, run with the forge image's node
// and git (or any node >= 20 with git): node grapesjs.selftest.mjs <studios.json>
// Prints one verdict line: ok:studio-grapesjs-page:<n>-arms, or
// refused:studio-grapesjs-page:<arm>:<why>.
//
//   1 the document root comes from wrangler.jsonc assets.directory, and /load
//     answers public/index.html's body (pre-fix: {html:""} from the root)
//   2 a one-word edit commits ONLY public/index.html, with every byte outside
//     <body> unchanged (pre-fix: a root index.html with a bare head)
//   3 a save on the default branch leaves it unchanged and lands on a work
//     branch (pre-fix: committed on main)
//   4 the root falls back to STUDIO_APP_DIR, then to the repo root; a page-less
//     root loads as exists:false (the editor stays read-only)
//   5 the editor references no CDN and loads the vendored icon font
import { createRequire } from "node:module";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const registry = process.argv[2] || join(here, "..", "studios.json");
const front = require(process.env.STUDIO_FRONT || join(here, "..", "studio-front.js"));
const page = require(join(here, "studio-page.js"));
const server = await import(pathToFileURL(join(here, "server.mjs")).href);

let arms = 0;
function check(arm, cond, why) {
  if (!cond) {
    process.stdout.write(`refused:studio-grapesjs-page:${arm}:${String(why).replace(/\s+/g, "_").slice(0, 300)}\n`);
    process.exit(1);
  }
}
Object.assign(process.env, {
  GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1",
  GIT_AUTHOR_NAME: "user", GIT_AUTHOR_EMAIL: "u@example.invalid",
  GIT_COMMITTER_NAME: "user", GIT_COMMITTER_EMAIL: "u@example.invalid",
});
const quiet = () => {}; // the front's events go to stdout; keep the verdict line alone
const site = mkdtempSync(join(tmpdir(), "studio-grapesjs-page-"));
const g = (args) => execFileSync("git", ["-C", site, ...args], { encoding: "utf8" }).trim();
g(["init", "-q", "-b", "main"]);
const HEAD_PART =
  '<!doctype html>\n<html lang="es">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width">\n' +
  '<title>Tlatoāni</title>\n<meta property="og:title" content="Tlatoāni">\n<style>h1{color:#c33}</style>\n' +
  '<script>window.x=1</script>\n</head>\n<body class="home" data-k="v">';
const TAIL_PART = '</body>\n</html>\n';
const DOC = HEAD_PART + "\n<h1>Hola mundo</h1>\n<p>Bienvenidos</p>\n" + TAIL_PART;
mkdirSync(join(site, "public"));
writeFileSync(join(site, "public", "index.html"), DOC);
writeFileSync(join(site, "wrangler.jsonc"), '{\n  // site\n  "name": "t",\n  "assets": { "directory": "./public/", },\n}\n');
writeFileSync(join(site, "package.json"), '{"name":"t","private":true}\n');
g(["add", "-A"]);
g(["commit", "-q", "-m", "site"]);
const mainBefore = g(["rev-parse", "main"]);

// Arm 1: the root and the load.
const loaded = await server.load(site, {});
check(1, loaded.root === "public" && loaded.root_from === "wrangler.jsonc", JSON.stringify(loaded).slice(0, 200));
check(1, loaded.exists === true && loaded.page === "public/index.html", loaded.page);
check(1, loaded.html.includes("<h1>Hola mundo</h1>") && !loaded.html.includes("<title>"), loaded.html);
arms++;

// Arms 2 and 3: a one-word edit through the real front.
const out = process.stdout.write.bind(process.stdout);
process.stdout.write = (s) => (String(s).startsWith("event:") ? true : out(s));
const cfg = front.loadConfig({ TILLANDSIAS_STUDIO: "grapesjs", STUDIO_REGISTRY: registry, STUDIO_CHECKOUT: site, TILLANDSIAS_PROJECT: "tlatoani.net" });
// GrapesJS getHtml() wraps its content in its own <body>.
const edited = '<body id="iabc"><h1>Hola amigos</h1><p>Bienvenidos</p></body>';
const content = page.rebuild(loaded.doc, edited, null);
const r = front.save(cfg, loaded.page, content);
process.stdout.write = out;
check(2, r.status === 200 && r.body.sha, JSON.stringify(r));
const written = readFileSync(join(site, "public", "index.html"), "utf8");
check(2, written.startsWith(HEAD_PART) && written.endsWith(TAIL_PART), "outside-body-changed");
check(2, written.includes("Hola amigos") && !written.includes('id="iabc"'), "edit-or-body-tag");
const changed = g(["diff", "--name-only", `${mainBefore}`, "HEAD"]);
check(2, changed === "public/index.html", `changed:${changed}`);
arms++;
const branch = g(["symbolic-ref", "--short", "HEAD"]);
check(3, branch !== "main" && branch.startsWith("grapesjs/tlatoani-net-work/"), `branch:${branch}`);
check(3, g(["rev-parse", "main"]) === mainBefore, "main-moved");
check(3, g(["log", "-1", "--format=%s", branch]) === "studio(grapesjs): save public/index.html", "commit-not-on-work-branch");
arms++;

// Arm 4: the fallbacks.
const bare = mkdtempSync(join(tmpdir(), "studio-grapesjs-bare-"));
mkdirSync(join(bare, "site"));
writeFileSync(join(bare, "site", "index.html"), "<html><body><p>x</p></body></html>");
const viaApp = await server.load(bare, { STUDIO_APP_DIR: "site" });
check(4, viaApp.root === "site" && viaApp.root_from === "app_dir" && viaApp.html === "<p>x</p>", JSON.stringify(viaApp));
const viaRoot = await server.load(bare, {});
check(4, viaRoot.root === "." && viaRoot.exists === false && viaRoot.html === "", JSON.stringify(viaRoot));
check(4, server.resolveRoot(bare, { STUDIO_APP_DIR: "../etc" }).root === ".", "escape-accepted");
arms++;

// Arm 5: no CDN in the editor; the icon font is the vendored one.
const editor = readFileSync(join(here, "editor.html"), "utf8").replace(/<!--[\s\S]*?-->/g, "");
check(5, !/https?:\/\//.test(editor), "editor-references-a-url");
check(5, editor.includes('cssIcons: "/vendor/font-awesome/css/font-awesome.min.css"'), "icons-not-vendored");
const cf = readFileSync(join(here, "..", "Containerfile.grapesjs"), "utf8");
check(5, /vendor\.mjs "\$FONT_AWESOME_VERSION" "\$FONT_AWESOME_INTEGRITY"/.test(cf), "font-awesome-not-vendored-in-image");
arms++;

// Arm 6: the canvas renders the page as it looks (pre-fix: white canvas, the
// head's inline style never reached the frame; then, measured on tlatoani.net,
// GrapesJS 0.23 re-rendered its <head> component and wiped styles injected into
// it, and url("/assets/x.png") 404'd on the studio origin): canvasLook yields
// the head's inline CSS, local stylesheets resolved at "/" (never a remote
// one) and the body's attributes; the editor hands them to GrapesJS's own
// canvasCss / canvas.styles; the server falls back to the document root for
// any other GET; a save writes no studio-state file.
const look = page.canvasLook(
  HEAD_PART.replace("</head>", '<link rel="stylesheet" href="./css/site.css"><link rel="stylesheet" href="https://cdn.example/x.css">\n</head>') + "x" + TAIL_PART,
  "/");
check(6, look.styles.length === 1 && look.styles[0] === "h1{color:#c33}", JSON.stringify(look.styles));
check(6, look.links.length === 1 && look.links[0] === "/css/site.css", JSON.stringify(look.links));
check(6, look.attrs.class === "home" && look.attrs["data-k"] === "v", JSON.stringify(look.attrs));
check(6, /StudioPage\.canvasLook\(loaded\.doc, "\/"\)/.test(editor), "editor-does-not-read-the-look");
check(6, editor.includes('canvasCss: ["body{background-color:transparent}"].concat(look.styles).join("\\n")') && editor.includes("canvas: { styles: look.links }"), "look-not-passed-through-grapesjs-canvas-options-or-white-body-kept");
check(6, !editor.includes("project.json"), "a-save-still-writes-studio-state");
const srv = readFileSync(join(here, "server.mjs"), "utf8").replace(/\/\/[^\n]*/g, "");
check(6, /if \(req\.method === "GET"\) \{\s*const \{ root \} = resolveRoot\(PROJECT\);\s*return staticFile\(res, normalize\(join\(PROJECT, root\)\)/.test(srv), "no-document-root-fallback");
arms++;

// Arm 7 (v4, operator test on tlatoani.net): a save keeps the body's <script>
// (pre-fix: GrapesJS dropped the QR script), rewrites only the edited node
// (pre-fix: the whole body minified onto one line), keeps only the ids the CSS
// uses, puts the managed link on its own indented line, and the editor never
// saves while the text editor is active (pre-fix: the caret jumped).
{
  const d = '<!doctype html>\n<html>\n<head>\n  <title>x</title>\n</head>\n<body class="a">\n  <header>\n    <h1 class="t" data-x="1">Demon Attack</h1>\n    <p>uno</p>\n  </header>\n  <script>\n  var q = "<b>";\n  </script>\n</body>\n</html>\n';
  const prot = page.protect(page.split(d).inner);
  check(7, !prot.html.includes("<script") && prot.kept.length === 1, prot.html);
  const base = '<body id="w"><header id="ijvv2"><h1 data-x="1" class="t">Demon Attack</h1><p>uno</p></header><!--studio-keep:0--></body>';
  const now = base.replace('class="t">Demon Attack', 'class="t" id="iriib">Demon<br/>Attack');
  const outv4 = page.rebuild(d, now, "studio.css", { baseline: base, css: "#iriib{text-align:center;}" });
  const want = d
    .replace("</head>", '  <link rel="stylesheet" href="studio.css">\n</head>')
    .replace('<h1 class="t" data-x="1">Demon Attack</h1>', '<h1 data-x="1" class="t" id="iriib">Demon<br/>Attack</h1>');
  check(7, outv4 === want, JSON.stringify(outv4));
  const lost = page.rebuild(d, now.replace("<!--studio-keep:0-->", ""), null, { baseline: base, css: "" });
  check(7, lost.includes('var q = "<b>";') && !lost.includes("iriib") && !lost.includes("ijvv2"), JSON.stringify(lost));
  check(7, editor.includes('editor.on("rte:disable", check)') && /if \(editor\.getEditing\(\)\) return setDirty\(true\);/.test(editor) && editor.includes("StudioPage.protect(loaded.html") && editor.includes("files[0][1] === lastSaved"), "editor-saves-while-typing-or-unprotected");
  // Operator ruling: an explicit Save (one commit per click), never an
  // autosave commit; a beforeunload guard; the autosave is a local draft only.
  check(7, editor.includes('editor.Commands.add("studio-save"') && editor.includes('command: "studio-save"'), "no-save-button");
  check(7, (editor.match(/\.store\(\)/g) || []).length === 1 && /await ed\.store\(\);\s*setDirty\(false\)/.test(editor), "a-store-outside-the-save-command");
  check(7, editor.includes('addEventListener("beforeunload"') && editor.includes("localStorage.setItem(draftKey"), "no-unload-guard-or-draft");
  arms++;
}

process.stdout.write(`ok:studio-grapesjs-page:${arms}-arms\n`);
