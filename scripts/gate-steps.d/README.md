# scripts/gate-steps.d — one file per `./build.sh --check` step

Each `NNN-<order>.step` is DATA, not code (1072-b7eq): `STEP_DESC`,
`STEP_SCRIPT` (a LITERAL `scripts/test-<name>.sh` path, greppable — 1063-nraf),
`STEP_ERROR`, `STEP_OK`, optionally `STEP_SKIP_EXIT`/`STEP_SKIP_DESC`. build.sh
runs them in filename order; a step whose script is missing is a refusal, not
a skip. Two hosts adding steps touch two files, so git merges them without a
conflict.

The numeric prefix is the ORDER, spaced by ten so a later step can land
between two without renaming either. No two files may share a prefix
(test-gate-step-append-no-conflict.sh, arm 7, refuses the tree).

You pick the slot you mean; the LAND TOOL keeps it free (1162-qbrx). After
its integrate and before the gate, scripts/land-on-platform-branch.sh runs
`scripts/allocate-gate-step-prefix.sh --base origin/<branch> --commit`: a
step THIS push adds whose prefix the integrate has just taken moves to the
smallest free integer below the next occupied prefix (280 -> 281 when 290
is next) and the rename is committed, so the gate sees the final tree.
Existing steps are never renumbered. `refused:gate-step-prefix:no-gap` means
every integer up to the next occupied prefix is taken: renumber by hand so
the step keeps its intended place. Hand-rolled push: run the allocator
yourself after your merge, before your gate.
