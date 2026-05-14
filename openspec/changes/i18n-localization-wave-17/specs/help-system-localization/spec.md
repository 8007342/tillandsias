## ADDED Requirements

### Requirement: Localized help system with --help flag

The forge SHALL provide a help command wired to the `TILLANDSIAS_LOCALE` environment variable, supporting Spanish, French, German, and Japanese variants alongside English. The help system SHALL be accessible via `--help` flag in terminal entrypoint.

#### Scenario: Help command detects user locale
- **WHEN** user runs `tillandsias-help` or `--help` in terminal mode
- **THEN** system checks TILLANDSIAS_LOCALE environment variable (or falls back to LC_MESSAGES/LANG)
- **AND** loads the appropriate help script: help-{es,fr,de,ja}.sh (or help.sh for English)

#### Scenario: English help displays baseline documentation
- **WHEN** user runs `tillandsias-help` with English locale (or no locale set)
- **THEN** help.sh displays common forge commands, tips, and troubleshooting in English
- **AND** includes usage examples for OpenCode, Claude Code, and git operations

#### Scenario: Spanish help is localized
- **WHEN** TILLANDSIAS_LOCALE=es or LC_MESSAGES=es_ES
- **THEN** system sources help-es.sh and displays help in Spanish
- **AND** all text, examples, and section headers are in Spanish

#### Scenario: French help is localized
- **WHEN** TILLANDSIAS_LOCALE=fr or LC_MESSAGES=fr_FR
- **THEN** system sources help-fr.sh and displays help in French
- **AND** all text, examples, and section headers are in French

#### Scenario: German help is localized
- **WHEN** TILLANDSIAS_LOCALE=de or LC_MESSAGES=de_DE
- **THEN** system sources help-de.sh and displays help in German
- **AND** all text, examples, and section headers are in German

#### Scenario: Japanese help is localized
- **WHEN** TILLANDSIAS_LOCALE=ja or LC_MESSAGES=ja_JP
- **THEN** system sources help-ja.sh and displays help in Japanese
- **AND** all text, examples, and section headers are in Japanese

#### Scenario: Help is accessible from within forge
- **WHEN** user types `help` or `tillandsias-help` inside terminal entrypoint
- **THEN** system executes the localized help script
- **AND** output is piped to less for easy reading (if interactive terminal)

## Sources of Truth

- `cheatsheets/runtime/forge-localization.md` — locale environment variable detection and fallback pattern
- `images/default/locales/en.sh` — template for locale variable structure
