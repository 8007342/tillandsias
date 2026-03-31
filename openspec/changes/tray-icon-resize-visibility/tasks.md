## 1. Analyze Current Icons

- [x] 1.1 Read all 32 SVGs and catalog transform anchors, bounding boxes, fill colors
- [x] 1.2 Identify the vertical extent each plant uses within the 64x64 canvas
- [x] 1.3 Note special cases (usneoides hangs from top, tectorum is spherical, xerographica has wide curls)

## 2. Recenter and Scale

- [x] 2.1 Adjust `translate()` anchors to vertically center each plant in the 64x64 canvas
- [x] 2.2 Apply `scale()` transforms to fill 70-85% of the canvas
- [x] 2.3 Handle usneoides separately (top-hanging orientation preserved)
- [x] 2.4 Handle tectorum (spherical shape needs even centering)
- [x] 2.5 Handle xerographica (wide curling leaves, avoid clipping)

## 3. Improve Stroke Visibility

- [x] 3.1 Increase stroke-width from 1 to 1.5 on polygon-based genera (ionantha, stricta)
- [x] 3.2 Verify path-based genera already have adequate stroke-width (bulbosa, caput-medusae, xerographica have 2-3)
- [x] 3.3 Increase tectorum trichome line stroke-width from 1 to 1.5

## 4. Brighten Colors for Dark Tray Backgrounds

- [x] 4.1 Greens: #6aad6a -> #7ec87e, #7cbc7c -> #95d895, #5a9a5a -> #6ab86a
- [x] 4.2 Stroke greens: #3a7a3a -> #4a8a4a, #4a8a4a -> #5a9a5a
- [x] 4.3 Dried browns: #a08860 -> #b09968, #b09970 -> #c0aa78, #887044 -> #98804c
- [x] 4.4 Pup light greens: keep as-is (already bright enough)
- [x] 4.5 Bloom pinks/reds/purples: keep vivid (already high contrast)

## 5. Verification

- [x] 5.1 All 32 SVGs modified (8 genera x 4 states)
- [ ] 5.2 `./build.sh --check` passes (build.rs SVG rendering)
- [ ] 5.3 Visual spot-check: ionantha bloom/bud/dried/pup at 32x32 render
