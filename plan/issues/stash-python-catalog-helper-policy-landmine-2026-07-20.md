# Operator stash holds an uncommitted Python helper that regenerates catalog.rs (policy landmine + hidden tooling)

- Date: 2026-07-20
- Class: exploration / policy-hygiene (nothing committed today — preventive)
- Filed by: linux coordinator cycle (v0.4 stabilization)

## Observed

Local stash `stash@{0}` ("pre-night-loop discard 2026-07-19 (recoverable)") on
the Linux coordinator host contains, alongside tracked-file edits
(catalog.rs +49, main.rs +79, base.Caddyfile +25, two litmus yamls), an
UNTRACKED `update_catalog.py` (+99 lines) — a Python script that rewrites
`crates/tillandsias-headless/src/catalog.rs` from a template header.

During 2026-07-20 stash juggling the untracked copy spilled into the worktree
(`git stash pop` restores untracked files before aborting on tracked
conflicts); it was removed after verifying byte-identity with the stash copy,
so the stash remains the sole, recoverable home of the file. Nothing reached
the index or a commit.

## Why it matters

- `methodology.yaml` `runtime_language_policy.tlatoani_hard_no_python` forbids
  Python for repository scripts. A `git stash pop` of this stash followed by a
  routine "commit everything" cycle would commit a policy violation that
  `scripts/check-no-python-scripts.sh` would then flag loudly — or worse,
  train an agent to bypass it.
- catalog.rs maintenance apparently has a REAL regeneration workflow living
  only in an uncommitted script — hidden tooling that no other host or agent
  can reproduce, and knowledge-distribution debt of exactly the class the
  2026-07-20 AGENTS.md work is closing.

## Smallest fix (exit_criteria)

1. Operator triages stash@{0}: recover what is still wanted, then drop it
   (its name says "recoverable" — decide, don't let it age).
2. If catalog.rs regeneration is a real recurring need, reimplement the
   helper in an approved language (Rust bin or POSIX shell dispatching Rust
   tooling) and commit it; otherwise record that catalog.rs is hand-edited.
- Exit: no stash on the coordinator host contains repo tooling that exists
  nowhere else; catalog.rs's maintenance story is committed (tool or note).
