// @trace order:2066-obsv, spec:observatorium-dashboard
// Honesty rule 8 (design.md §3): a stale snapshot cannot ship. Offline, no
// network: the history's last release, the newest v* tag reachable from HEAD
// and HEAD's `Observatorium-Release:` trailer must agree before a deploy build
// writes anything. A preview build (the default) skips only the trailer, and
// says "preview build" on every page.
import {spawnSync} from 'node:child_process';

const TAG = /^v(\d+)\.(\d+)\.(\d+)\.(\d+)$/;

export function compareTags(a, b) {
  const pa = a.match(TAG).slice(1).map(Number);
  const pb = b.match(TAG).slice(1).map(Number);
  for (let i = 0; i < 4; i++) if (pa[i] !== pb[i]) return pa[i] - pb[i];
  return 0;
}

export function newestTag(tags) {
  const release = tags.filter((t) => TAG.test(t)).sort(compareTags);
  return release.at(-1) ?? null;
}

export function parseTrailer(message) {
  const m = message.match(/^Observatorium-Release:[ \t]*(\S+)[ \t]*$/m);
  return m ? m[1] : null;
}

export function checkRelease({snapshotRelease, newestTag: tag, trailer, deploy}) {
  const refuse = (reason, detail) => ({ok: false, reason, detail});
  if (!snapshotRelease || !TAG.test(snapshotRelease)) return refuse('no-snapshot', 'history/snapshots.jsonl has no release row');
  if (tag && compareTags(snapshotRelease, tag) !== 0) {
    return refuse('stale-snapshot', `history ends at ${snapshotRelease}, newest reachable tag is ${tag}`);
  }
  if (deploy) {
    if (!tag) return refuse('no-release-tag', 'no v* tag is reachable from HEAD');
    if (!trailer) return refuse('missing-trailer', `HEAD has no "Observatorium-Release: ${snapshotRelease}" trailer`);
    if (trailer !== snapshotRelease) return refuse('trailer-mismatch', `trailer names ${trailer}, history ends at ${snapshotRelease}`);
  }
  return {ok: true, preview: !deploy, release: snapshotRelease};
}

/** Read the two git facts from a checkout. Missing git reads as null. */
export function gitFacts(cwd) {
  const git = (...args) => {
    const r = spawnSync('git', args, {cwd, encoding: 'utf8'});
    return r.status === 0 ? r.stdout : null;
  };
  const tags = git('tag', '--merged', 'HEAD', '--list', 'v*');
  const message = git('log', '-1', '--format=%B');
  return {newestTag: tags ? newestTag(tags.split('\n').map((s) => s.trim())) : null,
    trailer: message ? parseTrailer(message) : null};
}
