## Why

The `cheatsheets-license-tiered` design introduces a `pull-on-demand` cache at `~/.cache/tillandsias/cheatsheets-pulled/<project>/` with a tiered RAMDISK budget (64 MB modest / 128 MB normal / 1024 MB plentiful) that auto-spills to disk past the cap. This pattern is neither pure HOT (kernel tmpfs with hard ENOSPC) nor pure COLD (disk-only) — it is a third pattern: a tmpfs-accelerated overlay on COLD storage with LRU eviction across the boundary. The existing `forge-hot-cold-split` spec asserts "Only these four path roots are HOT. 'Maybe a hot path' is a HARD NO." Without an explicit admission of the third pattern, the new pull cache reads as a violation of the HOT-roots invariant. This change adds the third pattern to the spec without weakening the four-HOT-roots rule.

## What Changes

- **Add a new requirement** to `forge-hot-cold-split`: the **tmpfs-overlay lane** — a per-project ephemeral cache where reads/writes target a tmpfs view up to a soft cap, beyond which content auto-spills to the underlying COLD per-project cache directory. LRU eviction operates across the tmpfs/disk boundary as a single per-project pool.
- **Constrain the tmpfs-overlay lane** to per-project ephemeral paths only (governed by `forge-cache-dual` per-project isolation). It is NOT a fifth HOT root; the four HOT roots remain hard-capped tmpfs with ENOSPC semantics.
- **Document the tier auto-detection** (`MemTotal < 8 GiB` → 64 MB, `8–32 GiB` → 128 MB, `≥ 32 GiB` → 1024 MB) and the override knob `forge.pull_cache_ram_mb` in `~/.config/tillandsias/config.toml`.
- **Codify the spillover guarantee:** a write that exceeds the tmpfs cap SHALL succeed by demoting LRU content to disk in the same per-project subtree. No ENOSPC for the agent. Per-project isolation is preserved across the boundary (`forge-cache-dual` invariant — project A's eviction NEVER touches project B's bytes).

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `forge-hot-cold-split`: ADD a `tmpfs-overlay lane` requirement that explicitly admits the new pattern alongside the existing HOT/COLD dichotomy. The existing four-HOT-roots rule remains unchanged.

## Impact

- **Spec only.** No code change in this change — the actual cache implementation lands when `cheatsheets-license-tiered` is applied. This change is purely a definitional cleanup so the apply phase has unambiguous spec coverage.
- **Cross-references:** depends on `forge-cache-dual` (per-project isolation) and is consumed by `cheatsheets-license-tiered` (the pull cache itself).
- **Risk:** if the apply phase of `cheatsheets-license-tiered` reveals that the tmpfs-overlay pattern should also apply to other paths (e.g., generated cheatsheets in `/opt/cheatsheets/`), this requirement is the natural extension point.
