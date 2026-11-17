# /home/forge/src fills under a multi-agent Flutter run (order 2065-5vcv)

Filed 2026-11-09 from the demon_attack forge session (demon-attack-3e),
relayed by macuahuitl-fedora. Ties into the disk-aware-forges direction and
openspec change `forge-storage-single-root-and-disk-discipline`.

## Observed (reported by the forge session, not re-measured here)

- `/home/forge/src` was a 1.5 GB tmpfs, shared by the checkout and every
  `.claude/worktrees/` worktree.
- Three agents filled it to 89%, and once to 100%.
- `.dart_tool/build` was 40–110 MB per worktree, and a Flutter web build was
  62 MB.

## What exists today (read from the source)

- `HOT_PATH_SOURCE_FLOOR_MB = 1536` (crates/tillandsias-core/src/config.rs).
  This is the 1.5 GB the session saw.
- Order 2006-srcr: the budget grows from the recorded high-water mark plus
  25%, and from a declared `[forge] src_mb`. Both are clamped to
  `hot_path_max_mb` and to half of the forge's `memory.max`, so a RAM-backed
  src can never outgrow the cgroup. The next launch of this project should
  get more room, but only up to that clamp.
- lib-common.sh prints a "/home/forge/src is FULL" diagnosis after git hits
  ENOSPC. That is after the fact, not before a build.

## Ask

1. Put worktrees and regenerable build caches (`.claude/worktrees/`,
   `.dart_tool/`, `build/`, `.cache/`) on disk-backed storage, or make
   `src` disk-backed. Then a multi-agent run is no longer bounded by half
   the forge's RAM.
2. Warn about free space before a build: a forge helper that checks
   `df /home/forge/src` and warns at 80% with the biggest regenerable dirs.
   Claude Code's own `rm` prompts make it hard to free them by hand (see
   2065-baby).

## Closure

A three-worktree Flutter web build in a forge completes without ENOSPC, and
the pre-build check warns when it is run against a src that is more than 80%
full.
