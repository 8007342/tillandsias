## 1. Spinner Helper

- [ ] 1.1 Add `spin` function to `images/default/lib-common.sh` — background spinner on stderr, TTY detection, cleanup trap
- [ ] 1.2 Add spinner cleanup to entrypoint trap handlers (kill spinner PID on EXIT/INT/TERM)

## 2. Entrypoint Progress Integration

- [ ] 2.1 Wrap npm install in `spin` call in `entrypoint-forge-claude.sh` (openspec + claude installs)
- [ ] 2.2 Wrap npm install in `spin` call in `entrypoint-forge-opencode.sh` (openspec install)
- [ ] 2.3 Wrap curl installer in `spin` call in `entrypoint-forge-opencode.sh` (opencode install)
- [ ] 2.4 Wrap npm update checks in `spin` call in both entrypoints

## 3. i18n — New Locale Keys

- [ ] 3.1 Add new `L_*` progress/spinner keys to `images/default/locales/en.sh`
- [ ] 3.2 Add Spanish translations to `images/default/locales/es.sh`
- [ ] 3.3 Add German translations to `images/default/locales/de.sh`

## 4. i18n — Entrypoint String Replacement

- [ ] 4.1 Replace all hardcoded English strings in `entrypoint-forge-claude.sh` with `L_*` variables
- [ ] 4.2 Replace all hardcoded English strings in `entrypoint-forge-opencode.sh` with `L_*` variables
- [ ] 4.3 Replace all hardcoded English strings in `entrypoint-terminal.sh` with `L_*` variables

## 5. Container Image — Deploy All Locales

- [ ] 5.1 Update `images/default/Containerfile` to COPY entire `locales/` directory instead of individual files

## 6. Rust-side i18n Fix

- [ ] 6.1 Add `menu.github.remote_projects` key to `locales/en.toml`, `locales/es.toml`, `locales/de.toml`
- [ ] 6.2 Replace hardcoded "Remote Projects" in `src-tauri/src/menu.rs` with `i18n::t("menu.github.remote_projects")`

## 7. Trace Annotations

- [ ] 7.1 Add `@trace spec:install-progress` to spinner function and entrypoint integration points
- [ ] 7.2 Add `@trace spec:environment-runtime` to i18n string replacement locations
