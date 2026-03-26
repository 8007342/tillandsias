## 1. Add build_projects_submenu() helper

- [ ] 1.1 Extract project iteration from `build_tray_menu()` into a new `build_projects_submenu()` function returning `tauri::Result<tauri::menu::Submenu<R>>`
- [ ] 1.2 Label the submenu "Projects" when multiple projects exist; include a count hint e.g. "Projects (3)" when there are more than 3
- [ ] 1.3 When `state.projects` is empty, the function still returns a submenu containing a single disabled "No projects detected" item
- [ ] 1.4 All per-project submenus built by `build_project_submenu()` are added as children of this new submenu

## 2. Move build chips into Running / Activity context

- [ ] 2.1 When `state.running` is non-empty, append a separator and the build chip items inside the Running Environments submenu (after the per-container items)
- [ ] 2.2 When `state.running` is empty but `state.active_builds` is non-empty, create a standalone "Activity" submenu containing the build chip items
- [ ] 2.3 Remove the inline build chip block from the top-level menu in `build_tray_menu()`

## 3. Add build_about_submenu() helper

- [ ] 3.1 Create `build_about_submenu()` returning `tauri::Result<tauri::menu::Submenu<R>>`
- [ ] 3.2 Submenu label is "Tillandsias v{version}" using the same `include_str!("../../VERSION")` embed
- [ ] 3.3 Submenu contains: disabled "Tillandsias v{version}" item, disabled "by Tlatoāni" item, separator, "Quit Tillandsias" item (enabled)
- [ ] 3.4 Remove the inline version, credit, and separator block from `build_tray_menu()`

## 4. Restructure build_tray_menu() top level

- [ ] 4.1 Top-level order after restructure: `src/ — Attach Here`, `🛠️ Root`, separator, `Projects ▸`, `Running ▸` (conditional), separator, `Settings ▸`, `Tillandsias v{version} ▸`
- [ ] 4.2 "Running Environments" submenu appears at top level only when `state.running` is non-empty; omitted entirely when idle (no "No running environments" placeholder at top level — that lives inside the Projects or Activity context)
- [ ] 4.3 All separators reduced: exactly two separators in normal operation (one after Root, one before Settings)
- [ ] 4.4 When `state.running` is empty, no Activity submenu appears unless there are active builds

## 5. Update build_decay_menu()

- [ ] 5.1 Replace inline version/credit/quit block in `build_decay_menu()` with a call to `build_about_submenu()`
- [ ] 5.2 Verify decay menu still compiles and renders correctly

## 6. Verify

- [ ] 6.1 `cargo check --workspace` passes
- [ ] 6.2 `cargo test --workspace` passes
- [ ] 6.3 Manual smoke test: tray menu opens, Projects submenu shows all projects, Running submenu appears/disappears with containers, About submenu contains version+credit+quit
