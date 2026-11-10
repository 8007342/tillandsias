// @trace order:2066-obsv, spec:observatorium-dashboard
// V4 Claims, V5 Instrument, V6 Glossary and the Data page.
import {card} from '../layout.mjs';
import {escape, MISSING, num} from '../honesty.mjs';
import {STRENGTHS} from '../claims.mjs';

const STRENGTH_TEXT = {
  'proved': 'a proof exists, within the stated scope',
  'property-tested': 'generative tests check it over a stated input set',
  'tested by name': 'a named test checks it',
  'external analogy': 'it rests on a comparison with established work, not on a test here',
  'assumed': 'stated, with no proof or named test found',
  'open': 'not established either way',
  'withdrawn': 'once claimed, now retracted',
  'on paper only': 'declared in the methodology, read by no code',
};
const cls = (s) => s.replace(/\s+/g, '-');

export function claimsPage(claims) {
  const counts = STRENGTHS.map((s) => [s, claims.filter((c) => c.strength === s).length]);
  const rows = claims.map((c) => `<tr id="claim-${c.id}" data-review="${c.review}"><th scope="row">${escape(c.statement)}</th><td><span class="strength strength-${cls(c.strength)}">${escape(c.strength)}</span></td><td>${escape(c.scope)}</td><td>${escape(c.discharge)}</td><td>${c.since ? escape(c.since) : `<data class="missing">${MISSING}</data>`}</td><td>${c.review === 'operator-pending' ? 'not yet reviewed by the operator' : 'reviewed by the operator'}</td></tr>`).join('');
  const legend = counts.map(([s, n]) => `<div><dt><span class="strength strength-${cls(s)}">${escape(s)}</span></dt><dd>${escape(STRENGTH_TEXT[s])}. Claims: ${n}.</dd></div>`).join('');
  const pending = claims.filter((c) => c.review === 'operator-pending').length;
  const body = [
    `<section class="card headline" aria-labelledby="claims">
<h1 id="claims">Claims</h1>
<p>What the project says about its own method, and how strongly each statement is established. Retractions stay listed: a withdrawn claim is part of the record, not something to hide.</p>
<p class="badge warn" role="note"><span aria-hidden="true">!</span> This register was seeded by an agent from the design notes. ${pending === claims.length ? 'None of the entries has' : `${pending} entries have not`} yet been reviewed by the operator.</p>
</section>`,
    card('register', 'Register', `<div class="table-scroll"><table class="claims"><caption>Claims and their strength</caption><thead><tr><th scope="col">Claim</th><th scope="col">Strength</th><th scope="col">Scope</th><th scope="col">What would settle it</th><th scope="col">Since</th><th scope="col">Review</th></tr></thead><tbody>${rows}</tbody></table></div>`),
    card('strengths', 'Strength categories', `<dl class="defs">${legend}</dl><p>Colour follows the category only. No colour here means pass or fail.</p>`),
  ].join('\n');
  return {title: 'Claims', description: 'The register of claims, with their strength, including withdrawn ones.', body};
}

export function instrument(view) {
  const l = 'latest';
  const cards = [
    ['Property tests', '<p>The document names three refinement properties (monotone, inflationary, idempotent) and three ledger-fold properties (commutative, idempotent, associative). Their test names are not resolved in this build, so no pass or fail is shown for them here. See the <a href="../claims/index.html">claims register</a> for their strength.</p>'],
    ['Scoring policy', '<p>The live residual is an unweighted count of obligations without a positive test. The weighted policy (methodology/proximity.yaml), its sixteen penalties and six caps are declared and read by no code. An older weighted dashboard (the centicolon-signature scheme, last computed 2026-08-09) used a different scheme and is not comparable with the count shown on this site.</p>'],
    ['Baseline', `<p>The durable baseline is <code>observatorium/history/snapshots.jsonl</code>: committed, one row per release, ${num(view, 'releases.length')} rows. The regression reporter still compares against a per-checkout baseline that is not committed.</p>`],
    ['Records', `<p>Litmus records read for the latest grade: ${num(view, `${l}.residual.records`)}. This counts every digest-bearing record in the local results stream; it does not identify which runs matched these obligations.</p>`],
    ['Platforms', '<p>Platform is not a grading dimension. Results carry a machine name only, and machine names are not published on this site.</p>'],
    ['Runtime observation', '<p>No code assigns the runtime-observed rung. Runtime metrics (processor, memory, disk) exist separately, are not tied to obligations, and are not shown here.</p>'],
    ['Complexity ratio', `<p>The methodology sets a ceiling of 0.15 on methodology size over codebase size, with no check enforcing it. This build does not count lines, so the ratio is <data class="missing">${MISSING}</data>.</p>`],
  ].map(([h, inner], i) => card(`instrument-${i}`, h, inner)).join('\n');
  return {
    title: 'Instrument',
    description: 'How the Tillandsias measurement works, and what it does not measure.',
    body: `<section class="card headline" aria-labelledby="instrument"><h1 id="instrument">Instrument</h1><p>The health of the measuring instrument itself: what it reads, what it does not, and where the methodology promises more than the code does.</p></section>\n<div class="grid">${cards}</div>`,
  };
}

