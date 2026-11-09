// @trace order:2066-obsv, spec:observatorium-dashboard
// V1 Home: "Is it getting better?" (design.md §1 V1; comparison.md §6.3).
import {barChart, stepChart} from '../chart.mjs';
import {escape, num, share} from '../honesty.mjs';

const L = 'latest';

export const BREAK_TEXT = {
  'first-release': 'first release',
  'epoch-changed': 'the measurement method changed',
  'denominator-changed': 'the number of obligations changed',
  'scope-changed': 'the set of obligations changed',
  'scope-unknown-before': 'the previous release did not record its set of obligations',
  'scope-unknown': 'this release did not record its set of obligations',
};
export const breakText = (reasons) => reasons.map((r) => BREAK_TEXT[r] ?? r).join('; ');
const scopeText = (r) => {
  if (!r.provenance.scopeSha256) return '<data class="missing">— not recorded</data>';
  if (r.segment.reasons.includes('scope-changed')) return 'changed';
  if (r.segment.reasons.includes('scope-unknown-before') || r.segment.reasons.includes('first-release')) return 'first recorded';
  return 'same';
};

function figure(id, heading, chart, lede = '') {
  return `<section class="card" aria-labelledby="${id}">
<h2 id="${id}">${heading}</h2>
${lede}
<figure>
${chart.svg}
<figcaption>${chart.caption || ''}</figcaption>
</figure>
<details class="twin">
<summary>Show the numbers as a table</summary>
<div class="table-scroll">${chart.table}</div>
</details>
</section>`;
}

