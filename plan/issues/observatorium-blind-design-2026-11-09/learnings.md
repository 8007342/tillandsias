# Learnings and risks from the backward derivation

Ordered by how much they change the design or the obligations.

1. **The headline metric is undefined; the dashboard must say so.** The
   release rule is "non-increase of d_v", but d_v is never defined (the
   document says so). *rev2: Q2, Q7.* The answers sharpen this: there is only
   **one** live projection, an unweighted count of obligations without a
   positive test over a denominator (1571/1571 at the latest release). The
   weighted policy, sixteen penalties and six caps are read by no code; the
   890/990 figure is an older, different scheme last computed 2026-08-09.
   So the rev1 "two projections" display was itself an overclaim: it would
   have shown a weighted number that does not exist. Design response: one
   count, plainly "1571 of 1571 unmet", the grader's reasons histogram
   beside it, and the weighted scheme listed as "on paper only".

1b. **The seven-rung lattice is a paper object; the live ladder has three
   rungs.** *rev2: Q2, Q6.* `absent`, `negatively_tested`, `runtime_observed`
   and `evidence_bundled` are never assigned by any code. The rev1 design
   would have drawn a seven-rung ladder as if a grader could fill it. The
   honest rendering is: seven slots, three solid, four hatched "never
   produced". This is the largest single gap between the level-5 document's
   model and the system it describes, and both designs built from that
   document would inherit it (Knight–Leveson).

2. **The existing dashboard defect (a frozen 890/990) is a pipeline property,
   not a display bug.** The document says the committed dashboard is a
   historical snapshot, not a measurement of the release. Any redesign that
   does not couple the published figure to the release it claims to measure
   will reproduce it. *rev2: Q11.* Because the deploy branch holds source and
   the build runs inside `wrangler deploy` on the operator's machine, the
   check has to live in that build: last history line ↔ newest reachable tag
   ↔ `Observatorium-Release` trailer, all three equal or the build refuses.
   A check on a committed `dist/` (rev1) would have had nothing to check.

3. **Scope changes are the main way a progress chart lies.** Tombstones,
   added obligations and bar raises all move the denominator; a ratio can
   improve while an old gap stays open. The document names this; the design
   makes it structural: regime breaks cut the series, the goalposts ledger sits
   beside the chart, and the only cross-break figure is the recomputed
   aligned-scope residual. *rev2: Q4.* The live vocabulary is the ratchet's
   `baseline | monotone | scope-added`, not Comparable/Broken; the history
   already carries `scopeSha256`, so scope change is derivable per row
   without new producer work. In seven releases the denominator moved
   1536→1567→1571 while satisfied stayed 0: the chart will show two breaks
   and a flat line, and that is the true picture.

4. **Half the evidence chain has no public witness.** `traced`,
   `runtime_obs` and `evidence_bundled` have no described exportable artefact.
   A public site can relay the grader's claim but cannot let a reader verify
   it. This is a limitation of the obligations' evidence policy, not of any
   dashboard; the page should carry "(claimed by grader)" until the project
   defines a publishable witness.

5. **Thirteen of twenty-nine obligations are unmeasurable or ambiguous as
   written.** Undeclared K, undefined "required platform" per obligation,
   undefined workstream scopes, "operator decision" without an evidence form,
   "complexity" without a unit. These are findings for the obligation
   authors; both the blind and the existing design will fail them identically
   (the Knight–Leveson shared-specification effect), so the comparison must
   not score either design on them.

6. **The project's negative results are its best public asset.** Withdrawn
   strong-law claim, retracted CRDT header, explicit "no contraction, no
   Galois connection, no probabilities". Most dashboards have no place to
   show a retraction. A claims register with strength categories (proved,
   property-tested, tested-by-name, external analogy, open, withdrawn) turns
   candour into a visible, auditable feature instead of a footnote.

7. **"Not a probability" is a display rule, not just a semantics note.**
   The temptation to print 89.9% as confidence is the exact misreading the
   document forbids. Lint for probability vocabulary and the two-integers-first
   rule enforce this at build time rather than relying on authors.

8. **Platform attribution is the largest silent gap.** *rev2: Q5, Q10.*
   Revised: platform is not a grading dimension at all; results carry a
   machine `host` name, which is sensitive and must not be published. The
   rev1 obligation × platform matrix is withdrawn because there is no data to
   put in it; a matrix of all-"not attributed" cells would have implied the
   axis exists. Replaced by one explicit sentence on /instrument/. The
   learning stands in a stronger form: an axis the document treats as a
   grading gap is, in the system, not an axis.

9. **A durable baseline exists; the ratchet does not use it.** *rev2: Q4.*
   Revised: `history/snapshots.jsonl` is a committed per-release history
   (seven rows) and is the right baseline. The regression reporter still
   compares against a host-local untracked `last.txt`. So the defect is not
   "no baseline" but "the instrument that could enforce non-regression reads
   the wrong one". The rev1 proposal of a site-owned history is withdrawn;
   the site consumes the existing file and publishes a derived view.

9b. **Aggregate history, detail lost.** *rev2: Q1.* Per-obligation rows
   (id, state, reason) are produced every run but only the aggregate is
   committed. Per-obligation history, the aligned-scope recomputation and
   the per-obligation page all depend on retaining those rows (host
   stripped) per release — a small producer change (Q16) that unlocks most of
   the technical reader's views.

9c. **The existing site is a Flutter SPA served as static assets.**
   *rev2: Q11.* The blind design converged on generated multi-page HTML with
   no runtime framework; the existing one is a Flutter web bundle with
   `single-page-application` not-found handling. This is a genuine design
   disagreement for the comparison, not a correction: the rubric should
   score it on no-JS completeness, payload size, accessibility and
   buildability on the operator machine (Flutter needs a container; Node is
   already required).

10. **Manual deploy is a feature for honesty and a risk for staleness.** No
    auto-deploy means the public page can lag releases indefinitely. Mitigate
    by the stamp (readers can see the lag) rather than by automation; add
    "latest known release" vs "release shown" only if a trusted release list
    is publishable (open question).
