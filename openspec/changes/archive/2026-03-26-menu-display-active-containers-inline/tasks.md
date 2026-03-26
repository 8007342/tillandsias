## 1. Menu Structure Refactor

- [x] 1.1 Split `state.projects` into active (has running containers) and inactive lists in `build_tray_menu()`
- [x] 1.2 Render active project submenus inline at the top level using `build_project_submenu()`
- [x] 1.3 Pass only inactive projects to `build_projects_submenu()`
- [x] 1.4 Omit the Projects submenu entirely when the inactive projects list is empty
- [x] 1.5 Render build chips inline (disabled top-level items) below active projects
- [x] 1.6 Delete `build_running_submenu()` function
- [x] 1.7 Delete `build_activity_submenu()` function

## 2. Verification

- [x] 2.1 `./build.sh --check` passes with no errors
