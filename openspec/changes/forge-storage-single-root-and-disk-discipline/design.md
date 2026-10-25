## Context

Audit performed 2026-10-25 on macuahuitl (Fedora 44, btrfs `/home`, 62 GiB
RAM, 8 GiB zram swap, no disk swap) against a live `tillandsias-tillandsias-forge`,
read-only, plus the code paths named below (cited by symbol).

### Inventory: what Tillandsias writes today (Linux host)

| Path | What | Created by | Class |
|---|---|---|---|
| `~/.cache/tillandsias/` | image-build logs, `*-containerfile-mtime` stamps, `init-build-state.json`, `capabilities.json`, CA (`ca-cert.pem`, `ca-key.pem`, `ca/`), `vault-data/`, `vault-audit/`, `secrets/`, `models/`, `sccache/`, `packages/`, `recipe-cache/`, `plan-cache/`, `openspec-pinned/`, `dev-proxy-cache/`, `forge-gitconfig/`, `forge-repo-gitdir/`, `metrics/`, `telemetry/`, `git-push.log`, `lane-attribution.jsonl`, `overlap-refusals.jsonl`, `service-restarts-*`, `target-codex-*` | tray/headless, scripts | mixed: cache, durable state, and key material in a cache dir |
| `~/.local/state/tillandsias/` | `ca/intermediate.crt` (bound into forge at `/run/tillandsias/ca-chain.crt`), `msg/lanes/<lane>` (bound at `/run/host/tillandsias-msg`), `preview-ca/`, `attached-sessions/`, `known-cloud-projects`, `image-build-events.jsonl`, `setup.log`, `benchmarks/`, `delegate-runs/`, `podman-wedge/` | tray/headless | state + logs |
| `~/.local/share/tillandsias/` | `podman/` (a separate vfs graphroot: `db.sql`, `vfs*`, `libpod`, `networks`), `nix-store/`, `nix-cache/`, `runtime/` | builder/nix cache service | data |
| `~/.config/tillandsias/` | `installation-uuid`, `host-push/`, `dev-host-experts` | installer/tray | config |
| `~/.local/share/containers/storage/` | default rootless podman store: images, containers, and volumes `tillandsias-forge-cache-<project>` (~4 GiB here), `tillandsias-source-<hash>` (tmpfs-backed, see below) | podman on behalf of tray | data (outside any tillandsias root) |
| `~/.config/containers/` | `containers.conf` (+ `.bak` copies) | installer | config outside root |
| `$XDG_RUNTIME_DIR/tillandsias/` | `mcp/<lane>` (bound at `/run/host/tillandsias-mcp`), runtime secrets and the vault unseal key (refused unless on tmpfs: `path_is_tmpfs`, `write_runtime_secret`) | vault_bootstrap | volatile, exempt |
| `~/.local/bin/` | `tillandsias`, `tillandsias-plan`, `tillandsias-lane-ssh`, validator stamp | installer | exempt (installed artifacts) |
| `~/.local/share/applications/tillandsias.desktop` | launcher | installer | exempt |
| root (opt-in) | `tillandsias --swap on` (`swap_cmd`) swap file + units; `removal_paths` is the uninstall list | `swap_cmd` | system, exempt |

### Inventory: a forge's mounts today (live inspect)

| Destination | Backing | Size | Lifetime |
|---|---|---|---|
| `/home/forge/src` | podman volume `tillandsias-source-<hash>` with `type=tmpfs,o=size=1536m` (`prepare_forge_ram_workspace`, size from `forge_hot_src_tmpfs` → `compute_source_budget`, clamped to half `memory.max`) | 1.5 GiB RAM | lane; removed by `remove_source_volume_if_present` when no forge of the lane runs |
| `/home/forge/.cache/tillandsias-project` | podman volume `tillandsias-forge-cache-<project>` on host disk | unbounded (host disk) | survives forge restarts; per project |
| `/tmp` | tmpfs | 256 MiB | container |
| `/run/user/1000` | tmpfs | 64 MiB | container |
| `/home/forge/.ssh`, `/home/forge/.config/gh` | tmpfs | 1 MiB each | container |
| `/opt/cheatsheets` | tmpfs | 8 MiB | container |
| `/dev/shm` | tmpfs | 62.5 MiB | container |
| `/home/forge/.gitconfig` | bind `~/.cache/tillandsias/forge-gitconfig/<project>.config` | file | host |
| `/run/tillandsias/ca-chain.crt`, `/run/host/tillandsias-msg`, `/run/host/tillandsias-mcp` | binds (above) | — | host |
| everything else (`/home/linuxbrew/.linuxbrew`, `~/go`, `~/.local`) | container overlay upper dir on host disk | unbounded | container (lost on remove) |

