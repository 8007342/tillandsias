// @trace order:2066-obsv, spec:observatorium-dashboard
// Build-time SVG. No chart library, no runtime JS. Every chart has a <table>
// twin built from the same view paths, which is both the accessibility
// fallback and the honesty fallback (design.md §2, §7).
import {escape, formatInt, num, resolve, MISSING} from './honesty.mjs';

const BREAK_LABEL = {'first-release': 'first release', 'epoch-changed': 'method changed', 'denominator-changed': 'count changed', 'scope-changed': 'set changed', 'scope-unknown-before': 'earlier set not recorded', 'scope-unknown': 'set not recorded'};

const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

const hatch = (id) => `<defs><pattern id="${id}" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" class="hatch-bg"/><line x1="0" y1="0" x2="0" y2="6" class="hatch-line"/></pattern></defs>`;

/**
 * Residual over releases as a step chart. A residual is constant between
 * releases, so a step, not a line; segments never connect across a break.
 */
export function stepChart(view, {field = 'value', title, summary = ''}) {
  const rows = view.releases;
  const W = 640, H = 260, L = 56, R = 16, T = 16, B = 44;
  const values = rows.map((r) => r.residual[field]);
  const max = Math.max(1, ...values.filter((v) => v != null));
  const step = (W - L - R) / rows.length;
  const x = (i) => L + i * step;
  const y = (v) => T + (H - T - B) * (1 - v / max);
  const key = slug(title);
  const titleId = `${key}-title`;
  const descId = `${key}-desc`;
  const hatchId = `${key}-hatch`;
  const parts = [];

  // Axis: zero-based, never truncated.
  for (const t of [0, max / 2, max]) {
    const v = Math.round(t);
    parts.push(`<line class="grid" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/>`,
      `<text class="tick" x="${L - 6}" y="${y(v) + 4}" text-anchor="end">${formatInt(v)}</text>`);
  }
  // Segments.
  const segs = [];
  rows.forEach((r, i) => {
    if (!segs.length || segs.at(-1).id !== r.segment.id) segs.push({id: r.segment.id, idx: []});
    segs.at(-1).idx.push(i);
  });
  let note = 0;
  for (const s of segs) {
    const first = s.idx[0];
    if (first > 0) {
      note += 1;
      parts.push(`<line class="break" x1="${x(first)}" x2="${x(first)}" y1="${T}" y2="${H - B}"/>`,
        `<text class="break-label" x="${x(first) + 4}" y="${T + 12}">break ${note}</text>`);
    }
    const present = s.idx.filter((i) => values[i] != null);
    if (present.length) {
      let d = '';
      for (const i of present) d += `${d ? 'L' : 'M'}${x(i)} ${y(values[i])}H${x(i) + step}`;
      parts.push(`<path class="series" data-releases="${present.map((i) => rows[i].tag).join(' ')}" d="${d}"/>`);
    }
    for (const i of s.idx) {
      if (values[i] == null) parts.push(`<rect class="no-data" x="${x(i)}" y="${T}" width="${step}" height="${H - T - B}" fill="url(#${hatchId})"><title>${rows[i].tag}: ${MISSING}</title></rect>`);
      else if (rows[i].regression) parts.push(`<circle class="regression" cx="${x(i) + step / 2}" cy="${y(values[i])}" r="5"><title>${rows[i].tag}: regression</title></circle>`);
    }
  }
  rows.forEach((r, i) => {
    if (rows.length <= 12 || i % Math.ceil(rows.length / 12) === 0 || i === rows.length - 1) {
      parts.push(`<text class="tick" x="${x(i) + step / 2}" y="${H - B + 16}" text-anchor="middle">${r.date.slice(5)}</text>`);
    }
  });
  parts.push(`<text class="tick" x="${L}" y="${H - 6}">release date (month-day)</text>`);

  const svg = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="${titleId} ${descId}">${hatch(hatchId)}<title id="${titleId}">${escape(title)}</title><desc id="${descId}">${escape(summary)}</desc>${parts.join('')}</svg>`;

  const body = rows.map((r, i) => `<tr><th scope="row">${escape(r.tag)}</th><td>${r.date}</td><td class="num">${num(view, `releases.${i}.residual.${field}`)}</td><td class="num">${num(view, `releases.${i}.residual.denominator`)}</td><td>${r.segment.reasons.length ? escape(r.segment.reasons.map((x) => BREAK_LABEL[x] ?? x).join(', ')) : 'same scope'}</td></tr>`).join('');
  const table = `<table class="twin"><caption>${escape(title)}, as a table</caption><thead><tr><th scope="col">Release</th><th scope="col">Date</th><th scope="col">Residual</th><th scope="col">Denominator</th><th scope="col">Break</th></tr></thead><tbody>${body}</tbody></table>`;
  return {svg, table, breaks: segs.slice(1).map((s) => ({release: rows[s.idx[0]].tag, reasons: rows[s.idx[0]].segment.reasons}))};
}

/** Horizontal bars of counts that share one denominator. Missing is hatched. */
export function barChart(view, {title, summary = '', items, denominatorPath}) {
  const W = 640, rowH = 36, L = 180, R = 72, T = 8;
  const H = T * 2 + rowH * items.length;
  const den = resolve(view, denominatorPath);
  const key = slug(title);
  const titleId = `${key}-title`;
  const descId = `${key}-desc`;
  const hatchId = `${key}-hatch`;
  const scale = (v) => ((W - L - R) * v) / Math.max(1, den);
  const parts = items.map((it, i) => {
    const v = resolve(view, it.path);
    const y0 = T + i * rowH;
    const label = `<text class="bar-label" x="${L - 8}" y="${y0 + rowH / 2 + 4}" text-anchor="end">${escape(it.label)}</text>`;
    if (v == null) {
      return `${label}<rect class="no-data" x="${L}" y="${y0 + 6}" width="${W - L - R}" height="${rowH - 12}" fill="url(#${hatchId})"/><text class="bar-value" x="${W - R + 6}" y="${y0 + rowH / 2 + 4}">${MISSING.replace('— ', '')}</text>`;
    }
    const w = Math.max(v > 0 ? 2 : 0, scale(v));
    return `${label}<rect class="track" x="${L}" y="${y0 + 6}" width="${W - L - R}" height="${rowH - 12}"/><rect class="bar ${it.tone || ''}" x="${L}" y="${y0 + 6}" width="${w}" height="${rowH - 12}"/><text class="bar-value" x="${W - R + 6}" y="${y0 + rowH / 2 + 4}">${formatInt(v)}</text>`;
  });
  const svg = `<svg class="chart bars" viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="${titleId} ${descId}">${hatch(hatchId)}<title id="${titleId}">${escape(title)}</title><desc id="${descId}">${escape(summary)}</desc>${parts.join('')}</svg>`;
  const body = items.map((it) => `<tr><th scope="row">${escape(it.label)}</th><td class="num">${num(view, it.path)}</td><td>${escape(it.note || '')}</td></tr>`).join('');
  const table = `<table class="twin"><caption>${escape(title)}, as a table</caption><thead><tr><th scope="col">Count</th><th scope="col">Obligations</th><th scope="col">Meaning</th></tr></thead><tbody>${body}<tr><th scope="row">Denominator</th><td class="num">${num(view, denominatorPath)}</td><td>all obligations in scope</td></tr></tbody></table>`;
  return {svg, table};
}
