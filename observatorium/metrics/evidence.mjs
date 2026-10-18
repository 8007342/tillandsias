// @trace order:1782-bek5, spec:observatorium-dashboard
// Publication validates measurements; it never upgrades inventory into evidence.
export const RECORD_SCOPE = 'All digest-bearing litmus records in the local results stream; this count does not identify runs matching these obligations.';
export const GRADE_LIMITS = [
  'The grader binds tests to requirements and may credit multiple scenarios from one requirement binding.',
  'Run freshness checks litmus and some spec digests; implementation revisions and assertion adequacy are not verified by this grade.',
];
export function count(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) throw Error(`Invalid ${label}: expected a nonnegative safe integer`);
  return value;
}
export function validateResidual(residual, {release = false} = {}) {
  if (!residual || residual.value === null || residual.value === undefined) return null;
  if (residual.measured === false || residual.unmeasured === true) throw Error('An unmeasured grade cannot carry a residual value');
  const value = count(residual.value, 'residual');
  const denominator = count(residual.denominator, 'obligation denominator');
  const satisfied = count(residual.satisfied, 'satisfied obligations');
  if (!denominator || satisfied > denominator || value !== denominator - satisfied) throw Error('Invalid residual arithmetic or empty obligation population');
  const records = residual.records === undefined ? null : count(residual.records, 'litmus records');
  if (release && !(records > 0)) throw Error('Release grade lacks recorded litmus results');
  const histogram = residual.histogram || {
    declared: residual.declared ?? (residual.traced == null ? null : denominator - satisfied - residual.traced),
    traced: residual.traced ?? null,
    positively_tested: residual.positivelyTested ?? satisfied,
  };
  for (const state of ['declared', 'traced', 'positively_tested']) {
    if (histogram[state] !== null && histogram[state] !== undefined) count(histogram[state], `histogram ${state}`);
  }
  if (histogram.positively_tested !== satisfied) throw Error('Positive-test histogram disagrees with satisfied obligations');
  if (histogram.declared != null && histogram.traced != null && histogram.declared + histogram.traced + satisfied !== denominator) throw Error('Obligation histogram disagrees with denominator');
  if (residual.reasons !== undefined) {
    if (!residual.reasons || typeof residual.reasons !== 'object' || Array.isArray(residual.reasons)) throw Error('Invalid residue reasons');
    const reasonTotal = Object.values(residual.reasons).reduce((sum, n) => sum + count(n, 'residue reason'), 0);
    if (reasonTotal !== value) throw Error('Residue reasons disagree with residual');
  }
  return {...residual, value, denominator, satisfied, records, histogram,
    declared: histogram.declared, traced: histogram.traced, positivelyTested: histogram.positively_tested,
    recordScope: RECORD_SCOPE};
}
export function releaseEvidence(record) {
  if (!/^v\d+\.\d+\.\d+\.\d+$/.test(record.release || '')) throw Error('Invalid release tag');
  if (typeof record.revision !== 'string' || !/^[a-f0-9]{7,64}$/i.test(record.revision)) throw Error('Release source revision is missing or invalid');
  if (!Number.isFinite(Date.parse(record.measuredAt))) throw Error('Release observation time is missing or invalid');
  if (record.current?.residual?.source !== 'centicolon-grade-observed/1') throw Error('Unsupported release grade source');
  const grade = validateResidual(record.current?.residual, {release: true});
  if (!grade) throw Error('Release grade is unavailable');
  const provenance = grade.provenance || {};
  if (provenance.revision && provenance.revision !== record.revision) throw Error('Grade provenance differs from release source revision');
  return {...grade, release: record.release, measuredAt: record.measuredAt, revision: record.revision, dirty: record.dirty,
    provenance: {...provenance, revision: record.revision, measuredAt: record.measuredAt, gradeSchema: grade.source,
      recordScope: RECORD_SCOPE, limitations: [...new Set([
        ...(provenance.limitations || []), ...GRADE_LIMITS,
        ...(record.dirty ? ['This observation includes uncommitted changes; its revision identifies the base commit.'] : []),
        ...(!provenance.gradeSha256 ? ['This historical snapshot has no retained grade digest or per-obligation evidence rows.'] : []),
      ])]},
    reason: `Release ${record.release} observation (${record.measuredAt.slice(0, 10)}): ${grade.satisfied} tested of ${grade.denominator} obligations; ${grade.value} residual. The global run-log count does not establish that every traced obligation ran.`};
}
