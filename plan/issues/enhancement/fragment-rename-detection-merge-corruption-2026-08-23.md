# git rename detection can write conflict markers INTO "immutable" ledger fragments

- Date: 2026-08-23 (UTC). Host: macos tlatoanis-macbook-air. Class: enhancement.
- Related: concurrent-ledger-append-without-manual-merges-2026-08-02.md (the
  fragment channel's founding premise: unique filenames make merges
  conflict-free), order 636-9m79 (set-field), 787-f7dh (unparseable-fragment
  guard family).

## What happened

Merging origin/linux-next into osx-next after BOTH sides ran a concurrent
compaction (mine + upstream 8387e275e, folding overlapping fragment sets),
git's rename detection paired two set-field-generated fragments from
DIFFERENT hosts — plan/index.d/20260823t074251z-2c7ea3e8-tlatoanis-…
(this host's 723-ji4v claim) and …074427z-36448447-lenovinha.yaml
(lenovinha's 829-dkuc claim) — because their generated content is nearly
identical (same header comment block, same `status:`/`events:` shape). It
then wrote a SINGLE marker-laden blob under both "renamed" names. A naive
`git checkout --theirs` + `git add` accepted the corrupted bytes into both
files: two immutable fragments now contained `<<<<<<<<` markers, parsed by
nothing, their packets invisible in every answer.

The fold's `malformed=` counter caught it (`tillandsias-plan fragments`),
which is the one backstop that fired. `check-added-fragments-parse.sh`
would NOT have: it examines fragments the outgoing diff ADDS, and these
presented as renames of existing paths.

## Why the founding premise did not hold

Unique filenames make ADD/ADD conflicts impossible, but rename detection
compares CONTENT similarity across differently-named files — and set-field's
generated fragments are ~90% boilerplate. Deletions from a concurrent
compaction on one side supply the "deleted" half; a similar new fragment on
the other side supplies the "added" half; git infers a rename and merges
their bodies.

## Reductions (candidate slices)

1. Post-merge fragment-parse verification as a stated step of the platform
   merge discipline (the fold's `malformed=` line makes it one command:
   `tillandsias-plan fragments` must report `malformed=0` before the merge
   commit). Cheap, catches every corruption of this class regardless of
   cause.
2. Consider `merge.renames=false` (or `-X no-renames`) for this repo — no
   ledger workflow ever renames a fragment, and rename detection has
   negative value under plan/index.d/*. Needs a check that it does not
   regress other merges (crate moves DO rename).
3. Reduce set-field fragment boilerplate similarity (e.g. lead with the
   packet_id) so the similarity score drops below git's rename threshold.
   Weakest of the three — threshold-dependent.

Recovered by restoring each path to its own side's clean bytes
(`git show HEAD:…` / `git show origin/linux-next:…`); ledger green at 535
packets, malformed=0.
