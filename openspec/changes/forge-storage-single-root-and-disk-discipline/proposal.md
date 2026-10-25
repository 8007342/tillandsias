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
- **Linux layout** (operator ruling 2026-10-25): `${TILLANDSIAS_HOME:-$HOME/.tillandsias}`,
  visible and easy to find, with fixed subtrees `config/ state/ cache/ podman/
  forges/ logs/`.
- **Own podman store** (ruling 2026-10-25): Tillandsias gets its own rootless
  podman store (separate graphroot and runroot under `<root>/podman`), so its
  containers never collide with the user's. It replaces both stores used today
  (`~/.local/share/containers/storage` and `~/.local/share/tillandsias/podman`).
  This costs one rebuild of every image.
- **Vault and CA** move out of `cache/` into `state/`; existing vault and CA
  are wiped, not migrated (ruling: the vault is thrown away, not recovered).
- **Download manifest**: every large Tillandsias download is listed with its
  size and class (non-negotiable: forge and web images; hot-deletable and
  recreated on demand: models, caches). Later UX shows it in a disk bar.
- **Mount-intent audit**: the forge's affordances, docs, startup context and
  tooling say each mount's intent and limits (scratch is wiped on teardown,
  cache survives and is wiped on corruption, src is RAM).
- **Forge layer table**: four named layers (ram, per-forge scratch, reusable
  cache, durable source of truth) with an owner, lifetime, size rule and
  corruption rule each.
- **Swap policy** (ruling 2026-10-25): disk-backed swap is MANDATORY. The
  Linux tray refuses to start without it and shows plain instructions to
  enable it; zram alone does not count. On macOS VMs and Windows WSL,
  Tillandsias forces the swap configuration known to work, floor-tier hosts
  included.
- **Scratch sizing**: the per-forge scratch folder is generous, sized from
  host free disk at creation, with a floor.
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
- `disk-discipline`: worktree eviction rule, disk-aware skills, download manifest and mount-intent wording.

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
- Existing host paths are wiped, not migrated ("reset is the baseline");
  the new podman store means one rebuild of every image.
