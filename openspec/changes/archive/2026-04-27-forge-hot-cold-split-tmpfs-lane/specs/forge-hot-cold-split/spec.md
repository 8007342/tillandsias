# forge-hot-cold-split — tmpfs-overlay lane delta

@trace spec:forge-hot-cold-split, spec:cheatsheets-license-tiered, spec:forge-cache-dual

## ADDED Requirements

### Requirement: Tmpfs-overlay lane for per-project ephemeral cache

A third storage pattern SHALL be admitted alongside HOT (kernel tmpfs with hard cap, ENOSPC on overflow) and COLD (disk, no spec-level cap): the **tmpfs-overlay lane**. The tmpfs-overlay lane is a tmpfs view rooted on top of a COLD per-project cache directory, with LRU eviction across the tmpfs/disk boundary as a single per-project pool. The tmpfs-overlay lane is NOT a fifth HOT root; the four HOT roots (`/opt/cheatsheets`, `/home/forge/src`, `/tmp`, `/run/user/1000`) remain unchanged. The tmpfs-overlay lane is scoped to `~/.cache/tillandsias/cheatsheets-pulled/` only; other paths require a dedicated spec change to opt in.

The tmpfs-overlay lane SHALL be sized at tray startup based on host `MemTotal`:

| `MemTotal` (from `/proc/meminfo`) | Tmpfs cap | User override |
|---|---|---|
| `< 8 GiB` | 64 MB | `forge.pull_cache_ram_mb` in `~/.config/tillandsias/config.toml` |
| `8 GiB ≤ MemTotal < 32 GiB` | 128 MB | same |
| `≥ 32 GiB` | 1024 MB | same |

The resolved cap SHALL be passed into the forge container via the env var `TILLANDSIAS_PULL_CACHE_RAM_MB` so the in-forge cache implementation knows the budget without re-reading `/proc/meminfo`.

#### Scenario: Tmpfs-overlay cap auto-detected at tray startup

- **WHEN** the tray starts on a host with `MemTotal = 16 GiB`
- **THEN** the resolved tmpfs cap SHALL be 128 MB
- **AND** every forge container launched after this point SHALL receive `TILLANDSIAS_PULL_CACHE_RAM_MB=128` in its environment
- **AND** if the user's config sets `forge.pull_cache_ram_mb = 256`, the override SHALL win and the env var SHALL be `256`

#### Scenario: Tmpfs-overlay write succeeds past cap by demoting LRU to disk

- **WHEN** the in-forge agent writes content to `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>` that would exceed the tmpfs cap
- **THEN** the cache implementation SHALL demote the least-recently-accessed file in the SAME PROJECT's subtree from tmpfs to the disk-backed portion of the same per-project pull cache
- **AND** the new write SHALL succeed without ENOSPC
- **AND** the demoted file SHALL remain readable from the same path (tmpfs/disk transition is transparent to readers)

#### Scenario: Tmpfs-overlay eviction NEVER crosses project boundaries

- **WHEN** project A's tmpfs-overlay portion is full and project A is writing
- **THEN** eviction SHALL only consider files in project A's subtree
- **AND** project B's bytes SHALL NOT be evicted, demoted, or even read
- **AND** this invariant SHALL hold even if project B's tmpfs portion is empty (idle space is not borrowable across projects per `forge-cache-dual`)

#### Scenario: Tmpfs-overlay is NOT a HOT root

- **WHEN** the spec test that enumerates HOT roots runs (the existing scenario from `Requirement: HOT tier — RAM-backed tmpfs for finely curated paths`)
- **THEN** the four HOT root paths SHALL be exactly `/opt/cheatsheets`, `/home/forge/src`, `/tmp`, `/run/user/1000`
- **AND** `~/.cache/tillandsias/cheatsheets-pulled/` SHALL NOT appear in that enumeration
- **AND** the "Maybe a hot path" HARD NO rule SHALL remain unweakened

## Sources of Truth

- `cheatsheets/runtime/forge-hot-cold-split.md` — HOT/COLD path taxonomy this delta extends with the third pattern.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — per-project ephemeral cache contract that the tmpfs-overlay lane sits inside.
- `openspec/changes/cheatsheets-license-tiered/design.md` Decision 3 — origin of the tiered RAMDISK budget and auto-detection heuristic.
