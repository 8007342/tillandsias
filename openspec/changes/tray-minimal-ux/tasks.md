## 1. Initial Tray Menu Simplification

- [x] 1.1 Modify `build_tray_menu()` in `src-tauri/src/menu.rs` to show only 4 elements at launch
- [x] 1.2 Add `Verifying environment ...` item with checklist icon (Unicode: ☑ or ✅)
- [x] 1.3 Add divider after the status item
- [x] 1.4 Add `Version X.Y.Z + Attributions` item (static, non-interactive)
- [x] 1.5 Add `Quit Tillandsias` item (always visible, always enabled)
- [x] 1.6 Add `@trace spec:tray-minimal-ux` annotation near menu building code

## 2. Dynamic Status Updates

- [x] 2.1 Create status update function that modifies the first element based on build state
- [x] 2.2 Implement `<Checklist><Network> Building enclave ...` when proxy is ready
- [x] 2.3 Implement `<Checklist><Network><Mirror> Building git mirror ...` when git is ready  
- [x] 2.4 Implement `<Checklist><Network><Mirror><Browser><DebugBrowser> ✓ Environment OK` when all images built
- [x] 2.5 Implement `<WhiteRose> Unhealthy environment` when any build fails
- [x] 2.6 Add `@trace spec:tray-minimal-ux` annotations to status update logic

## 3. Post-Initialization Menu Items

- [ ] 3.1 After successful build, add `<Home> ~/src >` if projects exist
- [ ] 3.2 After successful build + GitHub auth, add `<Cloud> Cloud >` for remote projects
- [ ] 3.3 If no GitHub credentials, show `<Key> GitHub login` instead of Cloud
- [ ] 3.4 Hide Projects/Cloud items until environment is fully ready
- [ ] 3.5 Add `@trace spec:tray-minimal-ux` annotations to conditional menu logic

## 4. Project Click Behavior

- [ ] 4.1 Modify project click handler to launch OpenCode Web container
- [ ] 4.2 Add logic to clone remote project to local before launching (if not cloned)
- [ ] 4.3 Once container is healthy, launch safe browser in `tillandsias-chromium-core` container
- [ ] 4.4 Use `tillandsias-browser-tool` to communicate between tray and browser container
- [ ] 4.5 Add `@trace spec:tray-minimal-ux` annotations to project click handler

## 5. Stale Container Cleanup

- [ ] 5.1 Add startup routine to clean up stale `tillandsias-*` containers
- [ ] 5.2 Remove stopped/orphaned containers not tracked in TrayState
- [ ] 5.3 Allow new containers to regenerate without conflicts
- [ ] 5.4 Add `@trace spec:tray-minimal-ux` annotation to cleanup logic

## 6. Update Existing Spec

- [ ] 6.1 Sync delta spec from `openspec/changes/tray-minimal-ux/specs/tray-ux/spec.md` to `openspec/specs/tray-ux/spec.md`
