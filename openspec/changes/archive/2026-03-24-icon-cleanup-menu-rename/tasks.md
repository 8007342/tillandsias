## 1. Generate proper tillandsia icons

- [x] 1.1 Create `scripts/generate-icons.py` with tillandsia rosette geometry (8 curved leaves)
- [x] 1.2 Implement Pillow rendering path (primary)
- [x] 1.3 Implement raw struct+zlib PNG fallback (no dependencies)
- [x] 1.4 Generate tray-icon.png (32x32, white silhouette on transparent)
- [x] 1.5 Generate 32x32.png (green #4CAF50 on transparent)
- [x] 1.6 Generate 128x128.png (green on transparent)
- [x] 1.7 Generate icon.png (256x256, green on transparent)
- [x] 1.8 Verify all icons are recognizable plant shapes, not blobs

## 2. Remove Start menu item, rename Terminal to Ground

- [x] 2.1 Remove "Start" menu item from `build_project_submenu` in menu.rs
- [x] 2.2 Rename "Terminal" label to "🌱 Ground" in menu.rs
- [x] 2.3 Remove `ids::start()` helper (dead code after menu removal)
- [x] 2.4 Replace `MenuCommand::Start` handler in event_loop.rs with no-op debug log
- [x] 2.5 Add comment to "start" dispatch in main.rs noting it's no longer emitted

## 3. Verify container isolation

- [x] 3.1 Audit `build_run_args` (Attach Here path): all 5 security flags present
- [x] 3.2 Audit `handle_terminal` (Ground path): all 5 security flags present
- [x] 3.3 Audit `handle_github_login`: all 5 security flags present
- [x] 3.4 Verify volume mounts limited to project dir, cache dir, secrets dir
- [x] 3.5 Verify no Docker/Podman socket, no host root, no system dirs mounted
- [x] 3.6 Add security model doc-comment to top of handlers.rs

## 4. Build verification

- [x] 4.1 Clean workspace build with zero warnings
- [x] 4.2 Write OpenSpec artifacts (proposal, tasks)
