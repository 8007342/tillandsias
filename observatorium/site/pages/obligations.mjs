// @trace order:2066-obsv, spec:observatorium-dashboard
// V2 Obligations. The ladder shows all seven rungs of the lattice in chain
// order; the four no grader assigns are hatched "never produced" (rule 3b).
// Per-obligation rows are not committed per release (answers.md Q1, Q16), so
// there is no per-obligation table yet and the page says so.
import {card, figure} from '../layout.mjs';
import {escape, formatInt, num, resolve, UNPRODUCED} from '../honesty.mjs';
import {RUNGS} from '../view.mjs';

const RUNG_TEXT = {
  absent: ['absent', 'no specification declares it'],
  declared: ['declared', 'a specification states it'],
  traced: ['traced (claimed by grader)', 'code or a test names it; the grader asserts this and publishes no witness'],
  positively_tested: ['positively tested', 'a passing test is bound to it: the bar for credit'],
  negatively_tested: ['negatively tested', 'a test shows the wrong behaviour is refused'],
  runtime_observed: ['runtime observed', 'a trace from a real run shows it'],
  evidence_bundled: ['evidence bundled', 'an exportable evidence bundle proves it'],
};

function ladder(view) {
  const W = 640, rowH = 34, L = 220, R = 80, T = 8;
  const H = T * 2 + rowH * RUNGS.length;
  const den = view.latest.residual.denominator;
  const key = 'rungs-at-the-latest-release';
  const rows = RUNGS.map((rung, i) => {
    const y0 = T + i * rowH;
    const label = `<text class="bar-label" x="${L - 8}" y="${y0 + rowH / 2 + 4}" text-anchor="end">${escape(RUNG_TEXT[rung][0])}</text>`;
    const bar = rung === 'positively_tested' ? `<line class="bar-mark" x1="${L}" x2="${L}" y1="${y0 + 2}" y2="${y0 + rowH - 2}"/>` : '';
    if (UNPRODUCED.includes(rung)) {
      return `<g data-rung="${rung}" data-produced="false">${label}<rect class="no-data" x="${L}" y="${y0 + 6}" width="${W - L - R}" height="${rowH - 12}" fill="url(#${key}-hatch)"/><text class="bar-value" x="${W - R + 6}" y="${y0 + rowH / 2 + 4}">never produced</text></g>`;
    }
    const v = resolve(view, `latest.residual.histogram.${rung}`);
    if (v == null) return `<g data-rung="${rung}" data-produced="true">${label}<rect class="no-data" x="${L}" y="${y0 + 6}" width="${W - L - R}" height="${rowH - 12}" fill="url(#${key}-hatch)"/><text class="bar-value" x="${W - R + 6}" y="${y0 + rowH / 2 + 4}">not recorded</text></g>`;
    const w = Math.max(v > 0 ? 2 : 0, ((W - L - R) * v) / Math.max(1, den));
    return `<g data-rung="${rung}" data-produced="true">${label}<rect class="track" x="${L}" y="${y0 + 6}" width="${W - L - R}" height="${rowH - 12}"/><rect class="bar${rung === 'positively_tested' ? ' good' : ''}" x="${L}" y="${y0 + 6}" width="${w}" height="${rowH - 12}"/>${bar}<text class="bar-value" x="${W - R + 6}" y="${y0 + rowH / 2 + 4}">${formatInt(v)}</text></g>`;
  }).join('');
  const svg = `<svg class="chart rungs" viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="${key}-title ${key}-desc"><defs><pattern id="${key}-hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" class="hatch-bg"/><line x1="0" y1="0" x2="0" y2="6" class="hatch-line"/></pattern></defs><title id="${key}-title">Rungs at the latest release</title><desc id="${key}-desc">Seven rungs in chain order. Three are produced by the grader; absent, negatively tested, runtime observed and evidence bundled are never produced by any grader.</desc>${rows}</svg>`;
  const body = RUNGS.map((rung) => `<tr><th scope="row">${escape(RUNG_TEXT[rung][0])}</th><td class="num">${UNPRODUCED.includes(rung) ? 'never produced' : num(view, `latest.residual.histogram.${rung}`)}</td><td>${escape(RUNG_TEXT[rung][1])}</td></tr>`).join('');
  const table = `<table class="twin"><caption>Rungs at the latest release, as a table</caption><thead><tr><th scope="col">Rung</th><th scope="col">Obligations</th><th scope="col">Meaning</th></tr></thead><tbody>${body}</tbody></table>`;
  return {svg, table, caption: `Counts at ${escape(view.latest.tag)} out of ${formatInt(den)} obligations. The bar for credit is positively tested; reaching it is credit, not reaching the top of the ladder. Hatched rungs are never produced by any grader: the lattice has them on paper only.`};
}

export function obligations(view) {
  const l = 'latest';
  const intro = `<section class="card headline" aria-labelledby="obligations">
<h1 id="obligations">Obligations</h1>
<p>An obligation is one scenario a specification states, or a requirement that has no scenario. At ${escape(view.latest.tag)} there are ${num(view, `${l}.residual.denominator`)} in scope. Invariants are extracted separately and not graded here: ${num(view, `${l}.population.invariantsExcluded`)}. Deprecated and obsolete specifications are excluded too: ${num(view, `${l}.population.excluded.deprecated`)} and ${num(view, `${l}.population.excluded.obsolete`)}.</p>
</section>`;
  const notRetained = card('rows', 'Per-obligation rows', `<p>The grader produces one row per obligation (id, specification, requirement, state, reason) on every run, but only the totals are committed per release. Per-obligation rows are not retained, so this site cannot yet list obligations one by one, show each one's history, or recompute a residual on the ids two releases share.</p>
<p>Specifications with no registry entry at ${escape(view.latest.tag)}: ${num(view, `${l}.population.gaps.unregistered`)}. Missing: ${num(view, `${l}.population.gaps.missing`)}. Unkeyed: ${num(view, `${l}.population.gaps.unkeyed`)}.</p>`);
  return {
    title: 'Obligations',
    description: `The seven-rung ladder of Tillandsias obligations at ${view.latest.tag}.`,
    body: [intro, figure('ladder', 'Where obligations stand', ladder(view)), notRetained].join('\n'),
  };
}
