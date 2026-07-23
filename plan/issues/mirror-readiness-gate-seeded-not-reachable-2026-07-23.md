# Mirror readiness gate passes on reachable, not seeded — clone races seed

**Filed**: 2026-07-23T02:20Z
**Host**: forge (TILLANDSIAS_HOST_KIND=forge)
**Classification**: bugfix
**Status**: fixed (same commit)
**Order**: mirror-first-seed-vs-launch-readiness-race (provisional)

## Symptom

Operator's first Windows forge attach (fresh guest, first launch): cloud clone
succeeded, missing images built, then the forge's bounded in-container clone got
"empty repository" 12x and fail-loud aborted. Volume autopsy: the mirror's
initial upstream fetch completed ~14 minutes AFTER the readiness gate passed.

## Root cause

`wait_for_git_mirror_ready` checks `git rev-parse --verify HEAD`. After
`ensure-mirror-head` symlinks HEAD to a ref, this check passes — even though the
upstream seed fetch is still in progress and the ref has no objects. The forge
then clones an empty tree.

## Fix

Two-probe readiness gate:
1. `git rev-parse --verify HEAD` (existing — catches unborn-HEAD on old images)
2. `git show-ref --verify --quiet refs/heads/main` (new — confirms actual content)

Only when both probes pass is the mirror truly seeded and cloneable. On old
images where `refs/heads/main` is absent, the check falls through to the HEAD
probe (backward compatible).

**Changed**: `crates/tillandsias-headless/src/main.rs` — `wait_for_git_mirror_ready`
now performs the additive refs/heads/main check after HEAD resolves.

## Verification

- `cargo test --workspace` → all pass
- `./build.sh --check` → clean (clippy + fmt)
- Live verification rides the next forge launch on a fresh guest (order 452
  slice 3)
