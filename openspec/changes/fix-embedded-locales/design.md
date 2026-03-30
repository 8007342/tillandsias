## Context

`embedded.rs` embeds all image source files via `include_str!` and extracts them at runtime for nix builds. The i18n commit added `images/default/locales/{en,es}.sh` and referenced them in `flake.nix` (line 23: `forgeLocales = ./images/default/locales`), but missed adding them to `embedded.rs`. Dev builds from the repo work fine (nix sees the real filesystem), but installed binaries fail because the extracted temp tree is incomplete.

## Goals / Non-Goals

**Goals:**
- Forge image builds succeed from the installed binary (all platforms)
- Locale files are embedded and extracted alongside existing image sources

**Non-Goals:**
- Adding new locale files (that's a separate i18n change)
- Changing the nix build or flake.nix

## Decisions

**Follow existing pattern**: Add `include_str!` constants and fs::write calls matching the exact pattern used for shell configs, entrypoints, and other data files. No new abstractions needed — two constants, one mkdir, two writes.

**No executable permissions on locale files**: Unlike entrypoints, locale files are sourced (`. /path/en.sh`), not executed directly. They don't need `chmod 0o755`. This keeps the change minimal and avoids platform-specific `#[cfg(unix)]` blocks for these files.

## Risks / Trade-offs

- [Risk] Future locale files added without updating embedded.rs → same bug recurs. Mitigation: the existing pattern is clear; the embedded-scripts spec will be updated to document locale files.