Environment (`lib-common.sh`): `TILLANDSIAS_PROJECT_CACHE` =
`/home/forge/.cache/tillandsias-project`; `TMPDIR=$PROJECT_CACHE/tmp` (order
1729-kg5q); `PNPM_HOME`, `UV_CACHE_DIR`, `PIP_CACHE_DIR` under the cache;
`HOMEBREW_CACHE=$TILLANDSIAS_PROJECT_CACHE/brew-cache` (`brew-shim-exec.sh`);
`GOPATH`, `GEM_HOME` unset (default to overlay `~/go`, `~/.gem`).

### Suspicion check: "shim downloads land on the ramdisk"

On Linux this is **not confirmed**: brew bottles download to the cache volume
(`HOMEBREW_CACHE`) and install into the container overlay (disk), and
`TMPDIR` points at the cache volume. The tmpfs that fills is `/home/forge/src`
(ENOSPC from parallel worktrees, 1866-ubtc), plus `/tmp` for tools that
ignore `TMPDIR`. Two real defects remain: (1) build scratch in
`$PROJECT_CACHE/tmp` survives restarts, so it is not ephemeral and grows the
reusable cache without bound; (2) the overlay upper dir is unbounded and
unaccounted. macOS and Windows peers must re-run this check, because in a
VM guest the "disk" behind the overlay may itself be RAM or a sparse image.

## Goals / Non-Goals

**Goals:** one findable, deletable root per host; explicit forge layers with
size and corruption rules; swap expectation surfaced in the tray; disk-aware
worktree creation.

**Non-Goals:** implementing any of it here (orders below); changing vault
cryptography; relocating installed binaries.

## Decisions

### D1. Linux root: `${TILLANDSIAS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/tillandsias}`

XDG splits cache/config/state/data across four trees; that is the opposite of
"find it and delete it". The XDG base-dir spec allows an application to keep
one tree under `XDG_DATA_HOME`. We pick that one tree and lay XDG's categories
out *inside* it:

```
$TILLANDSIAS_HOME/
  config/        installation-uuid, host-push, dev-host-experts
  state/         ca/, preview-ca/, msg/, attached-sessions/, known-cloud-projects, vault/ (data+audit)
  logs/          image-build-*.log, setup.log, *.jsonl event logs (rotated, capped)
  cache/         CACHEDIR.TAG; sccache, models, packages, recipe-cache, plan-cache, openspec-pinned, nix-cache
  podman/        graphroot + volumepath for all tillandsias containers/volumes (storage.conf override)
  forges/<lane>/ scratch/ (per-forge disk layer, deleted with the forge)
  projects/<p>/  cache/ (reusable layer, was tillandsias-forge-cache-<p>)
```

- Volatile: `$XDG_RUNTIME_DIR/tillandsias` stays (tmpfs; secrets may never be
  at rest — ruling 2026-10-19). It is exempt because it dies with the session.
- Exempt installed artifacts: `~/.local/bin/tillandsias*`, the `.desktop`
  entry, the opt-in swap file (root-owned; `swap_cmd::removal_paths`).
- `~/.config/containers/containers.conf` edits are replaced by a
  `CONTAINERS_STORAGE_CONF`/`--root`/`--runroot` scoped to the root, so the
  user's own podman config is untouched.
