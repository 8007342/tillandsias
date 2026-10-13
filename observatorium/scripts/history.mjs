// @trace spec:observatorium-dashboard — durable observation history
// Dedicated research branch keeps measured observations beyond CI retention.
// Never treat an unreachable remote as an empty history.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = fileURLToPath(new URL('..', import.meta.url));
const root = resolve(app, '..');
const branch = 'research/observatorium-history';
const ref = `refs/heads/${branch}`;
const cache = resolve(process.env.OBSERVATORIUM_CACHE || resolve(app, '.cache'));
const state = resolve(cache, 'history-head');
const history = resolve(cache, 'snapshots.jsonl');
const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
mkdirSync(cache, { recursive: true });
if (process.argv[2] === 'restore') {
  // ls-remote failure throws; an empty successful response is first deployment.
  const match = git('ls-remote', '--heads', 'origin', ref).trim();
  if (match) {
    git('fetch', '--no-tags', 'origin', ref);
    const head = git('rev-parse', 'FETCH_HEAD').trim();
    writeFileSync(history, git('show', `${head}:snapshots.jsonl`));
    writeFileSync(state, head);
  } else {
    writeFileSync(history, '');
    writeFileSync(state, '');
    console.log(`First deployment: initializing ${branch}`);
  }
} else if (process.argv[2] === 'save') {
  const parent = readFileSync(state, 'utf8').trim();
  const contents = readFileSync(history);
  const blob = execFileSync('git', ['hash-object', '-w', '--stdin'], { cwd: root, input: contents, encoding: 'utf8' }).trim();
  const tree = execFileSync('git', ['mktree'], { cwd: root,
    input: `100644 blob ${blob}\tsnapshots.jsonl\n`, encoding: 'utf8' }).trim();
  const args = ['commit-tree', tree, ...(parent ? ['-p', parent] : []), '-m', 'research(observatorium): preserve deployed metric observations'];
  const commit = execFileSync('git', args, { cwd: root, encoding: 'utf8', env: {
    ...process.env, GIT_AUTHOR_NAME: 'Observatorium', GIT_AUTHOR_EMAIL: 'observatorium@tillandsias.org',
    GIT_COMMITTER_NAME: 'Observatorium', GIT_COMMITTER_EMAIL: 'observatorium@tillandsias.org',
  } }).trim();
  // Explicit lease prevents concurrent deployments from replacing each other's
  // observations. Empty expected parent only permits creating a missing branch.
  git('push', `--force-with-lease=${ref}:${parent}`, 'origin', `${commit}:${ref}`);
  console.log(`Preserved observations at ${branch}@${commit}`);
} else {
  throw new Error('Usage: node scripts/history.mjs restore|save');
}
