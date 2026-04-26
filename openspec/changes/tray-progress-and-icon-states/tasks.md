## 1. Locales

- [ ] 1.1 Update `locales/en.toml`: rename `menu.sign_in_github` value to `🔑 GitHub Login`. Add `menu.unhealthy_environment = "🥀 Unhealthy environment"`. Add `menu.status.verifying_environment` and `menu.status.ready_one`. Add chip names `menu.build.chip_browser_runtime`, `menu.build.chip_proxy`, `menu.build.chip_router`.
- [ ] 1.2 Mirror to `locales/de.toml` and `locales/es.toml` so locale-parity tests pass.

## 2. tray_menu.rs

- [ ] 2.1 Add `subsystem_emoji_and_order(image_name) -> Option<(u8, &'static str)>` mapping the seven chip substrings to (sort_order, emoji).
- [ ] 2.2 Rewrite `status_text(state, stage) -> Option<String>` to produce the additive chip shape. Tombstone the prior fragment-list version with `@tombstone superseded:tray-progress-and-icon-states`.
- [ ] 2.3 Add `Stage::Unhealthy` to the enum. Update `apply_state` to early-return with the `🥀` item when stage is Unhealthy. Update its docs.

## 3. main.rs

- [ ] 3.1 Update `current_stage` precedence: Unhealthy first (any Failed build, no in-flight retry), then Booting, then health-derived stages.

## 4. Tests

- [ ] 4.1 Existing tests in `tray_menu.rs::tests`: adjust `status_text_*` to match the new chip shape (`✅` prefix + emoji prefix + tail action text). The existing test names stay; only assertions change.
- [ ] 4.2 New test: `current_stage_returns_unhealthy_when_a_build_failed_without_retry`. Pure-function test against a fabricated `TrayState` with one `BuildStatus::Failed` row.
- [ ] 4.3 New test: `current_stage_returns_booting_when_failed_build_has_concurrent_retry`. Same shape, plus a parallel `BuildStatus::InProgress` row — confirms the retry overrides the failure.
- [ ] 4.4 `cargo test -p tillandsias --bin tillandsias` — green.

## 5. Cheatsheet update

- [ ] 5.1 Update `docs/cheatsheets/tray-state-machine.md`: add the new emoji table + Unhealthy stage + the additive chip shape to the existing visibility tables.

## 6. Out of scope (next change)

- Tray icon lifecycle (pup/green/blushing/bloom/withered + 10s post-click revert + withered-on-quit). Tracked separately to keep this change tractable; will be `tray-icon-state-machine` follow-up.
