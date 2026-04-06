## Why
Users should be able to select their UI language from the tray menu. The selected language should propagate to containers so the forge environment matches the host app's language.

## What Changes
- Add Settings > Language submenu with 16 languages, each shown in native script
- Persist language selection in GlobalConfig (new `language` field)
- Default to host detected locale, fall back to English
- Add LANG and LANGUAGE env vars to all container profiles
- Add locale TOML stubs for all 16 languages (content can be translated later, falls back to English)
- Container locale is volatile — always matches app state at launch time, not persisted in container

## Capabilities
### New Capabilities
_None_
### Modified Capabilities
- `environment-runtime`: Containers receive LANG/LANGUAGE env vars from selected locale
- `tray-app`: Language submenu added to Settings

## Impact
- crates/tillandsias-core/src/config.rs — new language field in GlobalConfig, save/load
- crates/tillandsias-core/src/container_profile.rs — new ContextKey::Language, LANG/LANGUAGE env vars
- src-tauri/src/menu.rs — Language submenu builder
- src-tauri/src/event_loop.rs — handle MenuCommand::SelectLanguage
- src-tauri/src/i18n.rs — expand SUPPORTED_LOCALES, add all locale TOML includes
- src-tauri/src/launch.rs — resolve Language context key
- locales/*.toml — new stub files for all 16 languages
- images/default/embedded.rs — include new locale files for container-side locales
- images/default/locales/*.sh — new shell locale stub files
