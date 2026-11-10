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
import {mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseClaims} from './claims.mjs';
import {lintData, lintPage} from './honesty.mjs';
import {layout} from './layout.mjs';
import {home} from './pages/home.mjs';
import {obligations} from './pages/obligations.mjs';
import {releasePage, releasesIndex} from './pages/releases.mjs';
import {claimsPage, dataPage, glossary, instrument} from './pages/text.mjs';
import {checkRelease, gitFacts} from './trailer.mjs';
import {deriveView} from './view.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, '..');
const sha256 = (text) => createHash('sha256').update(text).digest('hex');
const json = (value) => `${JSON.stringify(value, null, 1)}\n`;

export function parseHistory(text) {
  return text.split('\n').filter((l) => l.trim()).map((l, i) => {
    try { return JSON.parse(l); } catch { throw Error(`history/snapshots.jsonl line ${i + 1} is not JSON`); }
  });
}

/**
 * Pure: committed history (+ claims) and git facts -> every output file.
 * Throws on a refused release or any honesty-lint violation, before anything
 * is written.
 */
export function buildSite(historyText, {newestTag, trailer, deploy = false, builtAt,
  claimsText = readFileSync(resolve(app, 'data/claims.yaml'), 'utf8')}) {
  const rows = parseHistory(historyText);
  const view = deriveView(rows);
  const check = checkRelease({snapshotRelease: view.latest.tag, newestTag, trailer, deploy});
  if (!check.ok) throw Error(`refused:${check.reason}: ${check.detail}`);
  const claims = parseClaims(claimsText);
  const stamp = {release: check.release, builtAt, preview: check.preview, snapshotSha256: sha256(historyText)};

  // Published data first: the Data page lists their digests.
  const data = new Map([
    ['data/history.json', [json({...view, latest: view.latest.tag, builtAt, snapshotSha256: stamp.snapshotSha256}),
      'The derived view every page is built from: one record per release, nulls kept where a snapshot records nothing.']],
    ['data/snapshots.jsonl', [historyText, 'The committed release history, byte for byte (observatorium/history/snapshots.jsonl).']],
    ['data/claims.json', [json({review: 'operator-pending entries are not endorsed by the operator', claims}),
      'The claims register (observatorium/data/claims.yaml) as JSON.']],
  ]);
  const files = new Map();
  for (const [file, [text]] of data) files.set(file, text);

  const pages = [
    ['index.html', home(view)],
    ['releases/index.html', releasesIndex(view)],
    ...view.releases.map((r, i) => [`releases/${r.tag}/index.html`, releasePage(view, i)]),
    ['obligations/index.html', obligations(view)],
    ['claims/index.html', claimsPage(claims)],
    ['instrument/index.html', instrument(view)],
    ['glossary/index.html', glossary()],
    ['data/index.html', dataPage([...data].map(([file, [text, what]]) => ({file: file.slice('data/'.length), what, sha256: sha256(text)})))],
    ['404.html', {title: 'Not found', description: 'No such page.',
      body: '<section class="card"><h1>Not found</h1><p>There is no page at this address. <a href="index.html">Go to the home page.</a></p></section>'}],
  ];
  for (const [file, page] of pages) files.set(file, layout({file, ...page, stamp}));

  const violations = [
    ...pages.flatMap(([file]) => lintPage(file, files.get(file), view)),
    ...lintData('data/history.json', JSON.parse(files.get('data/history.json'))),
    ...rows.flatMap((row, i) => lintData(`data/snapshots.jsonl:${i + 1}`, row)),
    ...lintData('data/claims.json', JSON.parse(files.get('data/claims.json'))),
  ];
  if (violations.length) {
    const lines = violations.map((v) => `  ${v.file}: ${v.rule}: ${v.detail}`).join('\n');
    throw Error(`refused:honesty-lint: ${violations.length} violation(s)\n${lines}`);
  }
  for (const f of ['style.css', 'filter.js', '_headers']) files.set(f, readFileSync(resolve(here, 'static', f), 'utf8'));
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
  // Empty the directory rather than replace it, so a live preview that
  // mounts it keeps serving the new files.
  mkdirSync(out, {recursive: true});
  for (const entry of readdirSync(out)) rmSync(resolve(out, entry), {recursive: true, force: true});
  for (const [file, content] of result.files) {
    mkdirSync(dirname(resolve(out, file)), {recursive: true});
    writeFileSync(resolve(out, file), content);
  }
  console.log(`observatorium-site: ok:${result.stamp.preview ? 'preview' : 'deploy'}:${result.stamp.release}:${result.files.size} files -> ${out}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
