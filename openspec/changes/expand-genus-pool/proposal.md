## Why

The genus pool has only 8 entries. With terminals now receiving their own genus names (separate from forge containers), a single project can easily consume 2+ genera. Users working on 4-5 projects simultaneously will exhaust the pool and hit `None` from the allocator, leaving new environments unnamed.

Expanding to 24 genera provides comfortable headroom: even with 2 environments per project across 10 projects, only 20 of 24 slots are used.

## What Changes

- **Expand `TillandsiaGenus` enum** from 8 to 24 variants, adding 16 real tillandsia species with visually distinct slugs and unique flower emojis
- **Graceful icon fallback** in `build.rs` and `genus.rs` icons module — new genera without dedicated SVG assets fall back to Ionantha icons at compile time
- **Update tests** to reflect the larger pool size (e.g., allocator exhaustion test at 24 instead of 8)

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `genus-pool`: Pool size increases from 8 to 24, reducing collision risk when running multiple environments per project

## Impact

- **New files**: none
- **Modified files**: `crates/tillandsias-core/src/genus.rs` (enum, ALL array, slug/from_slug/display_name/flower methods, icon fallback, tests), `crates/tillandsias-core/build.rs` (GENERA list expanded with SVG fallback for missing assets)
