#!/usr/bin/env node
// @trace order:2066-obsv, spec:observatorium-dashboard
// The manual publish step (operator ruling 2026-11-09: no auto-deploy
// anywhere; fleet lead Q1, 2026-11-10: the deploy branch holds the BUILT site).
//
//   git checkout v56.11.7.1            # the release, clean
//   node observatorium/site/publish.mjs v56.11.7.1
//
// builds the site for that release (history, newest tag and the named tag
// must agree), then writes ONE commit onto the LOCAL ref
// refs/heads/deploy/observatorium whose tree is
//
//   wrangler.jsonc   assets ./dist, no build command
//   package.json     `npm run deploy` = verify, then wrangler deploy
//   verify.mjs       the stale-ship guard (site/verify.mjs)
//   dist/**          the generated site
//
// with Observatorium-Release / -Snapshot / -Source trailers. It refuses a
// release that is already published or older than the branch tip. It never
// pushes and never deploys: the operator inspects, pushes the ref by hand
// after a gate run, and runs `npm run deploy` from a checkout of it.
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {buildSite} from './build.mjs';
import {compareTags, newestTag, parseTrailer} from './trailer.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const DEPLOY_REF = 'refs/heads/deploy/observatorium';

export const DEPLOY_WRANGLER = `{
  // @trace order:2066-obsv, spec:observatorium-dashboard
  // Written by observatorium/site/publish.mjs. Static assets only: there is no
  // build command, so nothing ever builds on Cloudflare, and no Workers Builds
  // trigger is connected to this branch. Deployed by hand: npm run deploy.
  "name": "tillandsias-observatorium",
  "compatibility_date": "2026-10-13",
  "workers_dev": false,
  "routes": [
    { "pattern": "observatorium.tillandsias.org", "custom_domain": true }
  ],
  "assets": {
    "directory": "./dist",
    "not_found_handling": "404-page"
  }
}
`;
export const DEPLOY_PACKAGE = `${JSON.stringify({
  name: 'tillandsias-observatorium-deploy', private: true, type: 'module',
  scripts: {verify: 'node verify.mjs', deploy: 'node verify.mjs && wrangler deploy'},
  devDependencies: {wrangler: '4.150.0'},
}, null, 2)}\n`;

function gitIn(cwd) {
  return (args, input) => {
    const r = spawnSync('git', args, {cwd, input, encoding: 'utf8', maxBuffer: 64 << 20});
    return {ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim()};
  };
}

/** Build a git tree from {path: content} with plumbing only; returns its id. */
function writeTree(git, files) {
  const root = {};
  for (const [path, content] of Object.entries(files)) {
    const parts = path.split('/');
    let node = root;
    for (const dir of parts.slice(0, -1)) node = node[dir] ??= {};
    node[parts.at(-1)] = content;
  }
  const mk = (node) => {
    const lines = Object.keys(node).sort().map((name) => {
      const v = node[name];
      if (typeof v === 'string') {
        const blob = git(['hash-object', '-w', '--stdin'], v);
        if (!blob.ok) throw Error(`hash-object: ${blob.err}`);
        return `100644 blob ${blob.out}\t${name}`;
      }
      return `040000 tree ${mk(v)}\t${name}`;
    });
    const tree = git(['mktree'], `${lines.join('\n')}\n`);
    if (!tree.ok) throw Error(`mktree: ${tree.err}`);
    return tree.out;
  };
  return mk(root);
}

export function publish({repo, tag, ref = DEPLOY_REF, builtAt = new Date().toISOString()}) {
  const refuse = (reason, detail) => ({ok: false, reason, detail});
  const git = gitIn(repo);
  const top = git(['rev-parse', '--show-toplevel']);
  if (!top.ok) return refuse('no-git', `${repo} is not a git checkout`);
  const head = git(['rev-parse', 'HEAD']).out;
  const tagCommit = git(['rev-parse', '--verify', '--quiet', `refs/tags/${tag}^{commit}`]);
  if (!tagCommit.ok) return refuse('no-release-tag', `no tag ${tag}`);
  if (git(['status', '--porcelain', '--', 'observatorium']).out) return refuse('dirty-tree', 'observatorium/ has uncommitted changes');
  if (tagCommit.out !== head) return refuse('not-at-tag', `HEAD is ${head.slice(0, 12)}, ${tag} is ${tagCommit.out.slice(0, 12)}; check out the release first`);

  const tip = git(['rev-parse', '--verify', '--quiet', `${ref}^{commit}`]);
  const tipRelease = tip.ok ? parseTrailer(git(['log', '-1', '--format=%B', tip.out]).out) : null;
  if (tipRelease && /^v\d+\.\d+\.\d+\.\d+$/.test(tipRelease)) {
    const c = compareTags(tag, tipRelease);
    if (c === 0) return refuse('already-published', `${ref} already serves ${tag}`);
    if (c < 0) return refuse('older-release', `${ref} serves ${tipRelease}, newer than ${tag}`);
  }

  const app = resolve(top.out, 'observatorium');
  const historyText = readFileSync(resolve(app, 'history/snapshots.jsonl'), 'utf8');
  const tags = git(['tag', '--merged', 'HEAD', '--list', 'v*']).out.split('\n').map((s) => s.trim());
  let site;
  try {
    site = buildSite(historyText, {newestTag: newestTag(tags), trailer: tag, deploy: true, builtAt,
      claimsText: readFileSync(resolve(app, 'data/claims.yaml'), 'utf8')});
  } catch (e) {
    const m = e.message.match(/^refused:([a-z-]+): ?([\s\S]*)$/);
    return m ? refuse(m[1], m[2]) : refuse('build-failed', e.message);
  }

  const files = {'wrangler.jsonc': DEPLOY_WRANGLER, 'package.json': DEPLOY_PACKAGE,
    'verify.mjs': readFileSync(resolve(here, 'verify.mjs'), 'utf8')};
  for (const [path, content] of site.files) files[`dist/${path}`] = content;
  const tree = writeTree(git, files);
  const snapshot = createHash('sha256').update(historyText).digest('hex');
  const message = `deploy(observatorium): ${tag}\n\nBuilt by observatorium/site/publish.mjs from ${head}.\nPush by hand after a gate run, then: npm run deploy\n\nObservatorium-Release: ${tag}\nObservatorium-Snapshot: ${snapshot}\nObservatorium-Source: ${head}\n`;
  const commit = git(['commit-tree', tree, ...(tip.ok ? ['-p', tip.out] : []), '-F', '-'], message);
  if (!commit.ok) return refuse('commit-failed', commit.err);
  const upd = git(['update-ref', ref, commit.out, ...(tip.ok ? [tip.out] : [''])]);
  if (!upd.ok) return refuse('update-ref-failed', upd.err);
  return {ok: true, release: tag, commit: commit.out, ref};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const tag = process.argv[2];
  if (!tag) {
    console.error('usage: node observatorium/site/publish.mjs <release-tag>');
    process.exit(64);
  }
  const r = publish({repo: process.cwd(), tag});
  if (!r.ok) {
    console.error(`observatorium-publish: refused:${r.reason}: ${r.detail}`);
    process.exit(1);
  }
  console.log(`observatorium-publish: ok:${r.release}:${r.commit}`);
  console.log(`next: inspect it (git worktree add /tmp/obs-deploy ${r.ref}), push it by hand after ./build.sh --check`);
  console.log(`      (git push origin ${r.ref}), then from that checkout: npm install && npm run deploy`);
}
