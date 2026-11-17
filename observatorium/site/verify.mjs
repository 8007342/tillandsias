#!/usr/bin/env node
// @trace order:2066-obsv, spec:observatorium-dashboard
// The stale-ship guard run immediately before `wrangler deploy`, on a
// checkout of deploy/observatorium (publish.mjs copies this file there). It
// has no imports beyond node itself, because the deploy tree carries no
// generator. The tip commit's Observatorium-Release and Observatorium-Snapshot
// trailers must name exactly the release and history digest that
// dist/data/history.json was built from.
import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';

const trailer = (message, key) => (message.match(new RegExp(`^${key}:[ \\t]*(\\S+)[ \\t]*$`, 'm')) || [])[1] ?? null;

export function verifyDeploy({message, historyJson}) {
  const refuse = (reason, detail) => ({ok: false, reason, detail});
  const release = trailer(message, 'Observatorium-Release');
  const snapshot = trailer(message, 'Observatorium-Snapshot');
  if (!release || !snapshot) return refuse('missing-trailer', 'the deploy commit lacks Observatorium-Release or Observatorium-Snapshot');
  let data;
  try { data = JSON.parse(historyJson); } catch { return refuse('no-data', 'dist/data/history.json is not JSON'); }
  if (data.latest !== release) return refuse('trailer-mismatch', `trailer names ${release}, the built data ends at ${data.latest}`);
  if (data.snapshotSha256 !== snapshot) return refuse('snapshot-mismatch', 'the built data was not made from the history the trailer names');
  return {ok: true, release};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const here = resolve(fileURLToPath(import.meta.url), '..');
  const log = spawnSync('git', ['log', '-1', '--format=%B'], {cwd: here, encoding: 'utf8'});
  if (log.status !== 0) {
    console.error('observatorium-verify: refused:no-git: run this from a checkout of deploy/observatorium');
    process.exit(1);
  }
  let historyJson = '';
  try { historyJson = readFileSync(resolve(here, 'dist/data/history.json'), 'utf8'); } catch { /* reported below */ }
  const r = verifyDeploy({message: log.stdout, historyJson});
  if (!r.ok) {
    console.error(`observatorium-verify: refused:${r.reason}: ${r.detail}`);
    process.exit(1);
  }
  console.log(`observatorium-verify: ok:${r.release}`);
}
