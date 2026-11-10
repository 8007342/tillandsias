// @trace order:2066-obsv, spec:observatorium-dashboard
// PR 2 red-first: the remaining pages, the claims register and rule 3b.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {buildSite} from './build.mjs';
import {parseClaims, STRENGTHS} from './claims.mjs';
import {lintPage} from './honesty.mjs';

const history = readFileSync(new URL('../history/snapshots.jsonl', import.meta.url), 'utf8');
const claimsText = readFileSync(new URL('../data/claims.yaml', import.meta.url), 'utf8');
const facts = {newestTag: 'v56.11.7.1', trailer: null, deploy: false, builtAt: '2026-11-10T09:00:00Z'};
const PAGES = ['index.html', 'releases/index.html', 'obligations/index.html', 'claims/index.html',
  'instrument/index.html', 'glossary/index.html', 'data/index.html'];
const stamp = '<footer data-stamp>release v1.1.1.1 · built 2026-11-09 18:02 UTC</footer>';

test('every page exists, lints clean and links all seven pages', () => {
  const {files, violations} = buildSite(history, facts);
  assert.deepEqual(violations, []);
  for (const page of PAGES) {
    const html = files.get(page);
    assert.ok(html, page);
    const nav = html.match(/<nav aria-label="Site">[\s\S]*?<\/nav>/)[0];
    assert.equal((nav.match(/<a /g) || []).length, 7, page);
    assert.equal((nav.match(/aria-current="page"/g) || []).length, 1, page);
  }
});

test('one page per release, with an alignment panel that says what is not retained', () => {
  const {files} = buildSite(history, facts);
  for (const tag of ['v56.10.14.1', 'v56.11.6.1', 'v56.11.7.1']) {
    const html = files.get(`releases/${tag}/index.html`);
    assert.ok(html, tag);
    assert.match(html, /aligned-scope comparison|alignment/i);
    assert.match(html, /not retained/);
  }
  assert.match(files.get('releases/v56.11.6.1/index.html'), /scope changed/i);
  assert.match(files.get('releases/v56.11.7.1/index.html'), /same set of obligations/i);
});

test('the obligations page draws all seven rungs, four hatched as never produced', () => {
  const {files} = buildSite(history, facts);
  const html = files.get('obligations/index.html');
  for (const rung of ['absent', 'negatively_tested', 'runtime_observed', 'evidence_bundled']) {
    assert.match(html, new RegExp(`data-rung="${rung}" data-produced="false"`), rung);
  }
  assert.match(html, /never produced by any grader/);
  assert.match(html, /claimed by grader/);
  assert.match(html, /not retained/);
});

test('rule 3b: a rung chart that omits or fills an unproduced rung is refused', () => {
  const view = {releases: []};
  const missing = `<main><svg class="chart rungs"><g data-rung="declared" data-produced="true"></g></svg></main>${stamp}`;
  assert.ok(lintPage('o.html', missing, view).some((v) => v.rule === 'unproduced-rung'));
  const filled = `<main><svg class="chart rungs">${['absent', 'negatively_tested', 'runtime_observed', 'evidence_bundled']
    .map((r) => `<g data-rung="${r}" data-produced="false"><rect class="bar"/></g>`).join('')}</svg></main>${stamp}`;
  assert.ok(lintPage('o.html', filled, view).some((v) => v.rule === 'unproduced-rung'));
});

test('the claims seed parses and every claim awaits operator review', () => {
  const claims = parseClaims(claimsText);
  assert.ok(claims.length >= 10);
  for (const c of claims) {
    assert.ok(STRENGTHS.includes(c.strength), c.id);
    assert.equal(c.review, 'operator-pending', c.id);
  }
  assert.ok(claims.some((c) => c.strength === 'withdrawn'));
  assert.ok(claims.some((c) => c.strength === 'on paper only'));
});

test('the claims parser fails closed', () => {
  const ok = '- id: a\n  statement: "x"\n  strength: open\n  scope: "s"\n  discharge: "d"\n  review: operator-pending\n';
  assert.equal(parseClaims(ok).length, 1);
  assert.throws(() => parseClaims(ok.replace('open', 'very-sure')), /strength/);
  assert.throws(() => parseClaims(ok.replace('  review: operator-pending\n', '')), /review/);
  assert.throws(() => parseClaims(`${ok}  colour: red\n`), /unknown key/);
  assert.throws(() => parseClaims(`${ok}  nested:\n    deep: 1\n`), /line/);
  assert.throws(() => parseClaims(`${ok}${ok}`), /duplicate/);
});

test('the claims page shows every claim as not yet reviewed', () => {
  const {files} = buildSite(history, facts);
  const html = files.get('claims/index.html');
  const n = parseClaims(claimsText).length;
  assert.equal((html.match(/data-review="operator-pending"/g) || []).length, n);
  assert.match(html, /not yet reviewed by the operator/i);
});

test('JS appears only as a filter, and the page is complete without it', () => {
  const {files} = buildSite(history, facts);
  for (const page of PAGES.filter((p) => p !== 'releases/index.html')) assert.doesNotMatch(files.get(page), /<script/, page);
  const rel = files.get('releases/index.html');
  assert.match(rel, /<script src="..\/filter.js" defer><\/script>/);
  assert.equal((rel.match(/<tr data-filter=/g) || []).length, 7);
  assert.ok(files.has('filter.js'));
});

test('the data page lists every published data file with its digest', () => {
  const {files} = buildSite(history, facts);
  const html = files.get('data/index.html');
  for (const f of ['history.json', 'snapshots.jsonl', 'claims.json']) {
    assert.ok(files.has(`data/${f}`), f);
    assert.match(html, new RegExp(`href="${f.replace('.', '\\.')}"`), f);
  }
  assert.match(html, /[0-9a-f]{64}/);
});
