// @trace order:2066-obsv, spec:observatorium-dashboard
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {decodeTag, deriveView} from './view.mjs';
import {stepChart} from './chart.mjs';

const lines = readFileSync(new URL('../history/snapshots.jsonl', import.meta.url), 'utf8').trim().split('\n');
const rows = lines.map((l) => JSON.parse(l));

test('release tags decode to their date', () => {
  assert.deepEqual(decodeTag('v56.11.7.1'), {date: '2026-11-07', build: 1});
  assert.deepEqual(decodeTag('v56.1.2.10'), {date: '2026-01-02', build: 10});
});

test('a field the snapshot lacks stays null in the view', () => {
  const view = deriveView(rows);
  const first = view.releases[0];
  assert.equal(first.tag, 'v56.10.14.1');
  assert.equal(first.residual.measured, null);
  assert.equal(first.residual.histogram.declared, null);
  assert.equal(first.provenance.scopeSha256, null);
  for (const rung of ['absent', 'negatively_tested', 'runtime_observed', 'evidence_bundled']) {
    assert.equal(view.releases.at(-1).residual.histogram[rung], null, rung);
  }
});

test('scope, denominator and epoch changes start a new segment', () => {
  const view = deriveView(rows);
  const ids = view.releases.map((r) => r.segment.id);
  // 1536 (v1 epoch, no scope) | 1567 x4 | 1571 x2
  assert.deepEqual(ids, [1, 2, 2, 2, 2, 3, 3]);
  assert.deepEqual(view.releases[1].segment.reasons, ['epoch-changed', 'denominator-changed', 'scope-unknown-before']);
  assert.deepEqual(view.releases[5].segment.reasons, ['denominator-changed', 'scope-changed']);
});

test('no strict decrease has ever happened, so the count is null', () => {
  assert.equal(deriveView(rows).releasesSinceLastStrictDecrease, null);
});

test('an invalid grade fails the build closed', () => {
  const broken = structuredClone(rows);
  broken[2].current.residual.value = 1;
  assert.throws(() => deriveView(broken), /residual/);
});

test('history must be in release order', () => {
  assert.throws(() => deriveView([rows[1], rows[0]]), /order/);
});

test('the step chart draws one path per segment and a twin table', () => {
  const view = deriveView(rows);
  const {svg, table} = stepChart(view, {field: 'value', title: 'Residual'});
  assert.equal((svg.match(/class="series"/g) || []).length, 3);
  assert.match(svg, /role="img"/);
  assert.match(table, /<table/);
  assert.equal((table.match(/<tr>/g) || []).length, view.releases.length + 1);
});
