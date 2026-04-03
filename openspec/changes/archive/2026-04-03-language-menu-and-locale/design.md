## Context
The i18n system already supports English and Spanish with TOML locale files embedded at compile time. Locale detection reads OS env vars. The menu system uses Tauri's SubmenuBuilder.

## Goals / Non-Goals
**Goals:** 16-language selection menu, persistent preference, LANG propagation to containers
**Non-Goals:** Full translations for all languages (stubs fall back to English), RTL layout support

## Decisions

### Language codes and native names
| Code | Native Name | LANG value |
|------|-------------|------------|
| en | English | en_US.UTF-8 |
| es | Español | es_MX.UTF-8 |
| ja | 日本語 | ja_JP.UTF-8 |
| zh-Hant | 繁體中文 | zh_TW.UTF-8 |
| zh-Hans | 简体中文 | zh_CN.UTF-8 |
| ar | العربية | ar_SA.UTF-8 |
| ko | 한국어 | ko_KR.UTF-8 |
| hi | हिन्दी | hi_IN.UTF-8 |
| ta | தமிழ் | ta_IN.UTF-8 |
| te | తెలుగు | te_IN.UTF-8 |
| fr | Français | fr_FR.UTF-8 |
| pt | Português | pt_BR.UTF-8 |
| it | Italiano | it_IT.UTF-8 |
| ro | Română | ro_RO.UTF-8 |
| ru | Русский | ru_RU.UTF-8 |
| nah | Nāhuatl | nah_MX.UTF-8 |

### Config persistence
Add `language` field to GlobalConfig:
```toml
[i18n]
language = "en"
```

New function `save_selected_language(lang: &str)` similar to existing `save_selected_agent()`.

### Menu construction
New `build_language_submenu()` function in menu.rs. Pin emoji on selected language. Menu ID format: `select-lang:{code}` (e.g., `select-lang:ja`).

### Container LANG propagation
Add two new env vars to ALL container profiles (forge, terminal):
- `LANG` — from ContextKey::Language (resolved to full locale like `ja_JP.UTF-8`)
- `LANGUAGE` — same code (for GNU gettext chain)

Add `ContextKey::Language` to container_profile.rs.

### TOML locale stubs
For new languages, create minimal TOML files that ONLY override `app.name`. All other keys fall back to English via the existing fallback chain. This means the UI works in all 16 languages immediately (in English), and translations can be added incrementally.
