## Why

The 32 tray icon SVGs (8 genera x 4 lifecycle states) have a 64x64 viewBox but the plant graphics are tiny within it. At typical system tray sizes (22-32px), the plants are barely visible:

- **Pup**: a few dots, plant extends only ~16px from the bottom
- **Bud**: occupies bottom ~40%, wasted space above
- **Bloom**: bottom ~50% with flower petals disappearing at small sizes
- **Dried**: similar underuse of canvas space
- **Stroke-width="1"**: invisible at 22px render size
- **Dark greens on dark trays**: #6aad6a disappears against dark panel backgrounds

Users cannot distinguish lifecycle states at actual tray size. The icons need to fill 70-85% of the canvas with brighter colors and thicker strokes.

## What Changes

- **Recenter all plants** — Shift `translate()` anchors from bottom-edge to vertical center of the 64x64 canvas
- **Scale up** — Apply `scale()` transforms so plants fill 70-85% of the viewBox instead of 15-50%
- **Increase stroke weight** — Bump `stroke-width` from 1 to 1.5-2 for visibility at small render sizes
- **Brighten colors for dark trays** — Greens (#6aad6a to #7ec87e, #7cbc7c to #95d895), slight brightening for dried browns, keep vivid bloom pinks/reds
- **Usneoides special handling** — Already top-anchored; recenter and scale without inverting its hanging form

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-icon-visibility`: All 32 genus/state SVG icons are clearly distinguishable at 22-32px tray size on both dark and light panel backgrounds

## Impact

- **Modified files**: All 32 SVGs in `assets/icons/<genus>/<state>.svg`
- **No code changes**: SVGs are loaded at runtime; no Rust/Tauri code affected
- **No new dependencies**: Pure SVG transform adjustments
