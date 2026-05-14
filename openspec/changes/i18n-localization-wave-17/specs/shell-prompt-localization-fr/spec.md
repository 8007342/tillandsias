## ADDED Requirements

### Requirement: French locale bundle for Tillandsias Forge

The forge SHALL provide a complete French locale bundle (`/etc/tillandsias/locales/fr.sh`) with translations of all 98 user-facing strings (installation messages, warnings, banners, tips) used by entrypoint.sh and forge-welcome.sh.

#### Scenario: French locale is sourced automatically
- **WHEN** a user's system has `LC_MESSAGES=fr_FR` or `LANG=fr_FR.UTF-8`
- **THEN** forge-welcome.sh detects locale code `fr` and sources `/etc/tillandsias/locales/fr.sh`
- **AND** all prompts, warnings, tips display in French (not English)

#### Scenario: French bundle provides all required variables
- **WHEN** forge-welcome.sh or entrypoint-*.sh sources fr.sh
- **THEN** all L_* variables are defined (same 98 vars as en.sh)
- **AND** each variable contains French text, not English defaults

#### Scenario: Fallback to English if French missing
- **WHEN** user locale is `fr_FR` but `/etc/tillandsias/locales/fr.sh` is missing or invalid
- **THEN** system loads `/etc/tillandsias/locales/en.sh` as fallback
- **AND** user receives English prompts (degraded but functional)

#### Scenario: Installation messages in French
- **WHEN** entrypoint-forge-claude.sh installs OpenCode/Claude Code with French locale
- **THEN** all messages use L_INSTALLING_OPENCODE, L_INSTALLED_CLAUDE, L_WARN_* variables
- **AND** user sees French installation progress

#### Scenario: Welcome banner and tips in French
- **WHEN** forge-welcome.sh renders with French locale
- **THEN** title, section headers, descriptions, and rotating tips all display in French
- **AND** emoji glyphs and formatting match English version exactly

## Sources of Truth

- `cheatsheets/runtime/forge-localization.md` — locale detection, sourcing pattern, variable naming conventions
- `images/default/locales/es.sh` — existing Spanish translation as quality reference
- `images/default/locales/de.sh` — existing German translation as quality reference
