#!/usr/bin/env node
// @trace order:1661-vckd
// @trace spec:observatorium-dashboard
// freshness: auditor=forge-observatorium date=2026-10-13 verdict=updated scope=projection
// Deploy-time projection; the browser never reads git or recomputes history.
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {atomicJson, EPOCH, options} from './collect.mjs';

export function logarithm(value) {
  if (value === null || value === undefined) return null;
  if (!Number.isFinite(value) || value < 0) throw Error(`Invalid count: ${value}`);
  return Math.log10(1 + value);
}
export function commitSeries(log) {
  const days = new Map();
  for (const timestamp of log.trim().split('\n').filter(Boolean)) {
    const date = new Date(Number(timestamp) * 1000).toISOString().slice(0, 10);
    days.set(date, (days.get(date) || 0) + 1);
  }
  let total = 0;
  return [...days].sort(([a], [b]) => a.localeCompare(b)).map(([date, count]) => ({date, value: total += count}));
}
export function project(snapshot, history = [], commits = [], legacy = null) {
  if (snapshot.schemaVersion !== 1 || snapshot.epoch !== EPOCH || !Number.isFinite(Date.parse(snapshot.measuredAt))) throw Error('Unsupported or invalid snapshot');
  const gaps = [...snapshot.gaps, 'Specification and folded-plan history starts at actual observations; earlier values are unknown, never backfilled from current counts.', 'Specification totals count Markdown requirement/scenario headings, including inactive specs; they are not the active CentiColon denominator.'];
  const observations = new Map();
  for (const record of [...history, snapshot]) {
    if (record.schemaVersion !== 1 || typeof record.epoch !== 'string' || !record.epoch || !Number.isFinite(Date.parse(record.measuredAt))) throw Error('History contains an invalid measurement schema');
    observations.set(`${record.epoch}:${record.measuredAt}`, record);
  }
  const measured = [...observations.values()].sort((a, b) => a.measuredAt.localeCompare(b.measuredAt));
  const graphSeries = [];
  function add(id, label, points, epoch = EPOCH, source = 'measured repository snapshots', unit = 'count') {
    graphSeries.push({id, label, definition: label, unit, source, epoch, interpolation: 'none', points: points.map(point => ({...point, y: logarithm(point.value)}))});
  }
  add('commits', 'Available ancestor commits (cumulative by commit date)', commits, 'git-committer-timestamp-v1', 'git log HEAD --format=%ct', 'commits');
  const fields = [
    ['specs', 'Specification files', s => s.current.specs?.files ?? null, 'openspec/specs/*/spec.md', 'files'],
    ['requirements', 'Requirement headings outside fenced code (all spec statuses)', s => s.current.specs?.requirements ?? null, 'openspec/specs/*/spec.md', 'headings'],
    ['scenarios', 'Scenario headings outside fenced code (all spec statuses)', s => s.current.specs?.scenarios ?? null, 'openspec/specs/*/spec.md', 'headings'],
    ['plan', 'Folded plan packets', s => s.current.plan.total, 'tillandsias-plan query --json canonical fold', 'packets'],
    ['fragments', 'Plan index fragments', s => s.current.plan.fragments, 'plan/index.d/*.yaml', 'files'],
    ['residual', 'Unfulfilled scenario obligations at release cuts', s => s.release ? (s.current.residual?.value ?? null) : null, 'centicolon-grade-observed/1 at the release cut, after a recorded litmus run', 'scenario obligations'],
  ];
  const earliest = commits[0]?.date;
  const epochs = [...new Set(measured.map(s => s.epoch))];
  for (const epoch of epochs) {
    const records = measured.filter(s => s.epoch === epoch);
    const epochId = id => epoch === EPOCH ? id : `${id}@${epoch}`;
    for (const [id, label, value, source, unit] of fields) {
      const points = records.map(s => ({date: s.measuredAt, value: value(s)}));
      if (earliest && earliest < records[0].measuredAt) points.unshift({date: earliest, value: null});
      const metadata = records.at(-1).definitions?.[id];
      // Unknown historical definitions are explicitly named, never assigned today's semantics.
      const historicalLabel = metadata?.definition || `${id} (historical definition unavailable; ${epoch})`;
      add(epochId(id), epoch === EPOCH ? label : historicalLabel, points, epoch, epoch === EPOCH ? source : metadata?.source || 'historical snapshot; source definition unavailable', epoch === EPOCH ? unit : metadata?.unit || 'historical unit unavailable');
    }
    const states = new Set(records.flatMap(s => Object.keys(s.current.plan.states)));
    for (const state of [...states].sort()) {
      const points = records.map(s => ({date: s.measuredAt, value: s.current.plan.total === null ? null : (s.current.plan.states[state] || 0)}));
      if (earliest && earliest < records[0].measuredAt) points.unshift({date: earliest, value: null});
      add(epochId(`plan_${state}`), `Plan packets: ${state} (${epoch})`, points, epoch, epoch === EPOCH ? 'tillandsias-plan query --json canonical folded status' : 'historical snapshot; status definition unavailable', 'packets');
    }
    if (epoch !== EPOCH) gaps.push(`Historical epoch ${epoch} is plotted independently; absent historical definitions are labelled unavailable.`);
  }
  // The old dashboard measured weighted gate checks, not scenario obligations.
  // Keeping a separate epoch prevents a false claim that its zero means no debt.
  if (legacy && Array.isArray(legacy.history)) {
    const points = legacy.history.filter(row => Number.isFinite(Date.parse(row.date)) && Number.isFinite(row.residual_cc) && row.residual_cc >= 0).map(row => ({date: row.date, value: row.residual_cc})).sort((a, b) => a.date.localeCompare(b.date));
    if (points.length) add('legacy_gate_residual', 'Legacy gate-weight residual (different denominator)', points, 'legacy-weighted-gate-checks', 'docs/convergence/centicolon-dashboard.json history', 'weighted gate checks');
    gaps.push('Legacy gate residual is a separate measurement epoch from scenario obligations; the two series must not be joined or compared as the same unit.');
  }
  // Order 1661-vckd: Workers Builds runs no litmus, so a deploy can trace but
  // never positively test. The HEADLINE grade is the latest release-cut
  // snapshot (graded on a host after a recorded litmus run); the deploy's own
  // grade is shown, labelled display-only, and never joined to that series.
  const cut = measured.filter(s => s.release && Number.isInteger(s.current.residual?.value)).at(-1);
  const headline = cut
    ? {...cut.current.residual, release: cut.release, measuredAt: cut.measuredAt, reason: `Release ${cut.release} cut (${cut.measuredAt.slice(0, 10)}): graded after a recorded litmus run`}
    : {value: null, source: 'observatorium/history/snapshots.jsonl', reason: 'No release-cut snapshot with a measured grade yet; the live deploy grade below is display-only.'};
  if (!cut) gaps.push(headline.reason);
  const residualLive = {...snapshot.current.residual, displayOnly: true, label: 'Requirements traced at this deploy, display-only: Workers Builds runs no litmus, so nothing is positively tested here'};
  const series = measured.map(s => ({date: s.measuredAt, epoch: s.epoch, commits: s.current.commits.total, specs: s.current.specs?.files ?? null, plan: s.current.plan.total, residual: s.release ? (s.current.residual?.value ?? null) : null}));
  const epochRanges = epochs.map(id => {
    const records = measured.filter(s => s.epoch === id);
    return {id, start: records[0].measuredAt, end: records.at(-1).measuredAt};
  });
  return {schemaVersion: 1, generatedAt: snapshot.measuredAt, revision: snapshot.revision, dirty: snapshot.dirty, epoch: {...epochRanges.find(e => e.id === EPOCH), description: 'Actual working-tree observations; absent periods remain unknown.'}, epochs: epochRanges, current: {...snapshot.current, residual: headline, residualLive}, details: snapshot.details, series, graph: {scale: 'log10(1+x)', series: graphSeries}, gaps: [...new Set(gaps)], provenance: {commits: 'git log HEAD, committer timestamps, all reachable ancestors; missing days have no recorded commits, not repeated observations', specs: 'openspec/specs/*/spec.md headings outside fenced code', plan: snapshot.current.plan.source, legacy: legacy ? 'docs/convergence/centicolon-dashboard.json history (legacy weighted gates)' : null}};
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = options(process.argv.slice(2), ['root', 'snapshot', 'history', 'output']);
    if (!args.snapshot || !args.output) throw Error('Usage: precompute.mjs --root REPO --snapshot JSON [--history JSONL] --output WEB/data/metrics.json');
    const root = resolve(args.root || '.');
    const snapshot = JSON.parse(readFileSync(args.snapshot, 'utf8'));
    const history = args.history && existsSync(args.history) ? readFileSync(args.history, 'utf8').split('\n').filter(line => line.trim()).map(line => JSON.parse(line)) : [];
    const revision = execFileSync('git', ['rev-parse', 'HEAD'], {cwd: root, encoding: 'utf8'}).trim();
    if (revision !== snapshot.revision) throw Error('Snapshot revision differs from HEAD; collect again before deployment');
    const log = execFileSync('git', ['log', '--format=%ct', snapshot.revision], {cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 30000});
    const legacyPath = join(root, 'docs/convergence/centicolon-dashboard.json');
    const legacy = existsSync(legacyPath) ? JSON.parse(readFileSync(legacyPath, 'utf8')) : null;
    atomicJson(resolve(args.output), project(snapshot, history, commitSeries(log), legacy));
    console.log(`Precomputed logarithmic graph: ${args.output}`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
