## 1. French Locale Bundle (ON-001 French Shell Prompts)

- [x] 1.1 Translate all 98 L_* variables from en.sh to French (es.sh and de.sh as references)
- [x] 1.2 Validate UTF-8 encoding and bash syntax with `bash -n images/default/locales/fr.sh`
- [x] 1.3 Verify all 98 L_* variables are defined (diff against en.sh variable list)
- [ ] 1.4 Test locale auto-detection: set LC_MESSAGES=fr_FR and verify fr.sh sources correctly
- [ ] 1.5 Manual smoke test: launch container with French locale and verify welcome banner, tips, error messages render in French

## 2. Japanese Locale Bundle (ON-001 Japanese Shell Prompts)

- [x] 2.1 Translate all 98 L_* variables from en.sh to Japanese (es.sh and de.sh as references)
- [x] 2.2 Validate UTF-8 encoding and bash syntax with `bash -n images/default/locales/ja.sh`
- [x] 2.3 Verify all 98 L_* variables are defined (diff against en.sh variable list)
- [ ] 2.4 Test locale auto-detection: set LC_MESSAGES=ja_JP and verify ja.sh sources correctly
- [ ] 2.5 Manual smoke test: launch container with Japanese locale and verify welcome banner, tips, error messages render in Japanese

## 3. Help System (ON-002 Help System Localization)

- [x] 3.1 Create `scripts/help.sh` with English help content (forge commands, tips, troubleshooting)
- [x] 3.2 Create `scripts/help-es.sh` with Spanish help (translate from help.sh)
- [x] 3.3 Create `scripts/help-fr.sh` with French help (translate from help.sh)
- [x] 3.4 Create `scripts/help-de.sh` with German help (translate from help.sh)
- [x] 3.5 Create `scripts/help-ja.sh` with Japanese help (translate from help.sh)
- [x] 3.6 Wire help scripts into entrypoint-terminal.sh: detect TILLANDSIAS_LOCALE and source appropriate help-*.sh
- [x] 3.7 Test `--help` flag in terminal entrypoint loads correct locale variant
- [x] 3.8 Verify help is readable via `help` command (piped to less for interactive terminals)

## 4. Error Message Library (ON-003 Error Message Localization)

- [x] 4.1 Create `images/default/lib-localized-errors.sh` with error template functions
- [x] 4.2 Define error functions: error_container_failed(), error_image_missing(), error_network(), error_git_clone(), error_auth()
- [x] 4.3 Each error function detects locale via L_* variables and emits localized message with recovery hint
- [x] 4.4 Add error messages in Spanish, French, German, Japanese to locale bundles (new L_ERROR_* variables)
- [ ] 4.5 Refactor entrypoint-terminal.sh to source lib-localized-errors.sh and call error functions instead of hardcoded echo
- [ ] 4.6 Refactor entrypoint-forge-claude.sh to use error functions for installation/clone failures
- [ ] 4.7 Refactor entrypoint-forge-opencode.sh to use error functions
- [ ] 4.8 Test error messages in all 4 locales: verify each error function outputs correct language

## 5. Integration & Testing

- [x] 5.1 Create automated test: verify all L_* vars in en.sh are defined in {es,de,fr,ja}.sh
- [x] 5.2 Create automated test: bash syntax check for all locale files (`bash -n`)
- [x] 5.3 Verify locale file is properly included in Containerfile COPY or Nix flake
- [ ] 5.4 Run full test suite: `./build.sh --test` passes with all changes
- [ ] 5.5 Build container image and verify locales are present at `/etc/tillandsias/locales/`
- [ ] 5.6 Manual integration test: launch forge with each locale, verify welcome banner, help, and error messages

## 6. Documentation & Commits

- [x] 6.1 Add `@trace spec:` annotations to all new/modified files
- [x] 6.2 Update cheatsheets with locale file structure (if missing)
- [ ] 6.3 Create commit(s) for this change
- [ ] 6.4 Push to origin/linux-next
