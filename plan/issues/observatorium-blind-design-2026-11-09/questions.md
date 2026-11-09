# Open questions for the coordinator

Each entry: why I need it, what I assume meanwhile, what changes if wrong.
Numbered in the order they arose while deriving.

1. **Is there a machine-readable obligation registry (ID, kind, state in the
   seven-chain, evidence bar, weight, tombstone flag)?**
   Why: every page keys on obligation IDs. Assume: yes, producible locally as
   one JSON/YAML export per release. If wrong: the snapshot builder must
   parse spec files itself and the "coverage of obligations" views degrade to
   a count.

2. **Is the per-obligation state (absent…evidence_bundled) actually recorded,
   or only the aggregate CentiColon score?**
   Why: the honesty rule "credit means reaching the configured bar, not the
   top" needs per-obligation state and bar. Assume: per-obligation state is
   recorded by the grader. If wrong: the lattice view is replaced by a
   "state not recorded" placeholder and the learnings note this gap.

3. **What is one "release" for the dashboard's x-axis: a tag, the version
   tuple (years-since-epoch, month, day, build), or a stable promotion?**
   Why: trend charts are indexed by release. Assume: the version tuple,
   with a "stable" flag. If wrong: re-key the series; nothing structural.

4. **Does the grader emit the denominator (total_cc), earned, residual, and the
   regime (Comparable/Broken) per run, and is a durable accepted-release
   baseline stored anywhere?**
   Why: the ratchet view compares releases; the document says the baseline is
   per-checkout and untracked. Assume: the snapshot builder itself keeps the
   history by appending each release's record to a committed history file.
   If wrong (a durable baseline exists): read it instead of maintaining one.

5. **Which platforms are "required" per obligation, and is per-platform pass
   status recorded?**
   Why: the document says grading selects by test digest, not platform; a
   platform matrix is needed to show the gap honestly. Assume: platforms
   known (Linux, macOS, Windows at least) but per-platform attribution absent.
   If wrong (attribution exists): the matrix fills in; otherwise the cells
   show "not attributed".

6. **Where do runtime observations ("runtime_obs" rung) come from, and are any
   exported in a form that may be published?**
   Why: a rung with no public source cannot be shown as reached. Assume: not
   exportable today; the rung is shown as "no public evidence". If wrong:
   add a source descriptor and a link.

7. **Are the sixteen penalties and six cap rules evaluated per release and are
   their individual contributions logged?**
   Why: the score is non-additive; a waterfall needs the parts. Assume: only
   the rolled-up figure exists. If wrong: the waterfall view becomes real.

8. **Is the methodology-to-codebase ratio measurable locally (line counts of
   validators vs. codebase) and would publishing those counts be acceptable?**
   Why: the document flags this constraint as unenforced; the dashboard can
   at least observe it. Assume: counts can be produced with a line counter at
   snapshot time. If wrong: show the obligation as "declared, unmeasured".

9. **Are the generative property tests (monotone/inflationary/idempotent) and
   the CRDT fold tests identifiable by stable test names in CI output?**
   Why: "tested by name" is an auditable claim; the page wants to list the
   names and their last result. Assume: test names are stable and greppable
   in a local test report. If wrong: list the properties with "test name not
   resolved".

10. **Is any part of the snapshot sensitive (host names, operator identity,
    paths)?** Why: the site is public. Assume: host names must not appear;
    the snapshot schema has no host field. If wrong (hosts are public), a
    "measured on" column can be added.

11. **What hosting path exists today for the deploy branch (Pages project
    bound to a branch, or a Worker serving static assets)?**
    Why: pipeline design. Assume: Cloudflare Pages bound to branch
    `deploy`, which builds nothing and serves committed files. If wrong (a
    Worker), the same `dist/` directory is uploaded via a wrangler assets
    config; layout unchanged.

12. **Is the version document's component semantics (contract/phase vs.
    temporal) going to be corrected, and should the dashboard display the
    version as a date?** Assume: display as date-like tuple with the build
    number. If wrong: show raw tuple.

13. **Is there a public issue/plan list from which "open obligations" can be
    linked, or must links point only to the repository tree?** Assume: links
    to repository paths at the release tag only. If wrong: add issue links.

14. **May the snapshot include spec-file digests (hashes) so a reader can
    verify a grade was computed against the published spec?** Assume: yes,
    hashes are not sensitive. If wrong: omit the verification column.

## Round 2 (after answers.md)

15. **Should `stable` promotion be recorded?** The history has no stable flag
    and promotion moves a `stable` tag separately. Assume: the build reads
    the `stable` tag from the local checkout at build time and marks the row
    whose release equals it; rows show "stable: not recorded" otherwise. If
    wrong (a flag gets added to snapshots.jsonl): read it from there.

16. **May a stripped per-release detail file be committed
    (`history/details/<release>.json`: id, req_id, spec, state, reason,
    spec_digest; `host`/`regime` removed)?** ~1571 rows × 7 fields, roughly
    200–300 KB per release. Why: per-obligation history, aligned-scope
    recomputation, per-obligation pages. Assume: acceptable. If wrong: those
    views say "not retained" and only the latest run's rows are shown.

17. **Is replacing the Flutter web client with generated multi-page HTML
    acceptable, and does the operator's deploy machine have Node ≥ 22
    without the Flutter container?** Assume: acceptable, Node present. If
    wrong: the same derived `/data/` view and honesty rules apply and the
    Flutter client renders them; the build-time lint still runs.

18. **Ratchet regime semantics.** `scope-added` exists; is a scope *removal*
    (tombstoned spec dropping obligations) ever emitted, or does it appear
    only as a denominator decrease? Assume: not emitted; the build derives
    it from `scopeSha256`/denominator. If wrong: use the emitted value.

19. **Is the reason taxonomy (`no-binding`, `unrun`, `failed`, `skipped`,
    `spec-changed`) stable, and may per-row reasons be published?** Assume:
    stable and publishable (no host inside). If wrong: publish the histogram
    only.

20. **Which Rust test functions, by exact name, cover monotone /
    inflationary / idempotent refine and the fold's commutativity /
    idempotence?** Why: the claims register wants names and last status.
    Assume: none confirmed; register shows "test name not resolved". If
    answered: fill the names and read status from a local `cargo test` run at
    build time.

21. **Retire or retain the legacy `centicolon-signature` dashboard
    (29 records, 890/990, scheme of 2026-08-09)?** Assume: retain as a
    historical, scheme-labelled series on /instrument/ only. If wrong
    (retire): drop the page section and keep a one-line note.

22. **Should a `dirty: true` or `shallow: true` snapshot be published at
    all?** Assume: published with a visible badge; never dropped. If wrong
    (refuse): the build fails on such a row with the reason.

23. **Per-spec digests in the history.** `spec_digest` exists per obligation
    and in results records but is not exported per spec. Assume: it arrives
    via the detail file (Q16). If Q16 is refused: the release page shows
    only the four aggregate sha256 values already present.

24. **Is `measured: false` with `unmeasured_reason` a row the site should
    show as a gap in the series?** Assume: yes, hatched with the reason. If
    wrong: treat as absent row.
