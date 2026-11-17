// @trace order:2066-obsv, spec:observatorium-dashboard
// Honesty rule 8: a stale snapshot cannot ship. Red-first against a check that
// accepted everything.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {checkRelease, compareTags, newestTag, parseTrailer} from './trailer.mjs';

const T = 'v56.11.7.1';

test('deploy: history, newest tag and trailer agree', () => {
  assert.deepEqual(checkRelease({snapshotRelease: T, newestTag: T, trailer: T, deploy: true}), {ok: true, preview: false, release: T});
});

test('deploy: a history older than the newest tag is a stale snapshot', () => {
  const r = checkRelease({snapshotRelease: 'v56.11.6.1', newestTag: T, trailer: T, deploy: true});
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'stale-snapshot');
});

test('deploy: a commit without the trailer cannot ship', () => {
  const r = checkRelease({snapshotRelease: T, newestTag: T, trailer: null, deploy: true});
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'missing-trailer');
});

test('deploy: a trailer naming another release cannot ship', () => {
  const r = checkRelease({snapshotRelease: T, newestTag: T, trailer: 'v56.11.6.1', deploy: true});
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'trailer-mismatch');
});

test('deploy: no reachable release tag cannot ship', () => {
  const r = checkRelease({snapshotRelease: T, newestTag: null, trailer: T, deploy: true});
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'no-release-tag');
});

test('preview: no trailer needed, but a stale snapshot still refuses', () => {
  assert.deepEqual(checkRelease({snapshotRelease: T, newestTag: T, trailer: null, deploy: false}), {ok: true, preview: true, release: T});
  assert.equal(checkRelease({snapshotRelease: 'v56.11.6.1', newestTag: T, trailer: null, deploy: false}).reason, 'stale-snapshot');
});

test('tags compare numerically, not lexically', () => {
  assert.ok(compareTags('v56.11.10.1', 'v56.11.9.3') > 0);
  assert.equal(newestTag(['v56.10.31.2', 'v56.11.7.1', 'v56.11.10.1', 'stable', 'v56.11.6.1']), 'v56.11.10.1');
  assert.equal(newestTag(['stable']), null);
});

test('the trailer is read from the commit message', () => {
  assert.equal(parseTrailer(`deploy observatorium\n\nObservatorium-Release: ${T}\nObservatorium-Snapshot: abc\n`), T);
  assert.equal(parseTrailer('deploy observatorium\n\nObservatorium-Release is mentioned in prose\n'), null);
});
