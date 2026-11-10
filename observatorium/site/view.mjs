// @trace order:2066-obsv, spec:observatorium-dashboard
// The derived, published view (design.md §4) built from the committed
// history/snapshots.jsonl. Every row passes the existing evidence validator
// first; a field the snapshot lacks stays null here and renders as missing.
import {releaseEvidence} from '../metrics/evidence.mjs';
import {compareTags} from './trailer.mjs';

export const SCHEMA = 'observatorium/1';
/** The seven-rung lattice (methodology/math-foundations.yaml). Only three are ever produced. */
export const RUNGS = ['absent', 'declared', 'traced', 'positively_tested', 'negatively_tested', 'runtime_observed', 'evidence_bundled'];
export const PRODUCED = new Set(['declared', 'traced', 'positively_tested']);
export const REASONS = ['no-binding', 'unrun', 'failed', 'skipped', 'spec-changed'];

export function decodeTag(tag) {
  const m = tag.match(/^v(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) throw Error(`Invalid release tag ${tag}`);
  const [, y, mo, d, b] = m.map(Number);
  const pad = (n) => String(n).padStart(2, '0');
  return {date: `${1970 + y}-${pad(mo)}-${pad(d)}`, build: b};
}

const orNull = (v) => (v === undefined ? null : v);

function release(row) {
  const grade = releaseEvidence(row); // throws on any arithmetic or provenance fault
  const p = row.current?.residual?.provenance || {};
  const h = grade.histogram;
  const histogram = Object.fromEntries(RUNGS.map((r) => [r, PRODUCED.has(r) ? orNull(h[r]) : null]));
  const reasons = Object.fromEntries(REASONS.map((r) => [r, orNull(grade.reasons?.[r])]));
  // The validator checked that the reasons sum to the residual, so a reason
  // absent from an existing map is a true 0, not a missing count.
  if (grade.reasons) for (const r of REASONS) reasons[r] ??= 0;
  return {
    tag: row.release, ...decodeTag(row.release),
    measuredAt: row.measuredAt, revision: row.revision, dirty: row.dirty === true, shallow: row.shallow === true,
    epoch: row.epoch,
    residual: {
      value: grade.value, denominator: grade.denominator, satisfied: grade.satisfied,
      measured: orNull(row.current.residual.measured), records: grade.records, histogram, reasons,
      histogramRecorded: Boolean(row.current.residual.histogram),
      bar: 'positively_tested',
    },
    provenance: {
      gradeSha256: orNull(p.gradeSha256), obligationsSha256: orNull(p.obligationsSha256),
      staticSha256: orNull(p.staticSha256), scopeSha256: orNull(p.scopeSha256),
      recordScope: grade.provenance.recordScope, limitations: grade.provenance.limitations,
    },
    population: {
      excluded: {deprecated: orNull(p.excluded?.deprecated), obsolete: orNull(p.excluded?.obsolete)},
      invariantsExcluded: orNull(p.invariantsExcluded),
      gaps: p.populationGaps ? {
        unregistered: p.populationGaps.unregistered?.length ?? null,
        missing: p.populationGaps.missing?.length ?? null,
        unkeyed: p.populationGaps.unkeyed?.length ?? null,
      } : {unregistered: null, missing: null, unkeyed: null},
    },
    specs: {files: orNull(row.current.specs?.files), requirements: orNull(row.current.specs?.requirements), scenarios: orNull(row.current.specs?.scenarios)},
    plan: {total: orNull(row.current.plan?.total), fragments: orNull(row.current.plan?.fragments)},
    gaps: Array.isArray(row.gaps) ? row.gaps : [],
  };
}

function breakReasons(prev, cur) {
  if (!prev) return ['first-release'];
  const out = [];
  if (prev.epoch !== cur.epoch) out.push('epoch-changed');
  if (prev.residual.denominator !== cur.residual.denominator) out.push('denominator-changed');
  const a = prev.provenance.scopeSha256;
  const b = cur.provenance.scopeSha256;
  if (a === null) out.push('scope-unknown-before');
  else if (b === null) out.push('scope-unknown');
  else if (a !== b) out.push('scope-changed');
  return out;
}

export function deriveView(rows) {
  if (!rows.length) throw Error('history/snapshots.jsonl is empty');
  const releases = rows.map(release);
  for (let i = 1; i < releases.length; i++) {
    if (compareTags(releases[i - 1].tag, releases[i].tag) >= 0) throw Error(`History out of release order at ${releases[i].tag}`);
  }
  let id = 0;
  let lastDecrease = null;
  releases.forEach((r, i) => {
    const prev = releases[i - 1];
    const reasons = breakReasons(prev, r);
    if (reasons.length) id += 1;
    r.segment = {id, reasons};
    const sameSegment = prev && !reasons.length;
    r.denominatorDelta = prev ? r.residual.denominator - prev.residual.denominator : null;
    r.regression = sameSegment ? r.residual.value > prev.residual.value : null;
    if (sameSegment && r.residual.value < prev.residual.value) lastDecrease = i;
  });
  const latest = releases.at(-1);
  return {
    schema: SCHEMA, releases, latest,
    releasesSinceLastStrictDecrease: lastDecrease === null ? null : releases.length - 1 - lastDecrease,
  };
}
