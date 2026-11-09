// @trace order:2066-obsv, spec:observatorium-dashboard
// Honesty rules (plan/issues/observatorium-blind-design-2026-11-09/design.md §3),
// enforced on the generated files. The build fails closed on any violation.
//
// Every number a page shows goes through num()/share(), which emit
// <data value data-field> pointing at a path in the derived view. The lint
// then reads those elements back and checks them against the view, so a
// renderer that turns null into 0 is caught however it was written.

export const MISSING = '— not recorded';
const fmt = new Intl.NumberFormat('en-US', {maximumFractionDigits: 0});

export const escape = (s) => String(s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const UNKNOWN = Symbol('unknown');
export function resolve(view, path) {
  let node = view;
  for (const key of path.split('.')) {
    if (node === null || node === undefined || typeof node !== 'object' || !(key in node)) return UNKNOWN;
    node = node[key];
  }
  return node;
}

export const formatInt = (n) => fmt.format(n);

/** One integer from the view, or the missing marker. Throws on an unknown path. */
export function num(view, path) {
  const value = resolve(view, path);
  if (value === UNKNOWN) throw Error(`num: the view has no field ${path}`);
  if (value === null || value === undefined) return `<data class="missing" data-field="${escape(path)}">${MISSING}</data>`;
  if (!Number.isSafeInteger(value)) throw Error(`num: ${path} is not an integer`);
  return `<data value="${value}" data-field="${escape(path)}">${formatInt(value)}</data>`;
}

/** A share, always labelled as one; missing when either count is missing. */
export function share(view, numerator, denominator) {
  const n = resolve(view, numerator);
  const d = resolve(view, denominator);
  if (n === UNKNOWN || d === UNKNOWN) throw Error(`share: unknown field ${n === UNKNOWN ? numerator : denominator}`);
  if (n == null || d == null || d === 0) return `<span class="share missing">share: ${MISSING}</span>`;
  const pct = Math.round((n / d) * 1000) / 10;
  return `<span class="share">${pct}% (share of ${formatInt(d)})</span>`;
}

const PROBABILITY = /\b(confidence|likelihood|chance|chances|odds)\b/i;
const RELATIVE = /\b(\d+\s+(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\s+ago|yesterday|just now|last week|last month)\b/i;
const STAMP = /<footer\b[^>]*data-stamp[^>]*>[\s\S]*?release v\d+\.\d+\.\d+\.\d+[\s\S]*?built \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC[\s\S]*?<\/footer>/;
const BLOCK = /<(p|li|td|th|dd|dt|figcaption|caption|h[1-6]|summary)\b[^>]*>([\s\S]*?)<\/\1>/g;
const DATA = /<data\b([^>]*)>([\s\S]*?)<\/data>/g;
const attr = (attrs, name) => (attrs.match(new RegExp(`\\b${name}="([^"]*)"`)) || [])[1];
const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, '').replace(/<style[\s\S]*?<\/style>/g, '')
  .replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ');

export function lintPage(file, html, view) {
  const out = [];
  const add = (rule, detail) => out.push({file, rule, detail});

  // 1. Missing is missing; and every shown number is the view's number.
  for (const [, attrs, inner] of html.matchAll(DATA)) {
    const path = attr(attrs, 'data-field');
    if (!path) continue;
    const value = resolve(view, path);
    const shown = inner.trim();
    if (value === UNKNOWN) { add('unknown-field', path); continue; }
    if (value === null || value === undefined) {
      if (shown !== MISSING || attr(attrs, 'value') !== undefined) add('missing-is-missing', `${path} shown as "${shown}"`);
      continue;
    }
    if (shown !== formatInt(value) || attr(attrs, 'value') !== String(value)) add('field-mismatch', `${path}: view ${value}, shown "${shown}"`);
  }

  // 2 + 5. A ratio carries both integers and says it is a share.
  for (const [, , inner] of html.matchAll(BLOCK)) {
    if (!inner.includes('%')) continue;
    const ints = (inner.match(/<data\b[^>]*\bvalue="/g) || []).length;
    if (ints < 2 || !/share of/.test(text(inner))) add('ratio-without-integers', text(inner).trim().slice(0, 80));
  }
  const body = text(html);
  const word = body.match(PROBABILITY);
  if (word) add('probability-word', word[0]);

  // 4. Stamped, absolutely.
  if (!STAMP.test(html)) add('stamp', 'no footer stamp with release and UTC build time');
  const rel = body.match(RELATIVE);
  if (rel) add('relative-time', rel[0]);

  // 3. Breaks are breaks.
  if (view?.releases) {
    const seg = new Map(view.releases.map((r) => [r.tag, r.segment?.id]));
    for (const [, attrs] of html.matchAll(/<path\b([^>]*\bclass="series"[^>]*)\/?>/g)) {
      const tags = (attr(attrs, 'data-releases') || '').split(/\s+/).filter(Boolean);
      const ids = new Set(tags.map((t) => seg.get(t)));
      if (ids.size > 1 || ids.has(undefined)) add('connected-across-break', tags.join(' '));
    }
  }
  return out;
}

/** 3c. No machine names in anything published under data/. */
export function lintData(file, value) {
  const out = [];
  const walk = (node, at) => {
    if (Array.isArray(node)) node.forEach((v, i) => walk(v, `${at}[${i}]`));
    else if (node && typeof node === 'object') {
      for (const [k, v] of Object.entries(node)) {
        if (k === 'host') out.push({file, rule: 'no-host', detail: `${at}.${k}`});
        walk(v, `${at}.${k}`);
      }
    }
  };
  walk(value, '$');
  return out;
}
