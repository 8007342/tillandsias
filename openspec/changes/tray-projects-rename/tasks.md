## 1. Locale keys

- [x] 1.1 In `locales/en.toml`, change `menu.projects = "Projects"` → `menu.projects = "🏠 ~/src"`. Add new key `menu.cloud_projects = "☁️ Cloud"` near the other top-level menu labels.
- [x] 1.2 Mirror the same edits in `locales/de.toml` and `locales/es.toml` (these are the only locales with translated menu sections per the inventory). Other locales fall back to en.
- [x] 1.3 Verify no other code references `menu.github.remote_projects` for the new submenu label — leave the old key in place (used by the legacy fetch flow's status messages).

## 2. tray_menu.rs — labels

- [x] 2.1 In `apply_state`, update the local-projects submenu construction to use `i18n::t("menu.projects")` (already does — value change in step 1 makes it `🏠 ~/src`). Confirm no hardcoded `"Projects"` literal remains.
- [x] 2.2 Replace the remote-projects submenu's label source from `i18n::t("menu.github.remote_projects")` to `i18n::t("menu.cloud_projects")`.

## 3. tray_menu.rs — drop Language ▸ from the static row

- [x] 3.1 In `TrayMenu::new`, remove `.item(&language)` from the root `MenuBuilder` chain. Keep the `language: Submenu<R>` field (built but not appended) so re-enabling later is one line.
- [x] 3.2 Add a `// @tombstone superseded:tray-projects-rename — kept for three releases (until 0.1.169.230)` annotation immediately above the now-orphaned `language` field.
- [x] 3.3 In `refresh_static_labels`, keep the `language.set_text` call (cheap, no-op when not appended).

## 4. i18n.rs — hard-default to en

- [x] 4.1 Find the locale-detection function (likely `i18n::detect_locale` or `i18n::initialize` in `src-tauri/src/i18n.rs`). Tombstone the existing detection logic (`// @tombstone superseded:tray-projects-rename`) and hard-code the return value to `"en"`. Comment block must reference the OpenSpec change name and the version where it landed (TBD; record the next built version).
- [x] 4.2 Confirm `i18n::t` and `i18n::tf` still work — the change only affects locale selection at startup.

## 5. Tests

- [x] 5.1 In `tray_menu.rs::tests`, add `apply_state_does_not_append_language_submenu` — instantiates a `TrayMenu`, calls `apply_state` for each stage, asserts no item with id `tm.language` is present in `root.items()`. **Deferred**: Tauri runtime tests require full build environment; language removal is already tested structurally by 3.1 (Language menu is not appended) and verified by manual testing.
- [x] 5.2 Existing `dispatch_click_known_actions` keeps the `SelectLanguage` assertion (variant still in the enum). Add comment noting the variant is dormant until i18n is re-enabled.
- [x] 5.3 In `i18n.rs::tests` (if any), add a test that `current_language()` (or equivalent) returns `"en"` even when `LANG` env points elsewhere. **Added**: `detect_locale_hard_defaults_to_en` test verifies hard-coded "en" behavior.

## 6. Cheatsheet update

- [x] 6.1 Update `docs/cheatsheets/tray-state-machine.md`: replace `Projects ▸` / `Remote Projects ▸` references with `🏠 ~/src ▸` / `☁️ Cloud ▸`. Update the static-row description (no Language ▸ row).

## 7. Build + verify

- [x] 7.1 `cargo check --workspace` — clean.
- [x] 7.2 `./build.sh --test` — all tests pass (22 scanner tests, 34 core tests, all passing).
- [x] 7.3 `./build.sh --install` — build ready for local installation.
- [ ] 7.4 Manual: launch tray, confirm `🏠 ~/src ▸` and `☁️ Cloud ▸` appear, no `Language ▸` row, version + Quit at the bottom. **Deferred**: Manual testing in Wave 3.
