// @trace spec:observatorium-dashboard
// @trace order:1661-vckd
import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {collect, countSpec, EPOCH, summarizePlan} from './collect.mjs';
import {commitSeries, logarithm, project} from './precompute.mjs';

function snapshot(date = '2026-10-13T12:00:00Z') {
  return {schemaVersion: 1, epoch: EPOCH, measuredAt: date, revision: 'abcdef0123456789abcdef0123456789abcdef0123', dirty: false, gaps: [], details: {specs: [], plan: []}, current: {specs: {files: 2, requirements: 3, scenarios: 4}, plan: {total: 6, fragments: 2, states: {ready: 6}}, residual: {value: null}, commits: {total: 8}}};
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
test('successful canonical query with skipped fragment warning remains unavailable', () => {
  const root = mkdtempSync(join(tmpdir(), 'observatorium-damaged-plan-'));
  const old = process.env.TILLANDSIAS_PLAN_BIN;
  try {
    const git = (...args) => execFileSync('git', args, {cwd: root, stdio: 'ignore'});
    git('init'); git('config', 'user.email', 'test@example.invalid'); git('config', 'user.name', 'Fixture');
    mkdirSync(join(root, 'plan')); writeFileSync(join(root, 'plan/index.yaml'), 'packets: []\n');
    git('add', '.'); git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'fixture');
    const binary = join(root, 'fixture-plan');
    writeFileSync(binary, '#!/bin/sh\nprintf "[]\\n"\nprintf "warning: ledger fragment damaged.yaml does not parse and was SKIPPED — its contents are not in the answers below\\n" >&2\n');
    chmodSync(binary, 0o755);
    process.env.TILLANDSIAS_PLAN_BIN = binary;
    const result = collect(root);
    assert.equal(result.current.plan.total, null);
    assert.deepEqual(result.details.plan, []);
    assert.ok(result.gaps.some(gap => gap.includes('Incomplete canonical ledger') && gap.includes('damaged.yaml')));
  } finally {
    if (old === undefined) delete process.env.TILLANDSIAS_PLAN_BIN; else process.env.TILLANDSIAS_PLAN_BIN = old;
    rmSync(root, {recursive: true, force: true});
  }
});
test('a release-cut snapshot names its release tag; a bad tag is refused (1661-vckd)', () => {
  const repo = mkdtempSync(join(tmpdir(), 'observatorium-release-'));
  try {
    execFileSync('git', ['init', '-q', repo]);
    writeFileSync(join(repo, 'README.md'), 'x\n');
    execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '.']);
    execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'x']);
    const released = collect(repo, {release: 'v56.10.13.1'});
    assert.equal(released.release, 'v56.10.13.1');
    assert.equal('release' in collect(repo, {}), false, 'a deploy observation names no release');
    assert.throws(() => collect(repo, {release: 'latest'}), /Invalid release tag/);
  } finally { rmSync(repo, {recursive: true, force: true}); }
});
test('an unmeasured CentiColon grade is a visible gap, never a residual value (1670-gcwu)', () => {
  const repo = mkdtempSync(join(tmpdir(), 'observatorium-unmeasured-'));
  const old = process.env.TILLANDSIAS_PLAN_BIN;
  try {
    execFileSync('git', ['init', '-q', repo]);
    mkdirSync(join(repo, 'scripts'));
    const fake = (grade) => writeFileSync(join(repo, 'scripts/centicolon-grade.sh'),
      `mkdir -p "$TILLANDSIAS_REPO_ROOT/$TILLANDSIAS_CENTICOLON_DIR"\nprintf '%s' '${JSON.stringify(grade)}' > "$TILLANDSIAS_REPO_ROOT/$TILLANDSIAS_CENTICOLON_DIR/grade.json"\n`);
    fake({schema: 'centicolon-grade-observed/1', measured: false, unmeasured_reason: 'zero-resolved-requirement-keys', R: 4, denominator: 4, satisfied: 0, records: 0});
    execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '.']);
    execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'x']);
    process.env.TILLANDSIAS_PLAN_BIN = join(repo, 'absent-plan-tool');
    const unmeasured = collect(repo, {grade: true});
    assert.equal(unmeasured.current.residual.value, null, 'an unmeasured R is not a value');
    assert.equal(unmeasured.current.residual.unmeasured, true);
    assert.ok(unmeasured.gaps.some(gap => gap.startsWith('CentiColon grade unmeasured (zero-resolved-requirement-keys)')));
    fake({schema: 'centicolon-grade-observed/1', measured: true, R: 2, denominator: 4, satisfied: 2, records: 1});
    const measured = collect(repo, {grade: true});
    assert.equal(measured.current.residual.value, 2, 'a measured grade keeps its R');
  } finally {
    if (old === undefined) delete process.env.TILLANDSIAS_PLAN_BIN; else process.env.TILLANDSIAS_PLAN_BIN = old;
    rmSync(repo, {recursive: true, force: true});
  }
});
test('the headline grade is the latest release cut; the deploy grade is display-only and never joins that series (1661-vckd)', () => {
  const live = snapshot('2026-10-14T00:00:00Z');
  live.current.residual = {value: 1529, denominator: 1529, satisfied: 0, traced: 2, positivelyTested: 0, records: 0};
  const cut = snapshot('2026-10-13T20:00:00Z');
  cut.release = 'v56.10.13.1';
  cut.current.residual = {source: 'centicolon-grade-observed/1', value: 1527, denominator: 1529, satisfied: 2, traced: 0, positivelyTested: 2, records: 1399};
  const unmeasuredCut = snapshot('2026-10-12T20:00:00Z');
  unmeasuredCut.release = 'v56.10.12.1';
  const result = project(live, [unmeasuredCut, cut]);
  assert.equal(result.current.residual.value, 1527, 'the headline is the release cut, not the deploy');
  assert.equal(result.current.residual.release, 'v56.10.13.1');
  assert.match(result.current.residual.reason, /2 tested of 1529/);
  assert.equal(result.current.residual.revision, cut.revision);
  assert.match(result.current.residual.recordScope, /does not identify runs matching/);
  assert.equal(result.current.residualLive.displayOnly, true);
  assert.equal(result.current.residualLive.traced, 2);
  assert.match(result.current.residualLive.label, /display-only/);
  assert.deepEqual(result.graph.series.find(s => s.id === 'residual').points.map(p => p.value), [null, 1527, null]);
  const none = project(live, []);
  assert.equal(none.current.residual.value, null, 'no release cut: no headline grade, never the deploy grade');
  assert.ok(none.gaps.some(gap => gap.startsWith('No release-cut snapshot with a measured grade yet')));
});
test('the release cut refuses to append an unmeasured grade (1661-vckd)', () => {
  const repo = mkdtempSync(join(tmpdir(), 'observatorium-cut-'));
  const old = process.env.TILLANDSIAS_PLAN_BIN;
  try {
    execFileSync('git', ['init', '-q', repo]);
    mkdirSync(join(repo, 'scripts'));
    const fake = (grade) => writeFileSync(join(repo, 'scripts/centicolon-grade.sh'),
      `mkdir -p "$TILLANDSIAS_REPO_ROOT/$TILLANDSIAS_CENTICOLON_DIR"\nprintf '%s' '${JSON.stringify(grade)}' > "$TILLANDSIAS_REPO_ROOT/$TILLANDSIAS_CENTICOLON_DIR/grade.json"\n`);
    fake({schema: 'centicolon-grade-observed/1', measured: false, unmeasured_reason: 'zero-resolved-requirement-keys', R: 4, denominator: 4, satisfied: 0, records: 0});
    execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '.']);
    execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'x']);
    const history = join(repo, 'history.jsonl');
    const cut = () => execFileSync(process.execPath, [new URL('./collect.mjs', import.meta.url).pathname, '--root', repo, '--output', join(repo, 'out.json'), '--history', history, '--release', 'v56.10.13.1', '--grade'], {stdio: 'pipe', env: {...process.env, TILLANDSIAS_PLAN_BIN: join(repo, 'absent')}});
    assert.throws(cut, /Refusing the v56.10.13.1 release snapshot/);
    assert.equal(existsSync(history), false, 'nothing appended');
    fake({schema: 'centicolon-grade-observed/1', measured: true, R: 4, denominator: 4, satisfied: 0, records: 0, histogram: {traced: 4, positively_tested: 0}});
    assert.throws(cut, /not a measurement over recorded litmus results/, 'a measured grade with no recorded results is refused too');
    fake({schema: 'centicolon-grade-observed/1', measured: true, R: 3, denominator: 4, satisfied: 1, records: 7, histogram: {traced: 3, positively_tested: 1}});
    writeFileSync(join(repo, '.gitignore'), 'target/\nout.json\nhistory.jsonl\n');
    execFileSync('git', ['-C', repo, 'add', 'scripts/centicolon-grade.sh', '.gitignore']);
    execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'record fixture grade']);
    cut();
    const line = JSON.parse(readFileSync(history, 'utf8').trim());
    assert.equal(line.release, 'v56.10.13.1');
    assert.equal(line.current.residual.value, 3);
    assert.equal(line.current.residual.positivelyTested, 1);
    assert.throws(cut, /duplicate release snapshot/);
    assert.equal(readFileSync(history, 'utf8').trim().split('\n').length, 1);
  } finally {
    if (old === undefined) delete process.env.TILLANDSIAS_PLAN_BIN; else process.env.TILLANDSIAS_PLAN_BIN = old;
    rmSync(repo, {recursive: true, force: true});
  }
});
