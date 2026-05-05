<!-- @trace spec:tray-projects-rename -->
# tray-projects-rename Specification

## Status

active
promoted-from: openspec/changes/archive/2026-04-27-tray-projects-rename/
annotation-count: 5

## Purpose

Improve project submenu labels with explicit source cues and temporarily disable the broken i18n menu until translation infrastructure is repaired. Rename generic "Projects" and "Remote Projects" labels to emoji-prefixed, filesystem-aware labels that tell users at a glance where each list comes from.

## Requirements

### Requirement: Project List Label Updates

The tray MUST update the top-level project submenu labels to include source cues: @trace spec:tray-projects-rename

- **Local projects submenu**: `🏠 ~/src` (instead of `Projects`)
  - Locale key: `menu.projects` = `"🏠 ~/src"`
  - MUST reflect the actual filesystem watch path where projects live
  
- **Remote projects submenu**: `☁️ Cloud` (instead of `Remote Projects`)
  - Locale key: `menu.cloud_projects` = `"☁️ Cloud"`
  - MUST clarify that these are GitHub-hosted repos not yet cloned locally

Both labels MUST appear in all three locale files (en.toml, de.toml, es.toml) with semantically equivalent translations (the emoji prefixes MUST remain constant across locales).

#### Scenario: User sees the project menu
- **WHEN** user clicks on the Projects submenu (Authed state)
- **THEN** they MUST see two top-level entries: `🏠 ~/src` and optionally `☁️ Cloud`
- **AND** they SHOULD immediately understand the source of each project group without reading documentation

### Requirement: Language Submenu Removal

The `Language ▸` submenu item MUST be hidden from the tray menu. The i18n framework (locale loading, `i18n::t` / `i18n::tf`, lazy reload on locale change) MUST be kept intact, but runtime behavior changes:

1. `tray_menu.rs::apply_state` MUST NOT append the language submenu item (even though the `language: Submenu<R>` field is kept in the struct for future re-enablement)
2. `i18n::initialize` MUST hard-code locale to `"en"` regardless of `$LANG`, `$LC_ALL`, or config overrides
3. `MenuCommand::SelectLanguage` variant MUST remain in the enum but is unreachable (the menu item that triggers it no longer exists)
4. A single `if cfg!(feature = "i18n-menu") { menu.append(&self.language) }` statement MUST guard the submenu append, allowing re-enablement with one line of change when i18n is fixed

#### Scenario: Localization pipeline is temporarily broken
- **WHEN** tray starts
- **THEN** locale MUST be forced to English (`"en"`)
- **AND** the Language submenu MUST NOT be visible in the menu
- **AND** code that calls `i18n::t()` SHOULD continue to work (fallback to English)
- **AND** re-enabling the submenu later SHOULD require only uncommenting one line

### Requirement: Code Hygiene — Dormant Infrastructure

The i18n infrastructure MUST be preserved:

- `build_language_submenu()` method MUST be kept
- `language: Submenu<R>` field MUST remain in the struct
- All locale files (en.toml, de.toml, es.toml, +17 others) MUST remain in the codebase
- Calls to `i18n::t()` and `i18n::tf()` MUST NOT be removed
- The language submenu append MUST be guarded by `if cfg!(feature = "i18n-menu")` so it can be toggled at compile time

This ensures the return path to full i18n support is simple and low-risk.

#### Scenario: Team decides to fix i18n in a future change
- **WHEN** translation coverage is complete
- **THEN** one line of code change SHOULD re-enable the submenu
- **AND** `i18n::initialize` MUST be updated to respect OS locale preferences
- **AND** no orphaned code SHOULD need to be cleaned up

### Requirement: Tombstone Annotation

The original locale-detection logic (the block that reads `$LANG` / `$LC_ALL` in `i18n::initialize`) MUST be kept as a comment with a `@tombstone superseded:tray-projects-rename` annotation:

```rust
// @tombstone superseded:tray-projects-rename
// Original locale detection from OS env — disabled in 0.1.169.227 when i18n pipeline broke.
// Safe to delete after 0.1.169.230 (three releases).
// To restore: uncomment and update i18n::initialize to use this detection again.
//
// let locale = env::var("LANG").ok().and_then(parse_locale_code).unwrap_or("en");
```

This MUST preserve the original code path for three releases in case the team needs to restore it urgently.

### Requirement: Documentation Update

The cheatsheet `cheatsheets/runtime/tray-state-machine.md` MUST be updated to reflect:

- New static-row composition (no Language menu item)
- New project submenu labels and their meanings

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee` — submenu labels, i18n menu hiding, tombstone preservation

Gating points:
- Local projects submenu labeled `🏠 ~/src` (not generic "Projects")
- Remote projects submenu labeled `☁️ Cloud` (not "Remote Projects")
- Language submenu not visible in tray menu (i18n hardcoded to "en")
- MenuCommand::SelectLanguage unreachable (no menu item triggers it)
- Feature flag `i18n-menu` guards submenu append for one-line re-enablement
- Tombstone annotation preserves original locale detection code for three releases

## Sources of Truth

- `cheatsheets/runtime/tray-state-machine.md` — the five-stage menu projection and dynamic region where project submenu labels appear
- `cheatsheets/runtime/forge-container.md` — confirms the `~/.tillandsias/watch` default path and project discovery logic
- `cheatsheets/languages/toml.md` — i18n locale file format (en.toml, de.toml, es.toml) and translation key conventions