- Silverblue/immutable: `/home` is `/var/home`, writable and preserved by
  rpm-ostree; nothing goes in `/usr` or `/etc`. On btrfs, `cache/`, `podman/`
  and `forges/` SHOULD be a nested subvolume (excluded from snapshots, and
  `nodatacow` for swap and VM images) — recorded as a research task.
- Discoverability: the tray menu gets "Open storage folder" and "Storage
  report" (per-subtree size). A `~/.tillandsias` symlink is an open question.

### D2. Layer table (inside a forge)

| Layer | Mount | Backing | Size rule | Lifetime | On corruption | Contents |
|---|---|---|---|---|---|---|
| L0 ram | `/home/forge/src`, `/tmp`, `/run/user/1000`, `/dev/shm` | tmpfs, counted in forge `memory.max` | src: `compute_source_budget`; `/tmp` 256 MiB | forge | wipe | source checkout + worktrees, sockets, tiny temp |
| L1 scratch | `/home/forge/scratch` (`TMPDIR=/home/forge/scratch/tmp`) | per-forge podman volume under `forges/<lane>/scratch` on disk | capped at a fraction of host free space at create | deleted when the forge is removed; never reused | n/a | temporary tool downloads, framework tarballs, build dirs that overflow L0 |
| L2 reusable cache | `/home/forge/.cache/tillandsias-project` | `projects/<p>/cache` on disk, stamped with an image/toolchain version | soft cap + LRU eviction report | survives forge restart | **wipe and recreate, never repair** | flutter/pub, go mod/build, ruby gems, brew cache+cellar shims, npm/pnpm, cargo registry, models, studio images |
| L3 source of truth | git mirror / remote | host | — | durable | — | commits; a worktree is evictable once its commits are on the remote |

Rules: L0 MUST overflow to swap (D3); anything an agent downloads that is not
source MUST go to L1 or L2, never L0; `GOPATH`, `GOMODCACHE`, `GEM_HOME`,
`BUNDLE_PATH`, `PUB_CACHE` move to L2; `TMPDIR` moves from L2 to L1.

### D3. Swap policy

tmpfs pages are swappable; zram swap is compressed RAM and does not add
capacity under real pressure. The expectation: a disk-backed swap device of
at least `sum(L0 caps of running forges)` (floor 8 GiB) is active. The
existing `tillandsias --swap on` (`swap_cmd`) is the remedy. When absent, the
tray shows a persistent warning status line and icon state (not a log line),
naming the one-line remedy; forge launch is not blocked.

### D4. Worktree eviction rule

Before creating any worktree (host or forge): read free space of the target
filesystem and list existing worktrees. If free space < max(2 GiB, 15 %) (L0:
< 25 % of the tmpfs), evict worktrees that are (a) clean, (b) whose HEAD is an
ancestor of a remote ref (`git branch -r --contains`), oldest first, until
above threshold. A worktree with unpushed commits or dirty files is never
evicted; if eviction cannot reach the threshold, refuse with a named verdict
`refused:disk-low:<path>:<free>`. One shared implementation (tillandsias
binary subcommand, not new shell — shell-to-lua/binary carried obligation).

### D5. Disk-aware skills and startup context

Must run the D4 preflight: `advance-work-from-plan`, `meta-orchestration`,
`coordinate-multihost-work` (worktrees for relays), `haiku-delegate`,
`openspec-apply-change`, `build-install-and-smoke-test-e2e`,
`smoke-curl-install-and-test-e2e`, `build-macos-tray`, `build-windows-tray`,
`forge-continuous-enhancement`, `diagnose-forge`, `deslop-sweep`,
`merge-to-main-and-release`, `join-the-fleet`, `initialize-bare-metal-host`.
Startup-context lines: L0 source tmpfs size/used/threshold (1866-ubtc), L1 and
L2 free space, swap state (disk/zram/none), count of evictable worktrees,
host disk free %.

## Risks / Trade-offs

- Moving the podman graphroot strands existing images → rebuild (reset is the
  baseline); first launch after upgrade is slow.
- vault data moves path; per ruling the vault is wiped and rebuilt, not migrated.
- An L1 volume per forge costs a podman volume create per launch (cheap).

## Open Questions

See tasks.md section 9.
