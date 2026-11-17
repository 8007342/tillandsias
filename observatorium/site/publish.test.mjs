// @trace order:2066-obsv, spec:observatorium-dashboard
// Red-first: the manual publish step. publish() builds the site for a release
// tag and commits {wrangler.jsonc, package.json, verify.mjs, dist/**} onto the
// local deploy/observatorium ref with Observatorium-Release and
// Observatorium-Snapshot trailers. It never pushes; the operator does, after a
// gate run. verifyDeploy() is the check run before `wrangler deploy`.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cpSync, mkdtempSync, readFileSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {publish} from './publish.mjs';
import {verifyDeploy} from './verify.mjs';

// A hermetic git for the whole file. publish() spawns git with process.env, so
// the identity its deploy commit is written under, and any signing or hook
// config, would otherwise come from the host: on a host with no global
// user.email (the tillandsias-builder toolbox) the commit failed "Author
// identity unknown" and three tests reddened gate step 930 (#1083). node --test
// runs each file in its own process, so this reaches only these tests;
// publish.mjs itself still commits as the operator when run for real.
Object.assign(process.env, {
  GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1',
  GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t',
});

const app = fileURLToPath(new URL('..', import.meta.url));
const TAG = 'v56.11.7.1';
const REF = 'refs/heads/deploy/observatorium';

function git(cwd, ...args) {
  const r = spawnSync('git', args, {cwd, encoding: 'utf8', env: {...process.env, GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t'}});
  if (r.status !== 0) throw Error(`git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}

function repo() {
  const root = mkdtempSync(join(tmpdir(), 'obs-publish-'));
  git(root, 'init', '-q', '-b', 'main');
  for (const d of ['site', 'history', 'data', 'metrics']) cpSync(join(app, d), join(root, 'observatorium', d), {recursive: true});
  cpSync(join(app, 'wrangler.jsonc'), join(root, 'observatorium/wrangler.jsonc'));
  git(root, 'add', '-A');
  git(root, 'commit', '-q', '-m', 'release');
  git(root, 'tag', TAG);
  return root;
}
const opts = (root) => ({repo: root, tag: TAG, builtAt: '2026-11-10T12:00:00Z'});

test('publish commits the built site onto the deploy ref, with trailers, and pushes nothing', () => {
  const root = repo();
  const head = git(root, 'rev-parse', 'HEAD');
  const r = publish(opts(root));
  assert.equal(r.ok, true, r.detail);
  const msg = git(root, 'log', '-1', '--format=%B', REF);
  assert.match(msg, new RegExp(`^Observatorium-Release: ${TAG}$`, 'm'));
  assert.match(msg, /^Observatorium-Snapshot: [0-9a-f]{64}$/m);
  assert.match(msg, new RegExp(`^Observatorium-Source: ${head}$`, 'm'));
  const files = git(root, 'ls-tree', '-r', '--name-only', REF).split('\n');
  for (const f of ['wrangler.jsonc', 'package.json', 'verify.mjs', 'dist/index.html', 'dist/data/history.json', 'dist/releases/v56.11.7.1/index.html']) assert.ok(files.includes(f), f);
  assert.equal(git(root, 'rev-parse', 'HEAD'), head, 'the checkout is not moved');
  assert.equal(git(root, 'remote'), '', 'nothing to push to, nothing pushed');
  const wrangler = git(root, 'show', `${REF}:wrangler.jsonc`);
  assert.doesNotMatch(wrangler, /"build"/);
  assert.match(wrangler, /"directory": "\.\/dist"/);
});

test('publishing the same release twice refuses', () => {
  const root = repo();
  assert.equal(publish(opts(root)).ok, true);
  assert.equal(publish(opts(root)).reason, 'already-published');
});

test('publishing a release older than the deploy tip refuses', () => {
  const root = repo();
  const newer = git(root, 'commit-tree', git(root, 'write-tree'), '-m', 'deploy\n\nObservatorium-Release: v56.12.1.1\n');
  git(root, 'update-ref', REF, newer);
  assert.equal(publish(opts(root)).reason, 'older-release');
});

test('publish refuses when the checkout is not at the tag, or is dirty', () => {
  const root = repo();
  writeFileSync(join(root, 'observatorium/data/claims.yaml'), `${readFileSync(join(root, 'observatorium/data/claims.yaml'), 'utf8')}\n# edit\n`);
  assert.equal(publish(opts(root)).reason, 'dirty-tree');
  git(root, 'commit', '-q', '-am', 'after the release');
  assert.equal(publish(opts(root)).reason, 'not-at-tag');
});

test('publish refuses a history that does not end at the tag', () => {
  const root = repo();
  git(root, 'tag', 'v56.11.8.1');
  assert.equal(publish({...opts(root), tag: 'v56.11.8.1'}).reason, 'stale-snapshot');
});

test('verifyDeploy: trailers must match the built data', () => {
  const root = repo();
  publish(opts(root));
  const message = git(root, 'log', '-1', '--format=%B', REF);
  const history = git(root, 'show', `${REF}:dist/data/history.json`);
  assert.deepEqual(verifyDeploy({message, historyJson: history}), {ok: true, release: TAG});
  assert.equal(verifyDeploy({message: 'deploy\n', historyJson: history}).reason, 'missing-trailer');
  const other = JSON.stringify({...JSON.parse(history), latest: 'v56.11.6.1'});
  assert.equal(verifyDeploy({message, historyJson: other}).reason, 'trailer-mismatch');
  const resnap = JSON.stringify({...JSON.parse(history), snapshotSha256: '0'.repeat(64)});
  assert.equal(verifyDeploy({message, historyJson: resnap}).reason, 'snapshot-mismatch');
});
