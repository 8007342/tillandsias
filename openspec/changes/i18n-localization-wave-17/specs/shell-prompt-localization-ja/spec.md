## ADDED Requirements

### Requirement: Japanese locale bundle for Tillandsias Forge

The forge SHALL provide a complete Japanese locale bundle (`/etc/tillandsias/locales/ja.sh`) with translations of all 98 user-facing strings (installation messages, warnings, banners, tips) used by entrypoint.sh and forge-welcome.sh.

#### Scenario: Japanese locale is sourced automatically
- **WHEN** a user's system has `LC_MESSAGES=ja_JP` or `LANG=ja_JP.UTF-8`
- **THEN** forge-welcome.sh detects locale code `ja` and sources `/etc/tillandsias/locales/ja.sh`
- **AND** all prompts, warnings, tips display in Japanese (not English)

#### Scenario: Japanese bundle provides all required variables
- **WHEN** forge-welcome.sh or entrypoint-*.sh sources ja.sh
- **THEN** all L_* variables are defined (same 98 vars as en.sh)
- **AND** each variable contains Japanese text, not English defaults

#### Scenario: Fallback to English if Japanese missing
- **WHEN** user locale is `ja_JP` but `/etc/tillandsias/locales/ja.sh` is missing or invalid
- **THEN** system loads `/etc/tillandsias/locales/en.sh` as fallback
- **AND** user receives English prompts (degraded but functional)

#### Scenario: Installation messages in Japanese
- **WHEN** entrypoint-forge-claude.sh installs OpenCode/Claude Code with Japanese locale
- **THEN** all messages use L_INSTALLING_OPENCODE, L_INSTALLED_CLAUDE, L_WARN_* variables
- **AND** user sees Japanese installation progress

#### Scenario: Welcome banner and tips in Japanese
- **WHEN** forge-welcome.sh renders with Japanese locale
- **THEN** title, section headers, descriptions, and rotating tips all display in Japanese
- **AND** emoji glyphs and formatting match English version exactly

## Sources of Truth

- `cheatsheets/runtime/forge-localization.md` — locale detection, sourcing pattern, variable naming conventions
- `images/default/locales/es.sh` — existing Spanish translation as quality reference
- `images/default/locales/de.sh` — existing German translation as quality reference
