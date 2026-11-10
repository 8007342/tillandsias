// @trace order:2066-obsv, spec:observatorium-dashboard
// V3 Releases: the index (one row per committed snapshot) and one page per
// release with its stamp, numbers, reasons, provenance and alignment panel.
import {card} from '../layout.mjs';
import {escape, num, share} from '../honesty.mjs';
import {breakText} from './home.mjs';

const DIGESTS = [
  ['gradeSha256', 'sha256 of the grader output (grade.json) this row was read from'],
  ['obligationsSha256', 'sha256 of the extracted obligation list'],
  ['staticSha256', 'sha256 of the static grade (bindings before any run)'],
  ['scopeSha256', 'sha256 of the sorted obligation ids: equal digests mean the same set of obligations'],
];

const flags = (r) => [
  r.dirty ? '<span class="badge warn">uncommitted changes</span>' : '',
  r.shallow ? '<span class="badge warn">shallow clone</span>' : '',
].join(' ');

export function releasesIndex(view) {
  const segments = [...new Set(view.releases.map((r) => r.segment.id))];
  const rows = view.releases.map((r, i) => {
    const p = `releases.${i}`;
    const filter = `${r.tag} ${r.date} segment-${r.segment.id} ${r.dirty ? 'dirty' : 'clean'}`;
    return `<tr data-filter="${escape(filter)}" data-segment="${r.segment.id}"><th scope="row"><a href="${escape(r.tag)}/index.html">${escape(r.tag)}</a></th><td>${r.date}</td><td><code>${escape(r.revision.slice(0, 12))}</code> ${flags(r)}</td><td class="num">${num(view, `${p}.residual.denominator`)}</td><td class="num">${num(view, `${p}.residual.satisfied`)}</td><td class="num">${num(view, `${p}.residual.value`)}</td><td>${r.segment.id}</td><td>${r.segment.reasons.length ? escape(breakText(r.segment.reasons)) : 'same set of obligations'}</td></tr>`;
  }).join('');
  const controls = `<form class="filter" data-filter-for="releases-table" hidden>
<label for="release-filter">Filter releases</label>
<input id="release-filter" type="search" name="q" placeholder="tag, date, dirty or clean" autocomplete="off">
<label for="release-segment">Segment</label>
<select id="release-segment" name="segment"><option value="">all</option>${segments.map((s) => `<option value="${s}">segment ${s}</option>`).join('')}</select>
<output for="release-filter release-segment" aria-live="polite"></output>
</form>`;
  const body = `<section class="card" aria-labelledby="releases">
<h1 id="releases">Releases</h1>
<p>One row for every release whose measurement is committed to <code>observatorium/history/snapshots.jsonl</code>. A row is added when a release is cut, never at deploy time, and rows are never backfilled. A segment is a run of releases with the same set of obligations and the same measurement method. Values in different segments are not comparable.</p>
<p>Whether a release was promoted to the stable channel is not recorded in the history.</p>
${controls}
<div class="table-scroll"><table id="releases-table">
<caption>Committed release measurements</caption>
<thead><tr><th scope="col">Release</th><th scope="col">Date</th><th scope="col">Revision</th><th scope="col">Denominator</th><th scope="col">Tested</th><th scope="col">Residual</th><th scope="col">Segment</th><th scope="col">Starts a segment because</th></tr></thead>
<tbody>${rows}</tbody>
</table></div>
</section>`;
  return {title: 'Releases', description: `All ${view.releases.length} committed release measurements of the Tillandsias obligations.`, body, scripts: ['filter.js']};
}

export function releasePage(view, i) {
  const r = view.releases[i];
  const prev = view.releases[i - 1];
  const p = `releases.${i}`;
  const n = (path) => num(view, `${p}.${path}`);

  let alignment;
  if (!prev) alignment = `<p>This is the first committed release; there is nothing to align it with. Its per-obligation rows are not retained either.</p>`;
  else if (r.segment.reasons.includes('scope-changed')) alignment = `<p><strong>The scope changed</strong> since ${escape(prev.tag)}: the set of obligation ids differs (its digest changed). The residuals of the two releases are not comparable as they stand.</p>`;
  else if (r.segment.reasons.some((x) => x.startsWith('scope-unknown'))) alignment = `<p>One of ${escape(prev.tag)} and ${escape(r.tag)} did not record its set of obligations, so whether the scope changed is <data class="missing">— not recorded</data>.</p>`;
  else alignment = `<p>${escape(r.tag)} grades the <strong>same set of obligations</strong> as ${escape(prev.tag)} (equal scope digests), so their residuals are comparable.</p>`;
  if (prev) alignment += `<p>Aligned-scope comparison: per-obligation rows are not retained for ${escape(prev.tag)} or ${escape(r.tag)}, so the ids common to both, the ids only in one, and the residual recomputed on their intersection are not computable.</p>`;

  const reasons = ['no-binding', 'unrun', 'failed', 'skipped', 'spec-changed']
    .map((k) => `<tr><th scope="row">${k}</th><td class="num">${n(`residual.reasons.${k}`)}</td></tr>`).join('');
  const digests = DIGESTS.map(([k, d]) => `<tr><th scope="row">${k}</th><td>${r.provenance[k] ? `<code class="digest">${escape(r.provenance[k])}</code>` : '<data class="missing">— not recorded</data>'}</td><td>${escape(d)}</td></tr>`).join('');
  const limits = r.provenance.limitations.map((l) => `<li>${escape(l)}</li>`).join('');

  const body = [
    `<section class="card headline" aria-labelledby="release">
<p class="crumb"><a href="../index.html">Releases</a></p>
<h1 id="release">Release ${escape(r.tag)}</h1>
<p class="stamp-line">Released ${r.date}, build ${r.build}. Measured ${r.measuredAt.slice(0, 16).replace('T', ' ')} UTC at revision <code>${escape(r.revision)}</code>. Measurement method <code>${escape(r.epoch)}</code>. ${flags(r)}</p>
<p class="big"><span class="label">Obligations without a positive test</span>
<span class="pair">${n('residual.value')} <span class="of">of</span> ${n('residual.denominator')}</span>
<span class="sub">${share(view, `${p}.residual.value`, `${p}.residual.denominator`)} unmet; ${n('residual.satisfied')} tested. Litmus records read: ${n('residual.records')}.</span></p>
</section>`,
    card('alignment', 'Alignment with the previous release', alignment),
    card('reasons', 'Why obligations are unmet', `<div class="table-scroll"><table><caption>Unmet obligations by reason at ${escape(r.tag)}</caption><thead><tr><th scope="col">Reason</th><th scope="col">Obligations</th></tr></thead><tbody>${reasons}</tbody></table></div>
<p>Histogram ${r.residual.histogramRecorded ? 'recorded by the grader' : 'not recorded for this release; the declared count is derived from the recorded traced count'}: declared ${n('residual.histogram.declared')}, traced ${n('residual.histogram.traced')}, positively tested ${n('residual.histogram.positively_tested')}.</p>`),
    card('provenance', 'Provenance', `<div class="table-scroll"><table><caption>Digests recorded with this measurement</caption><thead><tr><th scope="col">Digest</th><th scope="col">Value</th><th scope="col">Meaning</th></tr></thead><tbody>${digests}</tbody></table></div>
<ul>${limits}</ul>
${r.gaps.length ? `<p>Gaps recorded with this snapshot:</p><ul>${r.gaps.map((g) => `<li>${escape(g)}</li>`).join('')}</ul>` : ''}`),
  ].join('\n');
  return {title: `Release ${r.tag}`, description: `Tillandsias obligations measured at release ${r.tag}.`, body};
}
