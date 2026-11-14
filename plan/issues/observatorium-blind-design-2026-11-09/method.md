# Method: a clean-room design protocol and an unanchored comparison

Blind designer, 2026-11-09. Inputs read: `input/level-5-phd.md` only, plus the
public web sources cited below. Nothing from the project's repositories or
hosted sites was read.

## 1. What the literature offers

### 1.1 Cleanroom software engineering (Mills, Dyer, Linger 1987)

Cleanroom is not a "blind" technique; the name is about preventing defects
from entering rather than removing them later. Three ideas transfer directly:

- Specify first, verify against the specification, and separate the people who
  build from the people who test. The test subset is chosen from the
  **specification's** input/output trajectories, not from the implementation.
- Statistical usage testing: "the statistics come from the usage of the
  software, not from its intrinsic properties." For a dashboard this says the
  acceptance test is *what a reader does with it*, not what the build emits.
- The Selby/Basili/Baker empirical evaluation (15 three-person teams, 10
  Cleanroom, 5 traditional) is the template for comparing two developments of
  the same requirement: same spec, independent teams, a pre-agreed measurement.

Sources: Mills, Dyer, Linger, *Cleanroom Software Engineering*, IEEE Software
4(5):19–25, 1987, doi:10.1109/MS.1987.231413
([Wikipedia summary](https://en.wikipedia.org/wiki/Cleanroom_software_engineering));
Selby, Basili, Baker, *Cleanroom Software Development: An Empirical
Evaluation*, IEEE TSE 1987
([record](https://www.scilit.net/publications/6378e3011d4f19d38ece2f128c8a3a66)).

### 1.2 Clean-room reverse engineering / Chinese wall (Phoenix BIOS)

The Phoenix BIOS procedure: team A reads the artefact and writes a functional
specification; team B, with no exposure to the artefact, implements from the
specification alone. The legal point (independent creation) is irrelevant
here; the methodological point is the **one-way membrane**: the only thing
that crosses from the existing system to the blind team is a specification
document, and questions cross back as written questions answered in writing.
Sony v. Connectix is the cautionary case: a wall that is breached once is no
wall.

Sources: [Clean-room design](https://en.wikipedia.org/wiki/Clean-room_design);
Schwartz, *Reverse engineering*, Computerworld 2001
([article](https://www.computerworld.com/article/2585652/reverse-engineering.html)).

### 1.3 N-version programming and design diversity

Chen & Avizienis (1977) conjectured that independent development greatly
reduces identical failures. Knight & Leveson (1986) tested that with 27
versions from one specification and found correlated failures far above the
independence prediction; the 1990 reply stood by the result. Two lessons:

- Independence of *people* does not give independence of *errors*: both
  designs will inherit the same blind spots from the **shared specification**.
  So the comparison must also score the specification (the level-5 document),
  not only the two designs. Where both designs make the same questionable
  choice, suspect the input.
- Where the designs disagree, the disagreement is the information. The
  comparison should enumerate disagreements and resolve each by evidence, not
  by majority.

Sources: Knight & Leveson, *An Experimental Evaluation of the Assumption of
Independence in Multiversion Programming*, IEEE TSE 12(1):96–109, 1986
([PDF](https://www.kth.se/social/files/564df871f2765419e306178d/KnightLeveson.pdf));
Knight & Leveson, *A Reply to the Criticisms…*, SEN 1990
([PDF](https://www.cs.washington.edu/homes/leveson/critics.pdf));
[N-version programming](https://en.wikipedia.org/wiki/N-version_programming).

### 1.4 Requirements traceability (Gotel & Finkelstein 1994)

The traceability problem is mostly *pre-requirements* traceability: knowing
where a requirement came from and who can say what it means. Backward
traceability (artefact → requirement) is what a dashboard has to exhibit:
every number on the page must point back to a named obligation, and every
obligation must either be covered or be visibly listed as uncovered. The
level-5 document helpfully gives every obligation a stable identifier
convention, so the backward trace is feasible.

Source: Gotel & Finkelstein, *An Analysis of the Requirements Traceability
Problem*, ICRE 1994, pp. 94–101 ([UCL Discovery](https://discovery.ucl.ac.uk/749/)).

### 1.5 Goal–Question–Metric (Basili, Caldiera, Rombach 1994)

GQM gives the derivation grammar: a conceptual **goal** (object, purpose,
quality focus, viewpoint, environment), operational **questions** that
characterise the goal, and quantitative **metrics** that answer the
questions. A metric may serve several questions; a question may need several
metrics. The viewpoint field matters here: the same obligation yields
different questions for a non-technical reader than for a reviewer.

Source: Basili, Caldiera, Rombach, *The Goal Question Metric Approach*,
Encyclopedia of Software Engineering vol. 1, Wiley 1994, pp. 528–532
([slide](https://www.cs.umd.edu/users/basili/qip/tsld025.htm),
[summary](https://msdbok.github.io/content/proc/basics/gqm.html)).

### 1.6 Anchoring and blind scoring

Shown a prior score, raters (human and LLM) drift towards it; seven of eight
models in one 2026 study showed significant anchoring. Blind first-pass
scoring with a shared, evidence-anchored rubric, then reconciliation, is the
standard mitigation; rubric *layout* can itself induce halo effects.

Sources: [Anchoring Bias in LLM-as-a-Judge Systems](https://arxiv.org/pdf/2608.25869)
(preprint; check before relying on numbers);
Humphry & Heldsinger, *Common Structural Design Features of Rubrics May
Represent a Threat to Validity*, Educational Researcher 2014,
doi:10.3102/0013189X14542154.

## 2. Protocol followed in this exercise

1. **Membrane.** One input document. Footnote paths treated as opaque labels.
   No repository, site, or search for the project by name.
2. **Backward derivation, not forward invention.** Every design element is
   introduced by a trace line `OBL-xx → Q → M → data → view`
   (`derivation.md`). Elements with no trace are either dropped or labelled
   *designer's addition* so the comparison can discount them.
3. **Questions, not guesses.** Unknowns about the existing system are logged
   in `questions.md` with the assumption adopted and the consequence of being
   wrong. The design is built on the stated assumptions; nothing is inferred
   from the footnote paths.
4. **Spec critique is a deliverable.** Per Knight & Leveson, obligations that
   are unmeasurable or ambiguous *as written* are flagged, because both designs
   will fail on them in the same way and the comparison would otherwise miss it.
5. **Honesty rules are written before the visuals.** The data-display rules
   (missing ≠ zero, every number dated and sourced, no ratios without
   denominators) are fixed in `design.md` §3 before any chart is chosen, so
   that chart choice cannot relax them.

## 3. How the later comparison should be scored

Goal: compare design B (this, blind) with design A (existing) without either
anchoring the judge.

1. **Rubric first, designs second.** The rubric is derived from
   `derivation.md`'s obligation list *and* a coordinator-supplied list of
   obligations A was built against, unioned. Neither design's page list is
   used to build the rubric.
2. **Criteria.** For each obligation: (a) covered / partially / not; (b) is
   the datum verifiable back to a named source and time; (c) does the display
   honour the honesty rules (missing shown as missing; denominator shown with
   every ratio; non-comparable regimes shown as breaks). Plus cross-cutting:
   reader-viewpoint fit (non-technical and technical), implementability as a
   static site under the stated deploy constraint, accessibility.
3. **Blind, parallel scoring.** Two judges (ideally neither author) score A and
   B in randomised order, labelled X and Y, without seeing each other's
   scores. The label→design mapping is revealed after both score sheets are
   submitted. Judges see the designs as rendered pages or page descriptions,
   not as repository diffs, so that familiarity with the codebase does not
   leak which is which.
4. **Agreement check.** Report per-criterion disagreement; discuss only
   disagreements, with evidence pointing into the design text. Do not average
   away a disagreement; record it.
5. **Diversity analysis (the N-version step).** List decisions where A and B
   agree and where they differ. Shared choices that score poorly indicate a
   defect in the level-5 document or in the obligations themselves; these go
   back to the obligation authors, not to either designer.
6. **Spec defects count.** Each flagged unmeasurable/ambiguous obligation in
   `derivation.md` is checked against A: did A silently measure it anyway? If
   so, that is a finding against the obligation text, scored neutrally for
   both designs.
7. **Output.** A merged design is allowed only after scoring; scoring the merge
   is a separate round.
