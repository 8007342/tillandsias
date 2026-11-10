// @trace spec:observatorium-dashboard, order:2066-obsv
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parseArgs} from './build.mjs';

test('scripts/build.mjs is the release cut only', () => {
  assert.deepEqual(parseArgs(['--release-snapshot', 'v56.11.7.1']), {tag: 'v56.11.7.1'});
  assert.throws(() => parseArgs([]), /site\/build\.mjs/);
  assert.throws(() => parseArgs(['--metrics-only']), /release-snapshot/);
  assert.throws(() => parseArgs(['--release-snapshot', 'latest']), /release tag/);
});
