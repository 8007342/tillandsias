## Why

Operator direction (2026-10-12): mobile first is first class. An agent asked to
"open it on an iPhone 12 Pro Max", or "check it on a Galaxy", needs that phrase
to become one fixed set of numbers: viewport, screen, devicePixelRatio, engine,
user agent, touch and safe areas. Today nothing in Tillandsias knows what a
device is. The browser plan (containerized `browser.open`, CDP emulation, dev
mode, a WebKit engine) is filed separately and builds on this catalogue
(order 1643-q3at).

## What Changes

- ADDED `device-catalogue`: a vendored, committed device catalogue merged from:
  - Playwright's device descriptors (Apache-2.0);
  - Chrome DevTools' emulated devices (BSD-3-Clause), which add safe areas, UA client hints and laptops;
  - a hand-written manufacturer overlay (Xperia, OnePlus, Xiaomi), one spec-page URL per entry.

  Every device records its source and licence. No GSMArena, WURFL or DeviceAtlas data.
- ADDED `device-catalogue`: a deterministic resolver from free-form queries to
  one device. It applies, in order: normalisation, exact alias, all-tokens
  with fewest extras, the newest base flagship for a bare brand, and an
  approximated near miss that never changes brand. A trailing "landscape"
  swaps the dimensions.
- ADDED `device-catalogue`: `tillandsias devices resolve <query>` and
  `tillandsias devices list`.

## Impact

- New: `crates/tillandsias-core/src/devices.rs` and `crates/tillandsias-core/data/devices/`. The latter holds the vendored upstream files with their licences, `overlay.yaml`, `released.yaml` and the generated `catalogue.json`.
- New: `scripts/lua/build-device-catalogue.lua` (generator, with a `--check` freshness mode).
- `crates/tillandsias-headless/src/main.rs`: the `devices` subcommand, dispatched early.
