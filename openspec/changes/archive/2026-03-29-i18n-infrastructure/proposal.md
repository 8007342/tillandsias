## Why

Tillandsias serves Average Joe (AJ), who may not speak English. The project is authored by a bilingual developer (English/Spanish) and targets a global audience. Currently, every user-facing string is hardcoded in English across Rust source files and shell scripts. There is no mechanism to localize the application.

Adding i18n infrastructure now -- while the string count is manageable (~150 unique user-facing strings) -- is far cheaper than retrofitting later when strings are scattered across dozens of modules. The `fix-ux-string-bugs` change (prerequisite) centralizes error message constants, creating a natural starting point for extraction.

## What Changes

- **String table system** for Rust code -- all user-facing strings extracted into a central TOML file per locale
- **Locale detection** from OS environment (`$LANG`, `$LC_ALL`, `$LANGUAGE`, macOS `defaults read`)
- **English (`en`)** as the default/fallback locale
- **Spanish (`es`)** as proof-of-concept second language
- **Shell script localization** via sourced variable files (`.sh` locale bundles)
- **Template system** for dynamic values (`{project_name}`, `{version}`, etc.)

## Capabilities

### New Capabilities
- `i18n`: Locale detection, string lookup by key, fallback to English, TOML-based string tables for Rust, sourced variable files for shell scripts

### Modified Capabilities
- `tray-app`: Menu labels, build chips, notifications drawn from locale-aware string table
- `cli-mode`: CLI output messages drawn from locale-aware string table
- `environment-runtime`: Entrypoint and welcome messages drawn from locale bundle

## Impact

- **New files**: `locales/en.toml`, `locales/es.toml`, `src-tauri/src/i18n.rs`, `images/default/locales/en.sh`, `images/default/locales/es.sh`
- **Modified files**: All files currently containing hardcoded user-facing strings (see `fix-ux-string-bugs` audit)
- **New dependency**: Potentially none (TOML parsing is already available via `toml` crate used for config). If using `fluent-rs`: `fluent`, `fluent-bundle` crates.
- **Risk**: Medium -- touches many files, but changes are mechanical (key lookup replaces literal string)
