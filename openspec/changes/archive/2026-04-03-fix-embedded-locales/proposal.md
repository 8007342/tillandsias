## Why

The i18n infrastructure commit added `images/default/locales/` (en.sh, es.sh) and updated `flake.nix` to reference them, but `embedded.rs` was never updated to embed and extract those locale files. When the installed binary runs `build-image.sh`, the extracted temp dir is missing `images/default/locales/`, causing `nix build` to fail with: `error: path '...-source/images/default/locales' does not exist`. This blocks all users who install via curl from building the forge image.

## What Changes

- Add `include_str!` constants for `images/default/locales/en.sh` and `images/default/locales/es.sh` to `embedded.rs`
- Extract locale files to `images/default/locales/` in `write_image_sources()`
- Update the doc comment's directory tree to reflect the locales directory

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `embedded-scripts`: Image source extraction must include locale files so nix build succeeds

## Impact

- `src-tauri/src/embedded.rs` — add constants and extraction logic
- Cross-platform: changes use only `std::fs` operations already present; no platform-specific concerns (unix permissions not needed for locale data files)
