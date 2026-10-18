// @trace order:1782-bek5, spec:observatorium-dashboard
import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {collect, DEFINITIONS, EPOCH} from './collect.mjs';
import {project} from './precompute.mjs';
import {gateInventory} from './inventory.mjs';
import {releaseEvidence, validateResidual} from './evidence.mjs';

function snapshot(date = '2026-10-18T03:00:00Z') {
  return {schemaVersion: 1, epoch: EPOCH, definitions: DEFINITIONS, measuredAt: date, revision: 'a'.repeat(40), dirty: false,
    current: {specs: {files: 1, requirements: 1, scenarios: 2}, plan: {total: 1, fragments: 1, states: {ready: 1}}, commits: {total: 1}, residual: {value: null}},
    details: {specs: [], plan: [], obligations: []}, gaps: []};
}
function release(date = '2026-10-17T03:00:00Z') {
  const row = snapshot(date);
  row.release = 'v56.10.17.1';
  row.current.residual = {source: 'centicolon-grade-observed/1', value: 2, denominator: 2, satisfied: 0, records: 10,
    histogram: {declared: 1, traced: 1, positively_tested: 0}, reasons: {'no-binding': 1, unrun: 1}};
  return row;
}
test('a zero-earned release remains honest, with its own provenance and global-record limit', () => {
  const historical = release();
  const live = snapshot(); live.revision = 'b'.repeat(40);
  const result = project(live, [historical]);
  assert.equal(result.current.residual.satisfied, 0);
  assert.equal(result.current.residual.denominator, 2);
  assert.equal(result.current.residual.revision, historical.revision);
  assert.equal(result.current.residual.measuredAt, historical.measuredAt);
  assert.equal(result.current.residualLive.revision, live.revision);
  assert.match(result.current.residual.recordScope, /does not identify runs matching/);
  assert.ok(result.current.residual.provenance.limitations.some(s => s.includes('historical snapshot')));
  assert.equal(result.graph.series.find(s => s.id === 'earned').points[0].value, 0);
  assert.equal(result.graph.series.find(s => s.id === 'denominator').points[0].value, 2);
});
test('malformed or unsupported release evidence becomes a gap and cannot replace a valid headline', () => {
  for (const mutate of [
    s => { s.current.residual.records = 0; },
    s => { s.current.residual.source = 'legacy-weighted-gate-checks'; },
    s => { s.current.residual.satisfied = 3; },
    s => { s.current.residual.denominator = 2.5; },
    s => { s.current.residual.measured = false; },
    s => { s.current.residual.histogram.traced = 2; },
    s => { s.current.residual.reasons.unrun = 2; },
    s => { s.current.residual.provenance = {revision: 'c'.repeat(40)}; },
    s => { s.revision = ''; },
  ]) {
    const good = release('2026-10-15T03:00:00Z'), bad = release();
    good.release = 'v56.10.15.1'; mutate(bad);
    const result = project(snapshot(), [good, bad]);
    assert.equal(result.current.residual.release, good.release);
    assert.equal(result.graph.series.find(s => s.id === 'residual').points[1].value, null);
    assert.ok(result.gaps.some(g => g.includes('grade unavailable')));
  }
});
test('dirty release evidence retains its base revision and names uncommitted source changes', () => {
  const row = release(); row.dirty = true;
  const grade = releaseEvidence(row);
  assert.equal(grade.value, 2);
  assert.equal(grade.dirty, true);
  assert.equal(grade.revision, row.revision);
  assert.ok(grade.provenance.limitations.some(s => s.includes('base commit')));
});
test('denominator and identity changes are named scope events, with independent epochs', () => {
  const before = release('2026-10-15T03:00:00Z'), after = release('2026-10-16T03:00:00Z');
  after.release = 'v56.10.16.1';
  after.current.residual = {...after.current.residual, value: 3, denominator: 3, histogram: {declared: 2, traced: 1, positively_tested: 0}, reasons: {'no-binding': 2, unrun: 1}};
  const result = project(snapshot(), [before, after]);
  assert.match(result.scopeChanges[0].label, /2 → 3/);
  assert.match(result.graph.series.find(s => s.id === 'residual').points[1].scopeChange, /scope changed/);
  before.current.residual.provenance = {scopeSha256: 'a'};
  after.current.residual = {...before.current.residual, provenance: {scopeSha256: 'b'}};
  assert.match(project(snapshot(), [before, after]).scopeChanges[0].label, /identities changed/);
  after.epoch = 'repository-observation-v1';
  const separated = project(snapshot(), [before, after]);
  assert.ok(separated.graph.series.some(s => s.id === 'residual@repository-observation-v1'));
  assert.match(separated.scopeChanges[0].label, /epoch changed/);
});
test('immutable v1 release history remains usable with explicit missing provenance', () => {
  const row = JSON.parse(readFileSync(new URL('../history/snapshots.jsonl', import.meta.url), 'utf8').trim().split('\n')[0]);
  const grade = releaseEvidence(row);
  assert.equal(grade.satisfied, 0);
  assert.equal(grade.revision, row.revision);
  assert.equal(grade.declared + grade.traced + grade.positivelyTested, grade.denominator);
  assert.ok(grade.provenance.limitations.some(s => s.includes('no retained grade digest')));
});
test('invalid counts cannot hide inside arithmetic or histograms', () => {
  const grade = release().current.residual;
  assert.throws(() => validateResidual({...grade, denominator: '2'}), /safe integer/);
  assert.throws(() => validateResidual({...grade, satisfied: -1, value: 3}), /safe integer/);
  assert.throws(() => validateResidual({...grade, records: Number.MAX_SAFE_INTEGER + 1}), /safe integer/);
});
test('Lua inventory requires existing literal targets and deduplicates aliases without granting credit', () => {
  const root = mkdtempSync(join(tmpdir(), 'observatorium-inventory-'));
  try {
    mkdirSync(join(root, 'scripts/gate-steps.d'), {recursive: true});
    mkdirSync(join(root, 'scripts/lua'));
    writeFileSync(join(root, 'scripts/lua/check-a.lua'), 'verdict.ok("fixture")\n');
    writeFileSync(join(root, 'scripts/lua/unreferenced.lua'), 'verdict.ok("unused")\n');
    writeFileSync(join(root, 'scripts/check-b.sh'), 'true\n');
    writeFileSync(join(root, 'scripts/gate-steps.d/a.step'), 'STEP_LUA="scripts/lua/check-a.lua"\n');
    writeFileSync(join(root, 'scripts/gate-steps.d/alias.step'), 'STEP_LUA="scripts/lua/check-a.lua"\n');
    writeFileSync(join(root, 'scripts/gate-steps.d/b.step'), 'STEP_SCRIPT="scripts/check-b.sh"\n');
    const measured = gateInventory(root);
    assert.equal(measured.summary.lua, 1); assert.equal(measured.summary.shell, 1); assert.equal(measured.summary.total, 2);
    assert.equal(measured.details.find(row => row.language === 'lua').manifests.length, 2);
    assert.match(measured.summary.definition, /inventory only/);
    writeFileSync(join(root, 'scripts/gate-steps.d/broken.step'), 'STEP_LUA="scripts/lua/missing.lua"\n');
    assert.equal(gateInventory(root).summary.total, null);
    assert.match(gateInventory(root).summary.unavailable[0], /absent/);
    writeFileSync(join(root, 'scripts/gate-steps.d/broken.step'), 'STEP_LUA="$ROOT/generated.lua"\n');
    assert.match(gateInventory(root).summary.unavailable[0], /nonliteral/);
  } finally { rmSync(root, {recursive: true, force: true}); }
});
test('fresh collection preserves obligation rows, scope identity and grade evidence digest', () => {
  const root = mkdtempSync(join(tmpdir(), 'observatorium-obligations-'));
  try {
    execFileSync('git', ['init', '-q', root]);
    mkdirSync(join(root, 'scripts'));
    const grade = {schema: 'centicolon-grade-observed/1', measured: true, R: 1, denominator: 2, satisfied: 1, records: 7,
      histogram: {declared: 0, traced: 1, positively_tested: 1}, residue_reasons: {unrun: 1}, obligations: [
        {id: 'cc:aaaa:a', req_id: 'aaaa', spec: 'alpha', state: 'positively_tested', reason: 'green', host: 'fixture', regime: 'linux'},
        {id: 'cc:bbbb:b', req_id: 'bbbb', spec: 'alpha', state: 'traced', reason: 'unrun'},
      ]};
    const setGrade = value => writeFileSync(join(root, 'scripts/centicolon-grade.sh'), `mkdir -p "$TILLANDSIAS_CENTICOLON_DIR"\ncat > "$TILLANDSIAS_CENTICOLON_DIR/grade.json" <<'GRADE'\n${JSON.stringify(value)}\nGRADE\n`);
    setGrade(grade);
    execFileSync('git', ['-C', root, 'add', '.']);
    execFileSync('git', ['-C', root, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture']);
    const measured = collect(root, {grade: true});
    assert.equal(measured.details.obligations.length, 2);
    assert.equal(measured.details.obligations[0].host, 'fixture');
    assert.equal(measured.current.residual.histogram.positively_tested, 1);
    assert.match(measured.current.residual.provenance.gradeSha256, /^[a-f0-9]{64}$/);
    assert.match(measured.current.residual.provenance.scopeSha256, /^[a-f0-9]{64}$/);
    setGrade({...grade, obligations: [grade.obligations[0], grade.obligations[0]]});
    const invalid = collect(root, {grade: true});
    assert.equal(invalid.current.residual.value, null);
    assert.deepEqual(invalid.details.obligations, []);
    assert.match(invalid.current.residual.reason, /duplicate obligation/);
  } finally { rmSync(root, {recursive: true, force: true}); }
});
