// @trace spec:observatorium-dashboard — collect once, precompute before render
import { spawnSync } from 'node:child_process';
import { mkdirSync, copyFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const app = fileURLToPath(new URL('..', import.meta.url));
const root = resolve(app, '..');
const cache = resolve(process.env.OBSERVATORIUM_CACHE || resolve(app, '.cache'));
function run(command, args) {
  const result = spawnSync(command, args, { cwd: app, stdio: 'inherit', env: process.env });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}
mkdirSync(cache, { recursive: true });
const snapshot = resolve(cache, 'snapshot.json');
const history = resolve(cache, 'snapshots.jsonl');
run(process.execPath, ['metrics/collect.mjs', '--root', root, '--output', snapshot, '--history', history, '--grade']);
mkdirSync(resolve(app, 'web/data'), { recursive: true });
run(process.execPath, ['metrics/precompute.mjs', '--root', root, '--snapshot', snapshot, '--history', history,
  '--output', resolve(app, 'web/data/metrics.json')]);
if (!process.argv.includes('--metrics-only')) {
  run(process.env.FLUTTER || 'flutter', ['pub', 'get']);
  run(process.env.FLUTTER || 'flutter', ['build', 'web', '--release', '--no-web-resources-cdn']);
  copyFileSync(resolve(app, 'web/_headers'), resolve(app, 'build/web/_headers'));
}
