## Why

Two separate UX issues from local testing of `0.1.169.227`:

1. The labels `Projects ▸` and `Remote Projects ▸` are too generic — they read as "category" labels rather than "where the projects live". Users want immediate visual cues for the source of each list. The user's preferred labels: `🏠 ~/src ▸` for the local watch-path projects (their actual filesystem location) and `☁️ Cloud ▸` for GitHub-hosted repos that aren't yet cloned.

2. The `Language ▸` submenu surfaces 17 locales but the i18n pipeline is broken in practice — most translations don't exist (only `en`, `de`, `es` have entries beyond English; the rest fall back silently and the menu still implies they're complete). Surfacing the menu hands users a footgun. We want to keep the i18n framework (locale loading, `i18n::t` / `i18n::tf`, lazy reload on locale change) so we can re-enable later, but hide the menu and hard-default to `en` for now.

## What Changes

- **BREAKING** Locale: `menu.projects = "Projects"` → `menu.projects = "🏠 ~/src"`. New key `menu.cloud_projects = "☁️ Cloud"` (replaces the existing `menu.github.remote_projects = "Remote Projects"` for the new submenu label — the old key stays around for the spec deltas that still reference `Remote Projects` literally, but the tray uses the new key).
- **BREAKING** Tray: `Projects ▸` and `Remote Projects ▸` rendered with the new emoji-prefixed labels in `tray_menu.rs`.
- **BREAKING** Tray: the `Language ▸` submenu is no longer appended to the menu. The static row collapses to `[separator] [signature] [Quit]`. Locale defaults to `en` regardless of OS settings until i18n is re-enabled.
- The i18n pipeline (`src-tauri/src/i18n.rs`, embedded `.toml` files, `i18n::t` / `i18n::tf`) is **kept** — code that calls these continues to work. Only the runtime locale source changes: `i18n::initialize` always picks `"en"` for now, ignoring `LANG` / `LC_ALL` / config overrides. `MenuCommand::SelectLanguage` stays in the enum but is unreachable because the menu item is gone.
- `build_language_submenu` and the `language: Submenu<R>` field stay in the code but the submenu is not appended to `root` — they become dormant infrastructure. Adding a single `if cfg!(feature = "i18n-menu") { menu.append(&self.language) }` re-enables the submenu when the user is ready to bring i18n back.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `tray-app`: rename the two top-level project submenus and remove the Language ▸ entry from the static row. The five-stage state machine and all other invariants are unchanged.

## Impact

- `locales/en.toml` — add `menu.cloud_projects`, change `menu.projects` value to `"🏠 ~/src"`. Mirror to `de.toml` / `es.toml`.
- `src-tauri/src/tray_menu.rs` — update `apply_state` to use the new label keys; drop `.item(&language)` from the static-row `MenuBuilder`. Keep the `language: Submenu<R>` field (dormant) so re-enabling later is one line of change.
- `src-tauri/src/i18n.rs::initialize` (or wherever the locale is selected) — hard-code `"en"` selection until further notice. Add a `// @tombstone superseded:tray-projects-rename` annotation on the previous detection block so the original logic is preserved through three releases for the i18n re-enablement work.
- `docs/cheatsheets/tray-state-machine.md` — update the "static row" composition and the "what the user can do" column.
- Tests in `tray_menu.rs::tests` — the dispatch tests for `MenuCommand::SelectLanguage` stay (the variant still exists; the menu item is just gone). Add a test asserting `apply_state` does NOT append a Language submenu in any stage.

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — confirms the `~/src` watch path that the new label cites.
- `cheatsheets/agents/openspec.md` — the workflow this change is going through.
