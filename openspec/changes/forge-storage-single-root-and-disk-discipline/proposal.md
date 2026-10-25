## Why

Operator direction 2026-10-25: true ephemerality with single-root containment.
Tillandsias today scatters host state over at least seven roots on Linux
(`~/.cache/tillandsias`, `~/.local/state/tillandsias`, `~/.local/share/tillandsias`,
`~/.config/tillandsias`, `~/.local/share/containers/storage` volumes,
`$XDG_RUNTIME_DIR/tillandsias`, `~/.local/bin`), so a user cannot find, inspect
or delete "everything Tillandsias" in one move. Inside a forge the storage
layers are implicit: the source workspace is a 1.5 GB tmpfs that parallel
subagent worktrees filled to ENOSPC (ranitas FORGE_DIAGNOSTICS.md, order
1866-ubtc), build scratch shares the restart-surviving cache volume, and no
host check ensures the RAM layers can overflow to a real swap device. A full
disk is the most likely cause of overnight forge crashes, and no skill checks
free space before creating a worktree.

## What Changes

- **Cross-platform contract**: one Tillandsias root per host that holds every
  file Tillandsias creates, except a short named exempt list (installed
  binaries/launcher entries, volatile runtime sockets/secrets). Deleting the
  root (with Tillandsias stopped) returns the host to pre-install state.
- **Linux layout**: `${TILLANDSIAS_HOME:-$XDG_DATA_HOME/tillandsias}` with fixed
  subtrees `config/ state/ cache/ podman/ forges/ logs/`; podman graphroot and
  volumes move under it.
- **Forge layer table**: four named layers (ram, per-forge scratch, reusable
  cache, durable source of truth) with an owner, lifetime, size rule and
  corruption rule each.
- **Swap policy**: a disk-backed swap device sized for the RAM layers is
  expected; the tray shows a loud, persistent warning when it is absent.
- **Worktree eviction rule**: free-space and existing-worktree inspection
  before any worktree is created; finished worktrees are evicted only after
  their commits are verified on the remote.
- **Disk-aware skills**: a named list of skills and startup-context lines that
  must run the disk preflight.
- **Per-platform research tasks** for macOS and Windows peers.

## Capabilities

### New Capabilities
- `host-storage-root`: the single-root containment contract and per-platform layout.
- `forge-storage-layers`: the in-forge layer table and swap policy.
- `disk-discipline`: worktree eviction rule and disk-aware skills.

### Modified Capabilities
<!-- Existing specs forge-cache-dual, forge-hot-cold-split, ephemeral-guarantee
and disk-usage-detection are referenced, not modified, by this change; their
deltas land with the implementing orders. -->

## Impact

- `crates/tillandsias-headless`: `prepare_forge_ram_workspace`,
  `forge_hot_src_tmpfs`, forge create argv, tray status, `swap_cmd`.
- `images/default/lib-common.sh` cache-layer exports (`TMPDIR`,
  `PROJECT_CACHE`), `brew-shim-exec.sh` (`HOMEBREW_CACHE`).
- Skills under `.claude/skills/` and the forge startup context.
- Migration of existing host paths (one-time move, or wipe-and-rebuild per
  the "reset is the baseline" ruling).
