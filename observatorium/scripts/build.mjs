// @trace order:2066-obsv, order:1661-vckd, spec:observatorium-dashboard
// The release cut, and only the release cut:
//
//   node scripts/build.mjs --release-snapshot <tag>
//
// appends ONE snapshot naming <tag> to history/snapshots.jsonl (committed; the
// durable history is the repository, updated by the release cut, never by a
// deploy). skills/merge-to-main-and-release runs it.
//
// The site is built by site/build.mjs from that committed history alone. The
// deploy-time live collection, the Flutter build and the pinned Flutter and
// rustup downloads that used to live here are gone (order 2066-obsv): nothing
// downloads a toolchain, and no deploy collects anything.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = fileURLToPath(new URL('..', import.meta.url));
const root = resolve(app, '..');
const cache = resolve(process.env.OBSERVATORIUM_CACHE || resolve(app, '.cache'));
const committedHistory = resolve(app, 'history/snapshots.jsonl');

function run(command, args, { cwd = app, env = process.env } = {}) {
  const result = spawnSync(command, args, { cwd, stdio: 'inherit', env });
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(`${command} ${args.join(' ')} exited ${result.status}`);
}

/** tillandsias-plan: given, or built from this checkout with the local cargo. */
function ensurePlan() {
  if (process.env.TILLANDSIAS_PLAN_BIN && existsSync(process.env.TILLANDSIAS_PLAN_BIN)) {
    return process.env.TILLANDSIAS_PLAN_BIN;
  }
  if (spawnSync('cargo', ['--version']).status !== 0) {
    throw Error('the release cut needs tillandsias-plan: set TILLANDSIAS_PLAN_BIN, or run where cargo is installed (a forge has it)');
  }
  run('cargo', ['build', '--release', '--locked', '-p', 'tillandsias-plan'], { cwd: root });
  return resolve(process.env.CARGO_TARGET_DIR || resolve(root, 'target'), 'release/tillandsias-plan');
}

export function parseArgs(argv) {
  const at = argv.indexOf('--release-snapshot');
  const tag = at >= 0 ? argv[at + 1] : null;
  if (at < 0) throw Error('usage: node scripts/build.mjs --release-snapshot <tag>; the site is built by node site/build.mjs');
  if (!/^v\d+\.\d+\.\d+\.\d+$/.test(tag || '')) throw Error('--release-snapshot needs a release tag like v56.10.13.1');
  return { tag };
}

function main() {
  const { tag } = parseArgs(process.argv.slice(2));
  mkdirSync(cache, { recursive: true });
  const env = { ...process.env, TILLANDSIAS_PLAN_BIN: ensurePlan() };
  run(process.execPath, ['metrics/collect.mjs', '--root', root,
    '--output', resolve(cache, 'release-snapshot.json'), '--history', committedHistory,
    '--release', tag, '--grade'], { env });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`observatorium-build: ${error.message}`);
    process.exit(1);
  }
}
