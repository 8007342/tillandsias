# Enhancement: stale per-tag Nix caches never purged — warm cache can LRU-evict before verification

- **Filed**: 2026-06-20 (linux_mutable, Claude Opus 4.8 Cowork meta-orch static review)
- **Class**: enhancement (robustness gap in the Order 64 fix, not a correctness break)
- **Relates to**: Order 64 `release-nix-cache-ref-scoping`, deliverable
  `plan/issues/release-nix-cache-ref-scoping-2026-06-20.md`
- **Reviewed commit**: `d273daff` (Gemini, "resolve Nix store cache ref-scoping
  regression and configure build monitoring")

## What was reviewed

Static correctness review of the just-landed Option-2 (warm-cache-on-main)
implementation, performed on a host that cannot run releases, to de-risk the
two-release `verify-incremental` step before CI cycles are spent on it.

### Confirmed correct (no action needed)

1. **Architecture defeats ref-scoping.** `nix-cache-warm.yml` SAVES the cache
   (no `save: false`) on `push` to `main`/`linux-next`, weekly `cron`, and
   `workflow_dispatch`. Scheduled events run on the default branch (`main`), so
   the weekly run populates a **main-scoped** cache, which GHA makes restorable
   from every other ref including tag-dispatched releases. `release.yml` now sets
   `save: false`, so releases only RESTORE. This correctly breaks the prior
   ref-isolation where each tag saved its own never-reused 2.2 GB cache.
2. **`hit` output name is right.** The monitoring step reads
   `steps.nix-cache.outputs.hit`. `nix-community/cache-nix-action` exposes `hit`
   (exact primary-key match); `cache-hit` is the `actions/cache` name. Gemini's
   correction from `cache-hit` → `hit` is correct.
3. **Key parity holds.** Both workflows compute
   `primary-key: nix-${{ runner.os }}-${{ hashFiles('flake.lock') }}` and both
   run on `ubuntu-22.04`; `runner.os` is `Linux` in both, so an unchanged
   `flake.lock` yields an exact restore (`hit=true`) on release.

## The gap

The `implement-cache-fix` handoff_note explicitly required: *"add purge of
unreusable per-tag Nix caches to stay under the 10 GB GHA limit."* **No purge /
gc / `gh actions-cache delete` step exists in either workflow.** Verified by
grep across `.github/workflows/`.

This matters because the original finding (Order 64) recorded that the repo
cache was **already over the 10 GB limit**, so LRU eviction is active. The
accumulated old per-tag release caches (2.2 GB each) are now dead weight that
`save: false` stops *adding to* but does not *remove*. Under the 10 GB cap with
LRU, those stale entries can evict the freshly-warmed main-scoped cache before
the two `verify-incremental` releases run, producing either:

- a spurious `hit=false` cache-miss warning from the new monitoring step, or
- an actual full cross-GCC rebuild on release — silently re-introducing the
  exact ~10 min / 2.2 GB waste the packet exists to remove.

`cache-nix-action@v7` supports this natively: `purge: true` with
`purge-prefixes: nix-Linux-`, `purge-created` / `purge-last-accessed` windows,
and `gc-max-store-size`. **Purging requires `permissions: actions: write`**,
which `nix-cache-warm.yml` does not grant (`contents: read` only) and
`release.yml` does not grant at all. So the permission must be added alongside
the purge inputs.

## Minor (not blocking)

The monitoring reads only `hit` (exact match). If `flake.lock` changes between
warm and release, only a prefix restore occurs (`hit-first-match=true`,
`hit=false`), firing a spurious cache-miss `::warning::` despite a large
restore. Soft warning only; consider also reading `hit-first-match`.

## Reduction

Promoted to a `ready` sub-packet under Order 64,
`release-nix-cache-ref-scoping/purge-stale-caches`: add `purge: true` +
`purge-prefixes: nix-Linux-` + a `purge-created` window + `gc-max-store-size`,
and `permissions: actions: write`, to the **warm** workflow (the job that owns
saving). Verifiable closure: a warm run reports purged entries and the repo
cache footprint drops back under 10 GB, observable via `gh actions-cache list`.
This should land before `verify-incremental` so the two measurement releases run
against a clean, non-evicting cache.

## Completed

Implemented 2026-06-21T03:32Z (linux big-pickle). Added `purge: true`,
`purge-prefixes: nix-Linux-`, `purge-created-offset: 86400000` (24h window),
`gc-max-store-size: 8000000000` (~8 GB), and `permissions: actions: write`
to `.github/workflows/nix-cache-warm.yml`. Sub-packet status flipped to `done`
in plan/index.yaml. Commit `38015e2f` on `linux-next`.