export function home(view) {
  const latest = view.latest;
  const n = (p) => num(view, `${L}.${p}`);

  const reading = `<p class="reading">At release <strong>${escape(latest.tag)}</strong> (${latest.date}) the project tracks
${n('residual.denominator')} obligations: things its specifications say the software must do. ${n('residual.satisfied')} of them
have a passing test linked to them. ${n('residual.reasons.no-binding')} have no test bound to them yet, and
${n('residual.reasons.unrun')} have a bound test that was not run. ${n('residual.reasons.failed')} have a test that failed.
So the large number above is mostly a gap in how tests are linked to specifications, not a record of failures.</p>`;

  const dirty = latest.dirty
    ? '<p class="badge warn" role="note"><span aria-hidden="true">!</span> Measured on a tree with uncommitted changes; the revision names the base commit.</p>'
    : '';

  const headline = `<section class="card headline" aria-labelledby="headline">
<h1 id="headline">Is it getting better?</h1>
<p class="stamp-line">Measured at release <strong>${escape(latest.tag)}</strong> (${latest.date}, build ${latest.build}), observed ${latest.measuredAt.slice(0, 16).replace('T', ' ')} UTC, revision <code>${escape(latest.revision.slice(0, 12))}</code>.</p>
${dirty}
<p class="big"><span class="label">Obligations without a positive test</span>
<span class="pair">${n('residual.value')} <span class="of">of</span> ${n('residual.denominator')}</span>
<span class="sub">${share(view, `${L}.residual.value`, `${L}.residual.denominator`)} unmet. That is a share of a count, not a probability.</span></p>
${reading}
</section>`;

  const why = barChart(view, {
    title: 'Why obligations are unmet',
    summary: `At ${latest.tag}, ${latest.residual.reasons['no-binding'] ?? 'an unrecorded number of'} obligations have no bound test and ${latest.residual.reasons.unrun ?? 'an unrecorded number'} were not run.`,
    denominatorPath: `${L}.residual.denominator`,
    items: [
      {label: 'Tested (passing)', path: `${L}.residual.satisfied`, tone: 'good', note: 'a positive test passed for this obligation'},
      {label: 'No test bound', path: `${L}.residual.reasons.no-binding`, tone: 'muted', note: 'no test is linked to the obligation yet'},
      {label: 'Bound, not run', path: `${L}.residual.reasons.unrun`, tone: 'muted', note: 'a test is linked but has no recorded run'},
      {label: 'Test failed', path: `${L}.residual.reasons.failed`, tone: 'bad', note: 'the linked test ran and failed'},
      {label: 'Test skipped', path: `${L}.residual.reasons.skipped`, tone: 'muted', note: 'the linked test was skipped'},
      {label: 'Spec changed', path: `${L}.residual.reasons.spec-changed`, tone: 'muted', note: 'the specification moved after the test ran'},
    ],
  });
  why.caption = `Counts at ${escape(latest.tag)}. Bars share one denominator; they are reasons, not slices of a whole that must add up visually.`;

  const series = stepChart(view, {
    field: 'value', title: 'Residual over releases',
    summary: `Residual at each of ${view.releases.length} releases, from ${view.releases[0].residual.value} to ${latest.residual.value}; a vertical line marks each change of scope.`,
  });
  const breaks = series.breaks.map((b, i) => `<li><strong>Break ${i + 1}</strong> at ${escape(b.release)}: ${escape(breakText(b.reasons))}. Points either side are not joined.</li>`).join('');
  const regressions = view.releases.filter((r) => r.regression).map((r) => `<li>${escape(r.tag)}: residual rose within one scope.</li>`).join('');
  series.caption = `Lower is better. Each step is one release; the value holds until the next release.
<ul class="notes">${breaks}${regressions || '<li>No regression within a scope.</li>'}</ul>`;

  const ledgerRows = view.releases.map((r, i) => {
    const p = `releases.${i}`;
    return `<tr><th scope="row">${escape(r.tag)}</th><td class="num">${num(view, `${p}.residual.denominator`)}</td><td class="num">${i === 0 ? 'first release' : num(view, `${p}.denominatorDelta`)}</td><td>${scopeText(r)}</td><td class="num">${num(view, `${p}.population.gaps.unregistered`)}</td><td class="num">${num(view, `${p}.population.excluded.deprecated`)}</td><td class="num">${num(view, `${p}.population.excluded.obsolete`)}</td><td class="num">${num(view, `${p}.population.invariantsExcluded`)}</td></tr>`;
  }).join('');
  const ledger = `<section class="card" aria-labelledby="goalposts">
<h2 id="goalposts">Goalposts</h2>
<p>When the set of obligations changes, the residual can move without any test changing. Every such change is listed here, beside the chart.</p>
<div class="table-scroll"><table>
<caption>Scope of each release</caption>
<thead><tr><th scope="col">Release</th><th scope="col">Denominator</th><th scope="col">Change</th><th scope="col">Scope</th><th scope="col">Unregistered specs</th><th scope="col">Deprecated excluded</th><th scope="col">Obsolete excluded</th><th scope="col">Invariants excluded</th></tr></thead>
<tbody>${ledgerRows}</tbody>
</table></div>
</section>`;

  const premise = view.releasesSinceLastStrictDecrease === null
    ? 'No release has yet lowered the residual within one scope. The project has not declared a bound on how many releases that may take, so no claim that the residual will reach zero is made.'
    : `Releases since the last decrease within one scope: ${num(view, 'releasesSinceLastStrictDecrease')}. The project has not declared a bound on that number.`;

  const limits = latest.provenance.limitations.map((l) => `<li>${escape(l)}</li>`).join('');
  const disclaimer = `<section class="card disclaimer" aria-labelledby="limits">
<h2 id="limits">What this does not show</h2>
<p><strong>Closing every obligation would prove neither that the set of obligations is adequate nor how the software behaves in every execution.</strong></p>
<ul>${limits}<li>${escape(latest.provenance.recordScope)}</li></ul>
<p>${premise}</p>
<p>The register of claims, including withdrawn ones, is not yet published on this site.</p>
</section>`;

  return {
    title: 'Home',
    description: `Tillandsias obligations at release ${latest.tag}: ${latest.residual.value} of ${latest.residual.denominator} without a positive test.`,
    body: [headline, figure('why', 'Why they are unmet', why), figure('series', 'Over releases', series), ledger, disclaimer].join('\n'),
  };
}
