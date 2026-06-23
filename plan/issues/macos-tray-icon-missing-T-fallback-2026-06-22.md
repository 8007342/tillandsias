# macOS tray icon missing — status item shows fallback letter "T" — 2026-06-22

**Filed:** 2026-06-22 (operator observation during curl-install e2e of v0.3.260622.4)
**Kind:** bug (tray UX)  **Status:** ready  **Owner host:** macos
**Trace:** `spec:macos-native-tray`, `spec:macos-tray-build-and-release`

## Symptom

The installed/released macOS tray's menu-bar status item shows a bare letter
**"T"** instead of the Tillandsias glyph. Operator confirmed the menu *items* are
correct (collapsed, GitHub-Login-gated — Linux parity); only the icon is wrong.

## Root cause (candidate)

`status_item.rs`:
- `load_status_icon_image()` (line 185) loads the glyph via
  `NSImage::initByReferencingFile(.../tray-icon.png)` and returns `Option<NSImage>`.
- On `Some(image)` → `button.setImage(image)` + clear title (lines 153-154); on
  `None` → `button.setTitle(status_icon_fallback_title())` which is **"T"**
  (lines 158-159, 218). So the "T" means **the icon failed to load** (`None`).
- Bundle path: `Tillandsias.app/Contents/Resources/tray-icon.png` (packaged) or
  `crates/tillandsias-macos-tray/assets/tray-icon.png` (dev) (lines 193-214).

Two likely causes (verify both):
1. **Invalid asset**: `crates/tillandsias-macos-tray/assets/tray-icon.png` is only
   **151 bytes** (vs `icon.png` 960 bytes) — almost certainly a broken/placeholder
   PNG that `initByReferencingFile` can't decode → `None` → "T". A real menu-bar
   template glyph (e.g. 16–22 pt @1x/@2x) is much larger.
2. **CI release bundling**: the released tray is built by the `macos-release`
   job in `.github/workflows/release.yml` (NOT `scripts/build-macos-tray.sh`).
   Confirm that job copies `tray-icon.png` into `Contents/Resources/` exactly
   where `tray_icon_paths()` looks; if it's absent in the CI bundle, load → "T".

## Fix

- Replace `assets/tray-icon.png` with a valid menu-bar glyph (ideally a
  **template image** so it adapts to light/dark + the system tint), verify it
  decodes (`sips -g pixelWidth assets/tray-icon.png` succeeds, non-trivial size).
- Ensure the CI `macos-release` job bundles it into `Contents/Resources/`.
- Closure: launch the bundle → status item shows the glyph, not "T"; an AX/
  visual smoke (`scripts/macos-tray-ax-smoke.sh icon-present` + a screencapture)
  asserts a non-text status item. Consider failing the build if
  `tray-icon.png` is below a sane byte/pixel threshold.
