// @trace spec:observatorium-dashboard
// @trace order:1661-vckd
import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {collect, countSpec, EPOCH, summarizePlan} from './collect.mjs';
import {commitSeries, logarithm, project} from './precompute.mjs';

function snapshot(date = '2026-10-13T12:00:00Z') {
  return {schemaVersion: 1, epoch: EPOCH, measuredAt: date, revision: 'abcdef', gaps: [], details: {specs: [], plan: []}, current: {specs: {files: 2, requirements: 3, scenarios: 4}, plan: {total: 6, fragments: 2, states: {ready: 6}}, residual: {value: null}, commits: {total: 8}}};
}
test('Markdown code fences cannot inflate heading totals', () => {
  assert.deepEqual(countSpec('### Requirement: A\n#### Scenario: B\n```md\n### Requirement: fake\n```\n~~~\n#### Scenario: fake\n~~~'), {requirements: 1, scenarios: 1});
});
test('canonical folded rows retain exact status vocabulary, duplicates refuse', () => {
  const rows = [{packet_id: 'a', status: 'in_progress'}, {packet_id: 'b', status: 'verified'}];
  assert.deepEqual(summarizePlan(rows).states, {in_progress: 1, verified: 1});
  assert.throws(() => summarizePlan([...rows, rows[0]]), /duplicate/);
});
test('log transform preserves zero and missing distinctly, rejects negative', () => {
  assert.equal(logarithm(0), 0);
  assert.equal(logarithm(null), null);
  assert.equal(logarithm(99), 2);
  assert.throws(() => logarithm(-1), /Invalid count/);
});
test('history never fabricates earlier snapshots or joins legacy measurement units', () => {
  const result = project(snapshot(), [], [{date: '2026-08-01', value: 8}], {history: [{date: '2026-08-01', residual_cc: 0}]});
  const specs = result.graph.series.find(s => s.id === 'specs');
  assert.deepEqual(specs.points[0], {date: '2026-08-01', value: null, y: null});
  assert.equal(result.series.length, 1);
  assert.equal(result.graph.series.find(s => s.id === 'residual').points.at(-1).value, null);
  assert.equal(result.graph.series.find(s => s.id === 'legacy_gate_residual').epoch, 'legacy-weighted-gate-checks');
  assert.throws(() => project(snapshot(), [{...snapshot(), schemaVersion: 99}]), /schema/);
});
test('changed epochs remain separate and do not inherit current metric definitions', () => {
  const previous = {...snapshot('2026-09-01T12:00:00Z'), epoch: 'old-counting-rule'};
  const result = project(snapshot(), [previous]);
  const old = result.graph.series.find(s => s.id === 'specs@old-counting-rule');
  const current = result.graph.series.find(s => s.id === 'specs');
  assert.equal(old.points.length, 1);
  assert.equal(current.points.length, 1);
  assert.notEqual(old.epoch, current.epoch);
  assert.match(old.definition, /unavailable/);
  assert.equal(current.unit, 'files');
  assert.equal(current.interpolation, 'none');
});
test('observed regressions and duplicate snapshot handling preserve measured values', () => {
  const before = snapshot('2026-10-12T12:00:00Z');
  before.current.specs.files = 4;
  const result = project(snapshot(), [before, snapshot()]);
  assert.deepEqual(result.graph.series.find(s => s.id === 'specs').points.map(p => p.value), [4, 2]);
});
test('commits group by UTC date regardless of git traversal order', () => {
  const first = Date.parse('2026-10-12T23:59:59Z') / 1000;
  assert.deepEqual(commitSeries(`${first + 1}\n${first}\n${first}\n`), [{date: '2026-10-12', value: 2}, {date: '2026-10-13', value: 3}]);
});
test('missing plan tool is a visible unknown, never a zero count', () => {
  const root = mkdtempSync(join(tmpdir(), 'observatorium-metrics-'));
  const old = process.env.TILLANDSIAS_PLAN_BIN;
  try {
    const git = (...args) => execFileSync('git', args, {cwd: root, stdio: 'ignore'});
    git('init'); git('config', 'user.email', 'test@example.invalid'); git('config', 'user.name', 'Fixture');
    mkdirSync(join(root, 'plan')); writeFileSync(join(root, 'plan/index.yaml'), 'packets: []\n');
    git('add', '.'); git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'fixture');
    process.env.TILLANDSIAS_PLAN_BIN = join(root, 'absent-plan-tool');
    const result = collect(root);
    assert.equal(result.current.plan.total, null);
    assert.equal(result.current.specs, null);
    assert.equal(result.current.residual.value, null);
    assert.ok(result.gaps.some(gap => gap.startsWith('Folded plan unavailable:')));
  } finally {
    if (old === undefined) delete process.env.TILLANDSIAS_PLAN_BIN; else process.env.TILLANDSIAS_PLAN_BIN = old;
    rmSync(root, {recursive: true, force: true});
  }
});
