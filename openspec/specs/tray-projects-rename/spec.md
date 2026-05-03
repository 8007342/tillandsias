<!-- @trace spec:tray-projects-rename -->
# tray-projects-rename Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-27-tray-projects-rename/
annotation-count: 5

## Purpose

Improve project submenu labels with explicit source cues and temporarily disable the broken i18n menu until translation infrastructure is repaired. Rename generic "Projects" and "Remote Projects" labels to emoji-prefixed, filesystem-aware labels that tell users at a glance where each list comes from.

## Requirements

### Requirement: Project List Label Updates

The tray SHALL update the top-level project submenu labels to include source cues:

- **Local projects submenu**: `🏠 ~/src` (instead of `Projects`)
  - Locale key: `menu.projects` = `"🏠 ~/src"`
  - Reflects the actual filesystem watch path where projects live
  
- **Remote projects submenu**: `☁️ Cloud` (instead of `Remote Projects`)
  - Locale key: `menu.cloud_projects` = `"☁️ Cloud"`
  - Clarifies that these are GitHub-hosted repos not yet cloned locally

Both labels SHALL appear in all three locale files (en.toml, de.toml, es.toml) with semantically equivalent translations (the emoji prefixes remain constant across locales).

#### Scenario: User sees the project menu
- **WHEN** user clicks on the Projects submenu (Authed state)
- **THEN** they see two top-level entries: `🏠 ~/src` and optionally `☁️ Cloud`
- **AND** they immediately understand the source of each project group without reading documentation

### Requirement: Language Submenu Removal

The `Language ▸` submenu item SHALL be hidden from the tray menu. The i18n framework (locale loading, `i18n::t` / `i18n::tf`, lazy reload on locale change) is kept intact, but runtime behavior changes:

1. `tray_menu.rs::apply_state` SHALL NOT append the language submenu item (even though the `language: Submenu<R>` field is kept in the struct for future re-enablement)
2. `i18n::initialize` SHALL hard-code locale to `"en"` regardless of `$LANG`, `$LC_ALL`, or config overrides
3. `MenuCommand::SelectLanguage` variant remains in the enum but is unreachable (the menu item that triggers it no longer exists)
4. A single `if cfg!(feature = "i18n-menu") { menu.append(&self.language) }` statement guards the submenu append, allowing re-enablement with one line of change when i18n is fixed

#### Scenario: Localization pipeline is temporarily broken
- **WHEN** tray starts
- **THEN** locale is forced to English (`"en"`)
- **AND** the Language submenu is not visible in the menu
- **AND** code that calls `i18n::t()` continues to work (fallback to English)
- **AND** re-enabling the submenu later requires only uncommenting one line

### Requirement: Code Hygiene — Dormant Infrastructure

The i18n infrastructure is preserved:

- `build_language_submenu()` method is kept
- `language: Submenu<R>` field remains in the struct
- All locale files (en.toml, de.toml, es.toml, +17 others) remain in the codebase
- Calls to `i18n::t()` and `i18n::tf()` are NOT removed
- The language submenu append is guarded by `if cfg!(feature = "i18n-menu")` so it can be toggled at compile time

This ensures the return path to full i18n support is simple and low-risk.

#### Scenario: Team decides to fix i18n in a future change
- **WHEN** translation coverage is complete
- **THEN** one line of code change re-enables the submenu
- **AND** `i18n::initialize` is updated to respect OS locale preferences
- **AND** no orphaned code needs to be cleaned up

### Requirement: Tombstone Annotation

The original locale-detection logic (the block that reads `$LANG` / `$LC_ALL` in `i18n::initialize`) SHALL be kept as a comment with a `@tombstone superseded:tray-projects-rename` annotation:

```rust
// @tombstone superseded:tray-projects-rename
// Original locale detection from OS env — disabled in 0.1.169.227 when i18n pipeline broke.
// Safe to delete after 0.1.169.230 (three releases).
// To restore: uncomment and update i18n::initialize to use this detection again.
//
// let locale = env::var("LANG").ok().and_then(parse_locale_code).unwrap_or("en");
```

This preserves the original code path for three releases in case the team needs to restore it urgently.

### Requirement: Documentation Update

The cheatsheet `docs/cheatsheets/tray-state-machine.md` SHALL be updated to reflect:

- New static-row composition (no Language menu item)
- New project submenu labels and their meanings

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — confirms the `~/src` watch path cited in the new label
