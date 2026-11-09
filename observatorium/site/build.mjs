#!/usr/bin/env node
// @trace order:2066-obsv, spec:observatorium-dashboard
// The static observatorium generator. Reads ONLY the committed
// history/snapshots.jsonl (no network, no live metrics, no toolchains), derives
// the view, renders plain HTML with build-time SVG, lints every file against
// the honesty rules and writes nothing unless all of them pass.
//
//   node site/build.mjs                 preview build into ./dist
//   node site/build.mjs --deploy        deploy build: also requires HEAD's
//                                       Observatorium-Release trailer
//   node site/build.mjs --out <dir>     another output directory
//
// Publishing is manual and separate (see README.md): nothing here deploys.
import {createHash} from 'node:crypto';
import {mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {lintData, lintPage} from './honesty.mjs';
import {layout} from './layout.mjs';
import {home} from './pages/home.mjs';
import {checkRelease, gitFacts} from './trailer.mjs';
import {deriveView} from './view.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, '..');

export function parseHistory(text) {
  return text.split('\n').filter((l) => l.trim()).map((l, i) => {
    try { return JSON.parse(l); } catch { throw Error(`history/snapshots.jsonl line ${i + 1} is not JSON`); }
  });
}

/** Pure: history text + facts -> files. Throws on a refused release or a lint violation. */
export function buildSite(historyText, {newestTag, trailer, deploy = false, builtAt}) {
  const view = deriveView(parseHistory(historyText));
  const check = checkRelease({snapshotRelease: view.latest.tag, newestTag, trailer, deploy});
  if (!check.ok) throw Error(`refused:${check.reason}: ${check.detail}`);
  const stamp = {release: check.release, builtAt, preview: check.preview,
    snapshotSha256: createHash('sha256').update(historyText).digest('hex')};

  const files = new Map();
  const pages = [['index.html', home(view)]];
  for (const [file, page] of pages) files.set(file, layout({file, ...page, stamp}));
  const data = {...view, latest: view.latest.tag, builtAt, snapshotSha256: stamp.snapshotSha256};
  files.set('data/history.json', `${JSON.stringify(data, null, 1)}\n`);

  pages.push(["404.html", {title: "Not found", description: "No such page.",
    body: "<section class=\"card\"><h1>Not found</h1><p>There is no page at this address. <a href=\"index.html\">Go to the home page.</a></p></section>"}]);
  files.set("404.html", layout({file: "404.html", ...pages.at(-1)[1], stamp}));
  const violations = [
    ...pages.flatMap(([file]) => lintPage(file, files.get(file), view)),
    lintData('data/history.json', data),
  ].flat();
  if (violations.length) {
    const lines = violations.map((v) => `  ${v.file}: ${v.rule}: ${v.detail}`).join('\n');
    throw Error(`refused:honesty-lint: ${violations.length} violation(s)\n${lines}`);
  }
  files.set('style.css', readFileSync(resolve(here, 'static/style.css'), 'utf8'));
  files.set("_headers", readFileSync(resolve(here, "static/_headers"), "utf8"));
  return {files, violations, view, stamp};
}

function main(argv) {
  const deploy = argv.includes('--deploy');
  const oi = argv.indexOf('--out');
  const out = resolve(oi >= 0 ? argv[oi + 1] : resolve(app, 'dist'));
  const historyText = readFileSync(resolve(app, 'history/snapshots.jsonl'), 'utf8');
  const builtAt = process.env.SOURCE_DATE_EPOCH
    ? new Date(Number(process.env.SOURCE_DATE_EPOCH) * 1000).toISOString()
    : new Date().toISOString();
  let result;
  try {
    result = buildSite(historyText, {...gitFacts(app), deploy, builtAt});
  } catch (e) {
    console.error(`observatorium-site: ${e.message}`);
    process.exit(1);
  }
  rmSync(out, {recursive: true, force: true});
  for (const [file, content] of result.files) {
    mkdirSync(dirname(resolve(out, file)), {recursive: true});
    writeFileSync(resolve(out, file), content);
  }
  console.log(`observatorium-site: ok:${result.stamp.preview ? 'preview' : 'deploy'}:${result.stamp.release}:${result.files.size} files -> ${out}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
