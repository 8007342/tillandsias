// @trace order:1861-nmpp
// Build-time only: fetch the GrapesJS core npm tarball, verify it against the
// pinned sha512 integrity, and unpack dist/ and LICENSE into the target dir.
// Usage: node vendor.mjs VERSION INTEGRITY TARGET_DIR
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";

const [version, integrity, target] = process.argv.slice(2);
if (!version || !integrity?.startsWith("sha512-") || !target) {
  console.error("usage: node vendor.mjs VERSION sha512-INTEGRITY TARGET_DIR");
  process.exit(2);
}
const url = `https://registry.npmjs.org/grapesjs/-/grapesjs-${version}.tgz`;
const res = await fetch(url);
if (!res.ok) {
  console.error(`fetch ${url}: HTTP ${res.status}`);
  process.exit(1);
}
const bytes = Buffer.from(await res.arrayBuffer());
const got = "sha512-" + createHash("sha512").update(bytes).digest("base64");
if (got !== integrity) {
  console.error(`integrity mismatch for grapesjs ${version}: want ${integrity}, got ${got}`);
  process.exit(1);
}
const tmp = "/tmp/grapesjs.tgz";
writeFileSync(tmp, bytes);
mkdirSync(target, { recursive: true });
execFileSync("tar", ["-xzf", tmp, "-C", target, "--strip-components=1", "package/dist", "package/LICENSE"]);
rmSync(tmp);
console.log(`ok:vendored:grapesjs@${version}:${join(target, "dist")}`);
