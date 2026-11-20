// @trace order:1861-nmpp, order:2108-dptd
// Build-time only: fetch an npm tarball, verify it against the pinned sha512
// integrity, and unpack the kept paths into the target dir.
// Usage: node vendor.mjs VERSION INTEGRITY TARGET_DIR [PACKAGE [KEEP...]]
//   PACKAGE defaults to grapesjs (keeping dist and LICENSE); 2108-dptd adds
//   font-awesome (css, fonts) so the editor's panel icons need no CDN.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";

const [version, integrity, target, pkg = "grapesjs", ...keepArgs] = process.argv.slice(2);
if (!version || !integrity?.startsWith("sha512-") || !target || !/^[a-z0-9][a-z0-9._-]*$/.test(pkg)) {
  console.error("usage: node vendor.mjs VERSION sha512-INTEGRITY TARGET_DIR [PACKAGE [KEEP...]]");
  process.exit(2);
}
const keep = keepArgs.length ? keepArgs : ["dist", "LICENSE"];
const url = `https://registry.npmjs.org/${pkg}/-/${pkg}-${version}.tgz`;
const res = await fetch(url);
if (!res.ok) {
  console.error(`fetch ${url}: HTTP ${res.status}`);
  process.exit(1);
}
const bytes = Buffer.from(await res.arrayBuffer());
const got = "sha512-" + createHash("sha512").update(bytes).digest("base64");
if (got !== integrity) {
  console.error(`integrity mismatch for ${pkg} ${version}: want ${integrity}, got ${got}`);
  process.exit(1);
}
const tmp = `/tmp/${pkg}.tgz`;
writeFileSync(tmp, bytes);
mkdirSync(target, { recursive: true });
execFileSync("tar", ["-xzf", tmp, "-C", target, "--strip-components=1", ...keep.map((k) => `package/${k}`)]);
rmSync(tmp);
console.log(`ok:vendored:${pkg}@${version}:${target}`);
