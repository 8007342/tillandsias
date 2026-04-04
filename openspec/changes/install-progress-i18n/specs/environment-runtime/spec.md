## MODIFIED Requirements

### Requirement: Entrypoint i18n coverage
All user-facing strings in container entrypoint scripts SHALL use `L_*` locale variables loaded from `/etc/tillandsias/locales/<lang>.sh`. Hardcoded English strings in entrypoints are not permitted.

#### Scenario: Spanish locale active
- **WHEN** the container locale is set to `es`
- **THEN** all install messages, error messages, and status lines display in Spanish

#### Scenario: Missing locale falls back to English
- **WHEN** the container locale is set to an unsupported language
- **THEN** the English locale file is loaded as fallback
- **THEN** all messages display in English

### Requirement: All locale files deployed in container image
The Containerfile SHALL copy all available locale files from the `locales/` directory into `/etc/tillandsias/locales/`, not just a hardcoded subset.

#### Scenario: German locale available in container
- **WHEN** `de.sh` exists in the image source `locales/` directory
- **THEN** it SHALL be available at `/etc/tillandsias/locales/de.sh` in the built container

#### Scenario: New locale added to source
- **WHEN** a new locale file (e.g., `fr.sh`) is added to the source `locales/` directory
- **THEN** it SHALL be automatically included in the next container image build without Containerfile changes
