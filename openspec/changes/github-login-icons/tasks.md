## 1. Update GitHub Login Menu Labels

- [ ] 1.1 Change `"GitHub Login"` to `"\u{1F511} GitHub Login"` (🔑) in `build_settings_submenu`
- [ ] 1.2 Change `"GitHub Login Refresh"` to `"\u{1F512} GitHub Login Refresh"` (🔒) in `build_settings_submenu`

## 2. Verification

- [ ] 2.1 `cargo check --workspace` passes (or confirms only GTK linker errors, not compile errors)
- [ ] 2.2 Both string literals updated in `src-tauri/src/menu.rs`