export function glossary() {
  const terms = [
    ['Obligation', 'One scenario a specification states, or a requirement with no scenario. It is what the project has said the software must do.'],
    ['Denominator', 'The number of obligations in scope at a release.'],
    ['Residual', 'Obligations in scope that have not reached the bar. Lower is better; zero would mean every obligation reached it.'],
    ['Bar', 'The rung an obligation must reach to earn credit. Today the one bar is positively tested.'],
    ['Credited', 'Reached the bar. Credit is not the top of the ladder: an obligation can be credited and still lack runtime evidence.'],
    ['Rung', 'A step on the seven-step chain: absent, declared, traced, positively tested, negatively tested, runtime observed, evidence bundled. The grader assigns only declared, traced and positively tested.'],
    ['Segment', 'A run of releases with the same set of obligations and the same measurement method. Charts never join two segments.'],
    ['Break', 'Where a segment ends: the set of obligations, their number or the measurement method changed.'],
    ['Scope digest', 'A sha256 of the sorted obligation ids. Two releases with equal digests grade exactly the same set.'],
    ['CentiColon', 'The project\'s name for its obligation score. On this site it is the residual count above.'],
  ].map(([t, d]) => `<div><dt>${escape(t)}</dt><dd>${escape(d)}</dd></div>`).join('');
  const body = [
    `<section class="card headline" aria-labelledby="glossary"><h1 id="glossary">Glossary</h1><p>Plain definitions of the words used on this site.</p></section>`,
    card('terms', 'Terms', `<dl class="defs">${terms}</dl>`),
    card('not', 'What a score is not', `<ul>
<li>It is not a probability. A share of obligations unmet says nothing about how often the software fails.</li>
<li>It has no complement rule: obligations met and obligations unmet are counts of different evidence, not two halves of one quantity.</li>
<li>It is not comparable across a break. When the set of obligations changes, so does what the number counts.</li>
<li>It is not proof of adequacy. Meeting every obligation would not show that the obligations are the right ones.</li>
</ul>`, 'disclaimer'),
  ].join('\n');
  return {title: 'Glossary', description: 'Definitions of the terms the Tillandsias Observatorium uses.', body};
}

export function dataPage(entries) {
  const rows = entries.map((e) => `<tr><th scope="row"><a href="${escape(e.file)}">${escape(e.file)}</a></th><td>${escape(e.what)}</td><td><code class="digest">${e.sha256}</code></td></tr>`).join('');
  const body = [
    `<section class="card headline" aria-labelledby="data"><h1 id="data">Data</h1><p>Every file this site is built from or publishes, with its sha256, so any number on any page can be checked. Machine names are stripped from everything here; the build refuses to publish a file that contains one.</p></section>`,
    card('files', 'Files', `<div class="table-scroll"><table><caption>Published data files</caption><thead><tr><th scope="col">File</th><th scope="col">What it is</th><th scope="col">sha256</th></tr></thead><tbody>${rows}</tbody></table></div>`),
    card('rebuild', 'Rebuild it yourself', '<p>From a checkout of the repository at the release tag, run <code>node observatorium/site/build.mjs</code>. It reads only the committed history, needs no network and no dependencies, and refuses to write anything if a page would misstate the data.</p>'),
  ].join('\n');
  return {title: 'Data', description: 'The data files behind the Tillandsias Observatorium, with digests.', body};
}
