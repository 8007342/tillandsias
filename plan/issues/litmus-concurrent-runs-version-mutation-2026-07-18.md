# Litmus runs mutate shared worktree state (VERSION) — concurrent/overlapping runs poison each other and cargo tests

- Date: 2026-07-18 (UTC 2026-07-19 cycle)
- Host: windows (windows-next)
- Class: optimization/ (test-infra integrity)
- Filed by: windows-bullo-fable5-20260719T0043Z (meta-orchestration capture rule)

## What happened (live, twice in one cycle)

1. A background `run-litmus-test.sh --size instant --phase pre-build` run
   mutated the repo-root `VERSION` file to `0.0.0-test-retag` mid-run (a
   retag-shape test does this in place) while the same checkout was being
   used for cargo tests and a git merge. Effects observed:
   - `wsl_lifecycle::tests::embedded_guest_headless_matches_workspace_version`
     failed spuriously (WORKSPACE_VERSION baked from the mutated file).
   - The merge workflow saw a dirty `VERSION` and had to treat it as
     suspect residue.
2. A SECOND litmus run, started while the first run's residue was still on
   disk, then failed its own `litmus:versioning-shape` STEP 2 ("VERSION has
   2 dots, expected 3") — run A's residue directly failed run B, and some
   share of that run's 16 reported failures are this collateral, not real
   regressions.

The failing test evidently mutates VERSION in place and restores it only on
its own success path; a failure or timeout strands the mutation.

## Why it matters

- False FAIL signals in the litmus summary erode trust in the gate (the
  16-fail summary needed manual triage to separate real regressions from
  residue collateral).
- The runner is not safe to run concurrently with builds, cargo tests, or a
  second runner on the same checkout — but nothing enforces or documents
  that, and recurring loops (meta-orchestration) naturally overlap runs.

## Smallest correct fix (exit criteria)

1. Any litmus step that mutates repo files (VERSION retag et al.) MUST do so
   in a COPY (tmpdir) or restore via an unconditional trap on exit/failure —
   a failed step leaves the worktree byte-identical.
2. The runner takes a per-checkout lock (the smoke-lock pattern already
   exists: `scripts/with-smoke-lock.sh`) so two litmus runs cannot overlap
   on one checkout.
3. A litmus-of-the-litmus: after a full run, `git status --porcelain` over
   tracked files is empty (runner self-check, loud on residue).

## Residual triage from this cycle's 16-fail run (for the coordinator)

Beyond the VERSION collateral, real/known items observed:
- `litmus:git-mirror-*` case-4 fast-forward + relay fixtures — the already
  filed linux-lane regressions (orders 413-415 family).
- credential-channel STEP 8 (forge mirror-origin seam) — forge fixture
  expects a mirror-resolved origin; windows host runs with plain GitHub
  origin + GCM. Needs a windows-lane look or an explicit skip-on-windows.
- `litmus:smoke-lock-fd-isolation-shape` STEP 2 (orphan retains lock,
  rc=75) — flock orphan semantics differ on Windows/MSYS; needs a
  windows-specific implementation or skip with reason.
