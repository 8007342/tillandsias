## Why

Container entrypoint scripts (forge-claude, forge-opencode, terminal) run npm installs and curl downloads silently. On slow connections they appear hung — the user sees nothing for 30+ seconds. Additionally, all user-facing strings in entrypoints are hardcoded in English despite the i18n locale system existing and being loaded. Users selecting Spanish or German still see English install messages, error messages, and status lines.

## What Changes

- Add terminal progress indicators (spinners) to npm install and curl download operations in entrypoint scripts
- Replace all hardcoded English strings in entrypoint scripts with `L_*` locale variables
- Add new `L_*` keys to en.sh, es.sh, de.sh for progress-related messages
- Fix Containerfile to COPY all locale files (currently only copies en.sh and es.sh)
- Fix hardcoded "Remote Projects" string in menu.rs to use i18n::t()
- Add corresponding key to all TOML locale files (en, es, de)

## Capabilities

### New Capabilities
- `install-progress`: Terminal spinner/progress display during npm install, curl downloads, and other first-run setup operations in container entrypoints

### Modified Capabilities
- `environment-runtime`: Entrypoint scripts must use i18n locale variables for all user-facing strings; Containerfile must deploy all available locale files
- `forge-welcome`: Welcome screen strings already use i18n but new progress strings need integration
- `tray-app`: Fix hardcoded "Remote Projects" menu label to use i18n

## Impact

- `images/default/lib-common.sh` — add spinner helper function, new L_* keys
- `images/default/entrypoint-forge-claude.sh` — spinner wrapping, i18n string replacement
- `images/default/entrypoint-forge-opencode.sh` — spinner wrapping, i18n string replacement
- `images/default/entrypoint-terminal.sh` — i18n string replacement
- `images/default/locales/en.sh` — new progress keys
- `images/default/locales/es.sh` — new progress keys (Spanish)
- `images/default/locales/de.sh` — new progress keys (German)
- `images/default/Containerfile` — COPY all locales, not just en+es
- `src-tauri/src/menu.rs` — replace hardcoded "Remote Projects"
- `locales/en.toml`, `locales/es.toml`, `locales/de.toml` — add menu.github.remote_projects key
