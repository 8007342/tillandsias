// @trace order:2066-obsv, spec:observatorium-dashboard
// Red-first: every rule here was written to fail against a permissive lint.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {MISSING, num, share, lintPage, lintData} from './honesty.mjs';

const view = {
  releases: [
    {tag: 'v1.1.1.1', residual: {value: 10, denominator: 10, satisfied: 0, histogram: {declared: null}}},
  ],
};
const stamp = '<footer data-stamp>release v1.1.1.1 · built 2026-11-09 18:02 UTC · snapshot sha256 0123456789ab · generator observatorium-site/1</footer>';
const page = (body) => `<!doctype html><html lang="en"><body><main>${body}</main>${stamp}</body></html>`;
const rules = (html) => lintPage('index.html', html, view).map((v) => v.rule);

test('missing renders as missing, never as zero', () => {
  const html = num(view, 'releases.0.residual.histogram.declared');
  assert.match(html, new RegExp(MISSING));
  assert.doesNotMatch(html, />0</);
  assert.match(html, /class="missing"/);
});

test('a present integer renders with its value', () => {
  assert.equal(num(view, 'releases.0.residual.value'), '<data value="10" data-field="releases.0.residual.value">10</data>');
});

test('lint refuses a null field rendered as 0', () => {
  const html = page('<p><data value="0" data-field="releases.0.residual.histogram.declared">0</data> declared</p>');
  assert.deepEqual(rules(html), ['missing-is-missing']);
});

test('lint refuses a number that disagrees with the view', () => {
  const html = page('<p><data value="9" data-field="releases.0.residual.value">9</data> unmet</p>');
  assert.deepEqual(rules(html), ['field-mismatch']);
});

test('lint refuses a field the view does not have', () => {
  const html = page('<p><data value="3" data-field="releases.0.residual.nonsense">3</data></p>');
  assert.deepEqual(rules(html), ['unknown-field']);
});

test('a ratio needs both integers and the words "share of" in the same block', () => {
  assert.deepEqual(rules(page('<p>100% unmet</p>')), ['ratio-without-integers']);
  const ok = `<p>${num(view, 'releases.0.residual.value')} of ${num(view, 'releases.0.residual.denominator')} unmet ${share(view, 'releases.0.residual.value', 'releases.0.residual.denominator')}</p>`;
  assert.deepEqual(rules(page(ok)), []);
  assert.match(share(view, 'releases.0.residual.value', 'releases.0.residual.denominator'), /100% \(share of /);
});

test('a share of a missing count is missing, not a percentage', () => {
  assert.match(share(view, 'releases.0.residual.histogram.declared', 'releases.0.residual.denominator'), new RegExp(MISSING));
});

test('probability words are refused', () => {
  for (const word of ['confidence', 'likelihood', 'chance', 'odds']) {
    assert.deepEqual(rules(page(`<p>High ${word} of closure.</p>`)), ['probability-word'], word);
  }
});

test('every page carries an absolute stamp', () => {
  const unstamped = '<!doctype html><html lang="en"><body><main><p>x</p></main></body></html>';
  assert.deepEqual(rules(unstamped), ['stamp']);
  assert.deepEqual(rules(page('<p>Measured 3 days ago.</p>')), ['relative-time']);
});

test('chart segments never connect across a break', () => {
  const segView = {releases: [{tag: 'a', segment: {id: 1}}, {tag: 'b', segment: {id: 1}}, {tag: 'c', segment: {id: 2}}]};
  const bad = page('<svg><path class="series" data-releases="a b c" d="M0 0"/></svg>');
  assert.deepEqual(lintPage('index.html', bad, segView).map((v) => v.rule), ['connected-across-break']);
  const good = page('<svg><path class="series" data-releases="a b" d="M0 0"/><path class="series" data-releases="c" d="M0 0"/></svg>');
  assert.deepEqual(lintPage('index.html', good, segView), []);
});

test('published data never carries a machine name', () => {
  assert.deepEqual(lintData('data/history.json', {releases: [{rows: [{id: 'x', host: 'yoga'}]}]}).map((v) => v.rule), ['no-host']);
  assert.deepEqual(lintData('data/history.json', {releases: [{tag: 'v1'}]}), []);
});
