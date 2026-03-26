## 1. Enum expansion

- [ ] 1.1 Add 16 new variants to `TillandsiaGenus` enum: Cyanea, Funckiana, Magnusiana, Bergeri, Brachycaulos, Harrisii, Duratii, Gardneri, Seleriana, Fasciculata, Leiboldiana, Flabellata, Paleacea, Recurvata, Kolbii, Pruinosa
- [ ] 1.2 Add all 16 to the `ALL` const array
- [ ] 1.3 Add slug mappings for each new variant in `slug()` and `from_slug()`
- [ ] 1.4 Add display names in `display_name()`
- [ ] 1.5 Add unique flower emojis in `flower()` (no conflicts with lifecycle emojis)

## 2. Icon fallback

- [ ] 2.1 Update `icons` module in `genus.rs` — new genera without SVG assets fall back to Ionantha icons
- [ ] 2.2 Update `build.rs` GENERA list and `genus_to_variant()` to include new genera, with fallback to ionantha SVGs when genus directory does not exist
- [ ] 2.3 Update generated `icon_png` and `window_icon_png` functions to handle all 24 genera

## 3. Test updates

- [ ] 3.1 Update `allocator_pool_exhaustion` test from 8 to 24
- [ ] 3.2 Verify `flower_unique_per_genus` still passes with 24 entries
- [ ] 3.3 Verify `slug_roundtrip` passes for all 24 genera

## 4. Verification

- [ ] 4.1 `cargo check --workspace` passes
- [ ] 4.2 `cargo test --workspace` passes
