## Tasks

- [ ] 1. Add `resvg` and `tiny-skia` as `[build-dependencies]` in `src-tauri/Cargo.toml`
- [ ] 2. Extend `src-tauri/build.rs` to render all 32 SVGs (`assets/icons/<genus>/<state>.svg`) into 32x32 PNGs in `OUT_DIR/icons/<genus>/<state>.png` using `resvg`
- [ ] 3. Extend `src-tauri/build.rs` to render the 3 tray icon variants (Ionantha bud/bloom/dried) into `OUT_DIR/icons/tray/base.png`, `building.png`, `decay.png` at 32x32
- [ ] 4. Extend `src-tauri/build.rs` to render per-genus, per-lifecycle window icons at 48x48 into `OUT_DIR/icons/window/<genus>/<state>@48.png`
- [ ] 5. Add `TrayIconState` enum (`Base`, `Building`, `Decay`) to `crates/tillandsias-core/src/genus.rs`
- [ ] 6. Create `crates/tillandsias-core/src/icons.rs` with `icon_png(genus, lifecycle, size)` and `tray_icon_png(state)` functions using `include_bytes!` pointed at `OUT_DIR` paths via `env!("OUT_DIR")`
- [ ] 7. Expose the `icons` module in `crates/tillandsias-core/src/lib.rs`
- [ ] 8. Replace `include_bytes!("../icons/tray-icon.png")` in `src-tauri/src/main.rs` with `tillandsias_core::icons::tray_icon_png(TrayIconState::Base)`
- [ ] 9. Add unit tests to `icons.rs` verifying all 32 PNG combinations are non-empty and start with the PNG magic bytes (`\x89PNG`)
- [ ] 10. Verify `cargo build --workspace` succeeds and the tray icon loads correctly at runtime
