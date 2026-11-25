// @trace order:2110-pk4s, spec:web-studio-lane
//
// Arms for the Puck studio's site build and Save, run with any node >= 20:
//   node puck.selftest.mjs
// Prints one verdict line: ok:studio-puck-site:<n>-arms, or
// refused:studio-puck-site:<arm>:<why>. No network: the npm steps are stubbed.
//
//   1 the site's config is found (src/puck.config.tsx first); an override that
//     escapes the checkout is refused (pre-fix: the site's config was never read)
//   2 the site's Puck package is used (@puckeditor/core before @measured/puck);
//     none refuses before any install
//   3 the build cache is outside the checkout; a cache inside it is refused;
//     a site without a config builds nothing and writes nothing
//   4 the editor saves only on the Save click: no onPublish, one POST to
//     /__studio/save inside save(), a no-op guard, beforeunload, a local draft
//     (pre-fix: every Publish committed, no dirty state)
//   5 the server serves the site build when there is one, the demo otherwise,
//     the site's public/ for root URLs, and refuses a path out of either
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawn } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const site = await import(pathToFileURL(join(here, "build-site.mjs")).href);
let arms = 0;
function check(arm, cond, why) {
  if (!cond) {
    process.stdout.write(`refused:studio-puck-site:${arm}:${String(why).replace(/\s+/g, "_").slice(0, 300)}\n`);
    process.exit(1);
  }
}
const stripComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/[^\n]*$/gm, "");

const co = mkdtempSync(join(tmpdir(), "studio-puck-site-"));
mkdirSync(join(co, "src"));
writeFileSync(join(co, "src", "puck.config.tsx"), "export default { components: {} };\n");
writeFileSync(join(co, "puck.config.js"), "export default { components: {} };\n");
writeFileSync(join(co, "package.json"), JSON.stringify({ dependencies: { "@measured/puck": "0.20.2", "@puckeditor/core": "0.24.1", react: "19.2.0" } }));

// Arm 1
check(1, site.findConfig(co, {}) === "src/puck.config.tsx", site.findConfig(co, {}));
check(1, site.findConfig(co, { STUDIO_PUCK_CONFIG: "puck.config.js" }) === "puck.config.js", "override-ignored");
check(1, site.findConfig(co, { STUDIO_PUCK_CONFIG: "../etc/passwd" }) === null, "escape-accepted");
arms++;

// Arm 2
check(2, site.puckPackage({ dependencies: { "@measured/puck": "1", "@puckeditor/core": "1" } }) === "@puckeditor/core", "wrong-package");
check(2, site.puckPackage({ devDependencies: { "@measured/puck": "1" } }) === "@measured/puck", "dev-dep-missed");
const bare = mkdtempSync(join(tmpdir(), "studio-puck-nopuck-"));
writeFileSync(join(bare, "puck.config.js"), "export default {};\n");
writeFileSync(join(bare, "package.json"), '{"dependencies":{"react":"19"}}');
let ran = 0;
const v2 = await site.build(bare, { STUDIO_PUCK_CACHE: join(tmpdir(), "spc") }, () => { ran++; });
check(2, v2.startsWith("refused:studio-puck:site-build:no-puck-dependency") && ran === 0, `${v2}:ran=${ran}`);
arms++;

// Arm 3
const dir = site.cacheDir(co, { HOME: "/home/forge" });
check(3, site.outsideCheckout(dir, co), dir);
const v3 = await site.build(co, { STUDIO_PUCK_CACHE: join(co, "cache") }, () => { ran++; });
check(3, v3 === "refused:studio-puck:site-build:cache-inside-checkout" && ran === 0, v3);
const none = mkdtempSync(join(tmpdir(), "studio-puck-none-"));
writeFileSync(join(none, "package.json"), "{}");
const v3b = await site.build(none, { STUDIO_PUCK_CACHE: join(tmpdir(), "spc") }, () => { ran++; });
check(3, v3b === "skip:studio-puck:site-build:no-site-config" && ran === 0, v3b);
check(3, readdirSync(none).join(",") === "package.json", readdirSync(none).join(","));
arms++;

// Arm 4
const ed = stripComments(readFileSync(join(here, "build", "editor.jsx"), "utf8"));
check(4, !/onPublish/.test(ed), "editor-still-publishes");
check(4, (ed.match(/\/__studio\/save/g) || []).length === 1 && /const save = async[\s\S]*\/__studio\/save/.test(ed), "save-not-only-in-save");
check(4, /if \(content === saved\.current\) \{[^}]*return; \}/.test(ed), "no-op-save-posts");
check(4, ed.includes('addEventListener("beforeunload"') && ed.includes("localStorage.setItem(draftKey"), "no-unload-guard-or-draft");
check(4, /onClick=\{save\}/.test(ed) && /headerActions:/.test(ed), "save-not-a-click");
check(4, /from "studio-config"/.test(ed) && /from "studio-puck"/.test(ed), "editor-not-built-against-the-site");
arms++;

// Arm 5
const demo = mkdtempSync(join(tmpdir(), "studio-puck-here-"));
mkdirSync(join(demo, "public"));
writeFileSync(join(demo, "public", "editor.html"), "DEMO");
const built = mkdtempSync(join(tmpdir(), "studio-puck-pub-"));
writeFileSync(join(built, "editor.html"), "SITE");
mkdirSync(join(built, "assets"));
writeFileSync(join(built, "assets", "x.svg"), "<svg/>");
async function serve(env, paths) {
  const port = 41000 + Math.floor(Math.random() * 2000);
  const child = spawn(process.execPath, [join(here, "server.mjs")], {
    env: { ...process.env, STUDIO_HERE: demo, STUDIO_PROJECT: co, STUDIO_PORT: String(port), ...env }, stdio: ["ignore", "pipe", "inherit"],
  });
  await new Promise((r) => child.stdout.once("data", r));
  const out = [];
  for (const p of paths) {
    const r = await fetch(`http://127.0.0.1:${port}${p}`);
    out.push(`${r.status}:${(await r.text()).slice(0, 6)}`);
  }
  child.kill();
  return out;
}
mkdirSync(join(co, "public", "assets"), { recursive: true });
writeFileSync(join(co, "public", "assets", "frame.png"), "PNGXYZ");
const withSite = await serve({ STUDIO_PUCK_PUBLIC: built }, ["/", "/assets/x.svg", "/..%2f..%2fetc%2fpasswd", "/assets/frame.png", "/..%2fpackage.json"]);
check(5, withSite[0] === "200:SITE" && withSite[1] === "200:<svg/>" && withSite[2].startsWith("404"), withSite.join(","));
// The page CSS's url("/assets/…") resolves to the site's public dir, read-only;
// nothing outside public/ is reachable that way.
check(5, withSite[3] === "200:PNGXYZ" && withSite[4].startsWith("404"), withSite.join(","));
const withoutSite = await serve({ STUDIO_PUCK_PUBLIC: "" }, ["/"]);
check(5, withoutSite[0] === "200:DEMO", withoutSite.join(","));
arms++;

process.stdout.write(`ok:studio-puck-site:${arms}-arms\n`);
