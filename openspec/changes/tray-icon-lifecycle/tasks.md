## Tasks

- [ ] 1. Rename `TrayIconState::Base` to `Mature`, `Decay` to `Dried`, and add `Pup` and `Blooming` variants in `genus.rs`
- [ ] 2. Update `TRAY_ICONS` in `build.rs` from 3 to 5 entries: pup->pup.svg, mature->bud.svg, building->bloom.svg, blooming->bloom.svg, dried->dried.svg
- [ ] 3. Update generated `tray_icon_png()` match arms in `build.rs` `generate_icons_rs()` for all 5 variants
- [ ] 4. Update `TrayState::new()` in `state.rs` to initialize with `TrayIconState::Pup` instead of `Base`
- [ ] 5. Update `compute_icon_state()` in `state.rs` to return `Blooming` when recent builds completed and none in progress
- [ ] 6. Update `main.rs` startup: launch with `Pup` icon, transition to `Mature` when forge confirmed, `Dried` when podman missing
- [ ] 7. Add Blooming-to-Mature transition in `main.rs` `on_menu_event` when user opens tray menu
- [ ] 8. Update `menu.rs` references from `TrayIconState::Decay` to `TrayIconState::Dried`
- [ ] 9. Update test functions in `icons.rs` for renamed variants (`Base`->`Mature`, `Decay`->`Dried`) and add tests for `Pup` and `Blooming`
- [ ] 10. Verify `cargo test --workspace` passes and `cargo build --workspace` succeeds
