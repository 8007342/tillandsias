// @trace order:2066-obsv, spec:observatorium-dashboard
// End to end: the committed history builds, lints clean and publishes no host.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {buildSite} from './build.mjs';

const history = readFileSync(new URL('../history/snapshots.jsonl', import.meta.url), 'utf8');
const facts = {newestTag: 'v56.11.7.1', trailer: null, deploy: false, builtAt: '2026-11-09T18:02:00Z'};

test('the committed history builds a clean Home page', () => {
  const {files, violations} = buildSite(history, facts);
  assert.deepEqual(violations, []);
  const home = files.get('index.html');
  assert.match(home, /<main id="main">/);
  assert.match(home, /data-field="latest.residual.value">1,571</);
  assert.match(home, /preview build/);
  assert.ok(files.has('data/history.json'));
  assert.ok(files.has('style.css'));
  assert.doesNotMatch(home, /<script/);
});

test('a stale history refuses to build', () => {
  assert.throws(() => buildSite(history, {...facts, newestTag: 'v56.11.9.1'}), /stale-snapshot/);
});

test('a deploy build without the trailer refuses', () => {
  assert.throws(() => buildSite(history, {...facts, deploy: true}), /missing-trailer/);
});

test('a deploy build with the trailer carries no preview banner', () => {
  const {files} = buildSite(history, {...facts, deploy: true, trailer: 'v56.11.7.1'});
  assert.doesNotMatch(files.get('index.html'), /preview build/);
});
