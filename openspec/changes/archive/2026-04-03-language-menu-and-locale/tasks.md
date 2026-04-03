## 1. Config and Core Types

- [x] 1.1 Add `language: String` field to GlobalConfig in config.rs (default from detect_locale or "en")
- [x] 1.2 Add `save_selected_language()` function in config.rs
- [x] 1.3 Add `ContextKey::Language` variant to container_profile.rs
- [x] 1.4 Add LANG and LANGUAGE env vars to common_forge_env() and terminal_profile() in container_profile.rs
- [x] 1.5 Add language_to_lang_value() helper that maps code to full LANG (e.g., "ja" -> "ja_JP.UTF-8")

## 2. Locale Files

- [x] 2.1 Create stub TOML files for all new languages (ja, zh-Hant, zh-Hans, ar, ko, hi, ta, te, fr, pt, it, ro, ru, nah) — each with just [app] name = "Tillandsias"
- [x] 2.2 Update i18n.rs: add all locale includes, expand SUPPORTED_LOCALES, update STRINGS init to load selected language
- [x] 2.3 Create stub shell locale files for container-side (images/default/locales/) for each new language
- [x] 2.4 Update embedded.rs to include new shell locale files

## 3. Menu and Event Loop

- [x] 3.1 Add `build_language_submenu()` to menu.rs with all 16 languages in native script
- [x] 3.2 Add Language submenu to Settings (after Seedlings, before Version)
- [x] 3.3 Add `select_lang` ID helpers to menu::ids module
- [x] 3.4 Add `MenuCommand::SelectLanguage` variant and handle in event_loop.rs
- [x] 3.5 Update en.toml and es.toml with new key `menu.language` = "Language"/"Idioma"

## 4. Launch Integration

- [x] 4.1 Resolve ContextKey::Language in launch.rs build_podman_args to the full LANG value
- [x] 4.2 Update LaunchContext to carry selected_language field
- [x] 4.3 Update handlers.rs build_launch_context to read language from global config

## 5. Tests

- [x] 5.1 Update test forge_profiles_have_four_env_vars to expect 6 (LANG, LANGUAGE added)
- [x] 5.2 Update test terminal_has_three_env_vars to expect 5
- [x] 5.3 Update test every_en_key_exists_in_es to also check new keys
