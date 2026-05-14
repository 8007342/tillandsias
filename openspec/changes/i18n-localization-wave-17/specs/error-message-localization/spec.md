## ADDED Requirements

### Requirement: Localized error message templates

The forge SHALL provide a shared error message library (`lib-localized-errors.sh`) with template functions for common error scenarios (container failure, image missing, network error, git clone failure, authentication failure) available in Spanish, French, German, and Japanese. Entrypoints SHALL source this library and call error functions instead of hardcoding echo statements.

#### Scenario: Error library sources locale-aware templates
- **WHEN** entrypoint-*.sh sources lib-localized-errors.sh
- **THEN** all error functions (error_container_failed, error_image_missing, error_network, error_git_clone, error_auth) are defined
- **AND** error functions detect locale via L_* variables already loaded by locale bundle

#### Scenario: Container failure error displays in user's language
- **WHEN** entrypoint-forge-claude.sh encounters container failure
- **THEN** calls `error_container_failed "error details"`
- **AND** error displays in locale-aware language (Spanish, French, German, Japanese, or English)
- **AND** includes actionable hint for recovery (e.g., "Try restarting the container")

#### Scenario: Image missing error displays in user's language
- **WHEN** entrypoint-forge-*.sh detects missing container image
- **THEN** calls `error_image_missing "tillandsias-forge:v1.2.3"`
- **AND** error displays in locale-aware language
- **AND** includes hint about rebuilding image or checking disk space

#### Scenario: Network error displays in user's language
- **WHEN** git clone or proxy fails due to network
- **THEN** calls `error_network "git clone"`
- **AND** error displays in locale-aware language
- **AND** includes hint to check TILLANDSIAS_PROXY or git service status

#### Scenario: Git clone failure displays in user's language
- **WHEN** git clone fails (auth, SSH key, or network)
- **THEN** calls `error_git_clone "project-name" "error reason"`
- **AND** error displays in locale-aware language
- **AND** includes next-step hint (check credentials, restart git service, etc.)

#### Scenario: Authentication failure displays in user's language
- **WHEN** gh auth or git push auth fails
- **THEN** calls `error_auth "operation" "gh|git"`
- **AND** error displays in locale-aware language
- **AND** includes hint to re-setup credentials via `gh auth login`

#### Scenario: Error messages are centered, consistent format across languages
- **WHEN** any error function is called
- **THEN** error message is wrapped in consistent format: box, header, body, footer
- **AND** format remains identical across Spanish, French, German, Japanese, English
- **AND** no hardcoded English text appears in error output

## Sources of Truth

- `cheatsheets/runtime/forge-localization.md` — locale variable structure and detection pattern
- `images/default/locales/en.sh` — locale variable naming convention (L_*)
- `images/default/entrypoint-terminal.sh` — existing error handling patterns to migrate
