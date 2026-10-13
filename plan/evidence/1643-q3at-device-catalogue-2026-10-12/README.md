# 1643-q3at evidence: device catalogue and resolver (lenovinha, 2026-10-12)

`tillandsias devices resolve <query>` turns "iphone 12 pro max", "galaxy s24
ultra", "xperia" or "desktop landscape" into one device with a fixed viewport,
screen, dpr, engine and UA. Red on trunk (`red-on-trunk.txt`): origin/linux-next
has no `devices` command and no `devices` module.

## Exit criteria (`cli-transcript.txt`, and tillandsias-core `devices::tests`, 8 tests)

| criterion | result |
|---|---|
| "iphone 12 pro max" → 428×926, dpr 3, webkit | `apple-iphone-12-pro-max`: viewport and screen 428×926 portrait, dpr 3, engine webkit (`resolve-iphone-12-pro-max.json`) |
| "iphone" → the newest iPhone | `apple-iphone-17` (2025-09), rule newest-flagship. The test computes the newest dated iPhone flagship from the data itself and checks the match. |
| 12 / 12 Pro / 12 Pro Max distinct | `apple-iphone-12` 390×844, `apple-iphone-12-pro` 390×844 (a different model, with DevTools safe areas), `apple-iphone-12-pro-max` 428×926 |
| "xperia", "oneplus" via the overlay | `sony-xperia-1-vi`, `oneplus-13` (newest), both `source.kind = manufacturer-spec`; "oneplus 12" → `oneplus-12` |
| nonsense → no match, never another brand | "blorp 9000" → `{"match":false,…}`, exit 1. "galaxy s24 ultra" → `samsung-galaxy-s24`, approximated, alternatives all `samsung-*`. "9000 ultra" → no match. |

Also covered:
- **Landscape:** "iphone 12 pro landscape" gives 844×390 and the landscape safe area (left 47).
- **Normalisation:** `iphone12`, `Pro+Max`, `s9+`, `samsung`→galaxy, `google`→pixel, `16e`, `s24u`.
- **Provenance:** every device has a source URL and licence.

## Catalogue (127 devices, `catalogue.json`, 97 KB)

Built by `scripts/lua/build-device-catalogue.lua` from inputs vendored under
`crates/tillandsias-core/data/devices/`. It is byte-reproducible:
`--check` says `fresh`, and litmus:device-catalogue-shape seeds a one-byte edit
to show the check goes red.

- **Playwright `deviceDescriptorsSource.json`:** the base, Apache-2.0, pinned at commit 606f017a1, with its LICENSE and NOTICE vendored.
- **Chrome DevTools `EmulatedDevices.ts`:** BSD-3-Clause, pinned at b0d348764, LICENSE vendored. Its TS literal is converted mechanically, and DevTools' own `DEVICE-LIST-ELSE` plain-literal branches are used.
  - It enriches Playwright twins with safe areas and UA client hints.
  - It adds Surface, Nest Hub, Zenbook Fold, Galaxy S20 Ultra, the laptops and more.
- **`overlay.yaml`:** the manufacturer pages for Xperia 1 VI (sony.com.my), OnePlus 12 and 13 (oneplus.com) and Xiaomi 14 (mi.com).
- **`released.yaml`:** launch months and flagship lines. Neither upstream records these, and rule 4 needs them.

### Choices to review
- **Viewport semantics:** for a mobile device, `viewport` is the portrait CSS screen (device-mode emulation). This is what makes iPhone 12 Pro Max 428×926. Playwright's own viewport subtracts the mobile browser UI (428×746) and is kept as `browser_viewport`. For a desktop, viewport is the browser window (Desktop Chrome: 1280×720) and screen is the display (1920×1080).
- **Overlay values are partly derived.** The manufacturer publishes the panel and its resolution, not the CSS viewport or DPR.
  - dpr is the nearest standard Android density bucket: 2.625 for 1080-wide, 3 for 1200-wide, 3.5 for 1440-wide panels.
  - viewport is resolution ÷ dpr.
  - Every overlay entry carries this `derivation`.
  - The UA is Chrome's real reduced Android UA; no model codes are invented.
- **Galaxy S24 Ultra is NOT in the data.** Samsung's spec page renders its figures client-side, and only third-party figures (including GSMArena, which is excluded) were reachable. So "galaxy s24 ultra" resolves approximated to the Galaxy S24, with S20 Ultra and A55 as alternatives. The Xperia 10 VI was left out for the same reason: no Sony-sourced figure.
- **Sony's spec pages block automated fetches.** The Xperia 1 VI figures (6.5-inch, 1080×2340 FHD+) are as indexed from sony.com.my's own spec page; the entry says so.
- **Undated devices are never picked as "newest".** Release months exist only where a launch month is known. iPhone 17e is undated.
- **`devices list`** prints one `id<TAB>model<TAB>w×h@dpr` line per device (`devices-list.txt`).
