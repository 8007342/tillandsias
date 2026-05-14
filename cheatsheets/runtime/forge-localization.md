<!-- @trace spec:shell-prompt-localization-fr, spec:shell-prompt-localization-ja, spec:help-system-localization, spec:error-message-localization -->
# Forge Localization

**Use when**: Understanding how Tillandsias Forge handles multiple language locales, configuring locale detection, or adding new locale translations.

## Provenance

- https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html — POSIX LC_* environment variables (LC_ALL, LC_MESSAGES, LANG)
- https://www.gnu.org/software/bash/ — Bash sourcing and variable expansion
- **Last updated:** 2026-05-14

## Overview

Tillandsias Forge provides locale-aware user experience in Spanish, French, German, and Japanese. Locale detection happens via `LC_ALL`, `LC_MESSAGES`, or `LANG` environment variables, and the forge automatically sources the appropriate locale bundle.

## Locale Detection

**Detection Order** (first match wins):
1. `LC_ALL` — if set, overrides all other locale vars
2. `LC_MESSAGES` — language for messages and UI
3. `LANG` — fallback default locale
4. English (`en`) — hardcoded fallback if no locale env vars set

**Example LC_MESSAGES values**:
- `en_US.UTF-8` → detected as `en`
- `es_ES.UTF-8` → detected as `es`
- `fr_FR.UTF-8` → detected as `fr`
- `de_DE.UTF-8` → detected as `de`
- `ja_JP.UTF-8` → detected as `ja`

**Detection Algorithm** (from forge-welcome.sh):
```bash
_LOCALE_RAW="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
_LOCALE="${_LOCALE_RAW%%_*}"          # Strip _XX suffix (e.g., es_ES → es)
_LOCALE="${_LOCALE%%.*}"              # Strip .UTF-8 suffix (e.g., es.UTF-8 → es)
_LOCALE_FILE="/etc/tillandsias/locales/${_LOCALE}.sh"
[ -f "$_LOCALE_FILE" ] || _LOCALE_FILE="/etc/tillandsias/locales/en.sh"
source "$_LOCALE_FILE"
```

## Locale Bundles

**Location**: `/etc/tillandsias/locales/`

**Files**:
- `en.sh` — English (82 variables)
- `es.sh` — Spanish (82 variables)
- `de.sh` — German (82 variables)
- `fr.sh` — French (82 variables)
- `ja.sh` — Japanese (82 variables)

**Variable Structure**: All `L_*` prefixed bash variables exported for use by entrypoint scripts and welcome banner.

**Coverage** (all locales have 82 variables):
- Entrypoint messages: `L_INSTALLING_OPENCODE`, `L_INSTALLED_CLAUDE`, `L_WARN_*`, etc.
- Welcome banner: `L_WELCOME_TITLE`, `L_WELCOME_PROJECT`, etc.
- Tips (20 rotating): `L_TIP_1` through `L_TIP_20`
- Error messages: `L_ERROR_CONTAINER_FAILED`, `L_ERROR_NETWORK`, etc.

## Adding a New Locale

1. **Create locale file** at `images/default/locales/XX.sh` (replace XX with locale code, e.g., `pt.sh` for Portuguese)
2. **Copy English as template**:
   ```bash
   cp images/default/locales/en.sh images/default/locales/XX.sh
   ```
3. **Translate all L_* variables** in the new file
4. **Validate syntax**:
   ```bash
   bash -n images/default/locales/XX.sh
   ```
5. **Add to Containerfile** (already does glob copy of locales/):
   ```dockerfile
   COPY locales/ /etc/tillandsias/locales/
   ```
6. **Run coverage test** to verify all 82 variables are present:
   ```bash
   bash scripts/test-locale-coverage.sh
   ```

## Help System

**Location**: `/usr/local/share/tillandsias/`

**Files**:
- `help.sh` — English help (commands, tips, troubleshooting)
- `help-es.sh` — Spanish help
- `help-fr.sh` — French help
- `help-de.sh` — German help
- `help-ja.sh` — Japanese help

**Detection**: Sources locale-specific help when `help` command is called (defined in `shell-helpers.sh`):
```bash
help() {
    local locale_raw="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
    local locale="${locale_raw%%_*}"
    local help_script="/usr/local/share/tillandsias/help-${locale}.sh"
    [ -f "$help_script" ] || help_script="/usr/local/share/tillandsias/help.sh"
    bash "$help_script" | ${PAGER:-less -R}
}
```

## Error Messages

**Library**: `lib-localized-errors.sh` (at `/usr/local/lib/tillandsias/`)

**Error Functions**:
- `error_container_failed "details"` — Container startup failure
- `error_image_missing "image:tag"` — Missing container image
- `error_network "operation"` — Network failure (proxy, DNS, connection)
- `error_git_clone "project" "reason"` — Git clone failure
- `error_auth "operation" "service"` — Authentication failure

**Usage Example**:
```bash
source /usr/local/lib/tillandsias/lib-localized-errors.sh
error_git_clone "my-project" "SSH key not configured"
```

**Locale Variables** (automatically detected from loaded locale bundle):
- `L_ERROR_CONTAINER_FAILED` — Error message
- `L_ERROR_CONTAINER_HINT` — Recovery hint
- (one pair per error type)

## Containerfile Integration

Locales are copied to the container image:
```dockerfile
RUN mkdir -p /etc/tillandsias/locales
COPY locales/ /etc/tillandsias/locales/
```

Help scripts are copied:
```dockerfile
COPY ../../scripts/help.sh /usr/local/share/tillandsias/help.sh
COPY ../../scripts/help-es.sh /usr/local/share/tillandsias/help-es.sh
# ... etc for all locales
RUN chmod +x /usr/local/share/tillandsias/help*.sh || true
```

Error library is copied:
```dockerfile
COPY lib-localized-errors.sh /usr/local/lib/tillandsias/lib-localized-errors.sh
```

## Testing

Run automated locale coverage test:
```bash
bash scripts/test-locale-coverage.sh
```

**Tests**:
1. All L_* variables in en.sh are defined in {es,de,fr,ja}.sh
2. Bash syntax valid for all locale files
3. Bash syntax valid for all help-*.sh files

## See Also

- `forge-welcome.sh` — Welcome banner with locale detection
- `lib-localized-errors.sh` — Error message templates
- `shell-helpers.sh` — Help command implementation
- Locale files: `images/default/locales/*.sh`
- Help system: `scripts/help*.sh`
