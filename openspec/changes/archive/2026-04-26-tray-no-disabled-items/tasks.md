## 1. Locale keys

- [ ] 1.1 In `locales/en.toml`, remove `menu.launch`, `menu.include_remote`, `menu.no_local_projects`, `menu.no_remote_projects`, `menu.maintenance_terminal`. Add `menu.attach_here_with_emoji = "🌱 Attach Here"`, `menu.attach_another_with_emoji = "🌱 Attach Another"`, `menu.signature_with_version = "v{version} — by Tlatoāni"`, `menu.status.building_one = "Building {image}…"`, `menu.status.building_many = "Building {images}…"`, `menu.status.ready = "{image} ready"`, `menu.status.github_unreachable = "GitHub unreachable — using cached list"`. Re-use the existing `menu.maintenance` (`"⛏️ Maintenance"`) for the per-stack child action.
- [ ] 1.2 Mirror the same key add/remove set in every other `locales/*.toml`. For locales without translations, leave the new keys as the English value — the runtime falls back to English on missing keys regardless, but explicit copies prevent accidental key removal during future edits.
- [ ] 1.3 Verify that `i18n::t` and `i18n::tf` resolve all new keys at runtime by writing one quick `cargo test -p tillandsias-tauri --bin tillandsias --lib i18n` style check, OR by `grep`-ing for any remaining `menu.launch` / `menu.include_remote` / `menu.no_local_projects` / `menu.no_remote_projects` / `menu.maintenance_terminal` in `src-tauri/`.

## 2. Event variant cleanup

- [ ] 2.1 In `crates/tillandsias-core/src/event.rs`, remove the `MenuCommand::IncludeRemoteToggle { include }` variant.
- [ ] 2.2 In `src-tauri/src/event_loop.rs:191`, remove the `MenuCommand::IncludeRemoteToggle` match arm.
- [ ] 2.3 In `src-tauri/src/main.rs`, remove the two call sites that read `menu.include_remote_checked()` and dispatch `IncludeRemoteToggle`. The `update_projects` call replacement is in §3.
- [ ] 2.4 Confirm `cargo check --workspace` after these removals — exhaustive match must still compile.

## 3. tray_menu.rs rewrite

- [ ] 3.1 In `src-tauri/src/tray_menu.rs`, remove `INCLUDE_REMOTE` from `ids` (line 52), remove the `include_remote_check: CheckMenuItem<R>` field, remove the import of `CheckMenuItem` / `CheckMenuItemBuilder`.
- [ ] 3.2 Collapse `version_line` and `signature_line` into a single field `signature_combined: MenuItem<R>` whose initial text is `format!("v{} — by Tlatoāni", env!("TILLANDSIAS_FULL_VERSION"))` (or via `i18n::tf("menu.signature_with_version", &[("version", env!("TILLANDSIAS_FULL_VERSION"))])`). Remove `ids::SIGNATURE` (or repurpose its ID for the combined line) and remove `ids::VERSION_LINE`.
- [ ] 3.3 Replace the pre-built static items (`building_chip`, `ready_indicator`, `sign_in`, `net_banner`, `projects_submenu`) with: a single `status_line: MenuItem<R>` handle (initially with empty text, NOT appended to the menu); a `sign_in: MenuItem<R>` handle (NOT initially appended). Stop pre-appending these to the root menu — they are appended on demand in §3.6.
- [ ] 3.4 Reduce the root menu builder (`MenuBuilder::new(app)…build()`) at lines ~277–289 to ONLY the static row: `[ separator_top, language, signature_combined, quit ]`. The variable region above the separator is owned by `update_dynamic_region` (§3.6).
- [ ] 3.5 Delete `set_stage` and `StageVisibility::for_stage`. Replace with a single method `apply_state(&self, app: &AppHandle<R>, stage: Stage, state: &TrayState) -> tauri::Result<()>` that calls `update_dynamic_region` (§3.6). Keep the `Stage` enum and `stage_from_health` — both are still semantic state.
- [ ] 3.6 Implement `update_dynamic_region(&self, app: &AppHandle<R>, stage: Stage, state: &TrayState) -> tauri::Result<()>`:
  - Compute a `MenuRegionCacheKey` from `(stage, status_text(state, stage), running_stack_signature(state), local_project_signature(state), remote_project_signature(state))`. Stash on `Mutex<MenuRegionCacheKey>`. Skip the rebuild if the key is unchanged.
  - Iterate the root menu's `items()` and `remove` every item whose position is above the top separator (the static row at the bottom is never touched). Use a sentinel: items above the `separator_top` index are dynamic; items at and below are static.
  - Compute the dynamic items in order, then `prepend` (or `insert(idx, …)`) them above the separator: optional status line → optional sign-in action → running-stack submenus (sorted by project name) → optional `Projects ▸` → optional `Remote Projects ▸`.
  - Update the cache key only after the rebuild succeeds.
- [ ] 3.7 Implement `status_text(state, stage) -> Option<String>` as a pure function. Inputs: `state.active_builds` (active vs completed-within-2s), `stage == Stage::NetIssue`. Output: `Some(joined_text)` if any condition holds, else `None`. Joining: `["Building forge…", "GitHub unreachable — using cached list"].join(" · ")`. Use `i18n::tf("menu.status.building_one", …)` etc. for individual fragments.
- [ ] 3.8 Implement `running_stacks(state) -> Vec<RunningStack>` returning `(project_name, project_path, bloom_emoji, tool_emojis)` for every project with at least one container of type `Forge | OpenCodeWeb | Maintenance` in `state.running`. `bloom_emoji: Option<String>` comes from the `OpenCodeWeb` container's `display_emoji` if present (today: `🌺`); else `None` (no fallback to Forge genus — bloom communicates "live web session", not "forge alive"). `tool_emojis: Vec<String>` comes from `display_emoji` of `Maintenance` containers in `state.running` insertion order, capped at 5 entries. Sorted by `project_name.to_lowercase()`.
- [ ] 3.9 Implement `build_running_stack_submenu(app, stack)` returning a `Submenu<R>` with label `"<project>[ <bloom>][ <tool emojis>]"` (project name first; bloom present only if `Some`; tool emojis present only if non-empty) and exactly two children: `🌱 Attach Another` from `i18n::t("menu.attach_another_with_emoji")` (id `ids::launch(&project_path)` — same `MenuCommand::Launch` dispatch as the cold-start path), and `🔧 Maintenance` from `i18n::t("menu.maintenance")` (id `ids::maint(&project_path)`).
- [ ] 3.10 Update `build_local_project_submenu` to remove the per-stack `Maintenance terminal` child when the project's forge is NOT running (the new spec hides Maintenance instead of disabling it). Rename the local action to `🌱 Attach Here` using `i18n::t("menu.attach_here_with_emoji")`. Drop the `🌺 ` prefix on the local-project label since the live shortcut is the top-level entry.
- [ ] 3.11 Update `build_remote_project_submenu` unchanged — it already produces a single `Clone & Launch` child that dispatches `MenuCommand::CloneProject`.
- [ ] 3.12 Update the `Projects ▸` submenu construction inside `update_dynamic_region`: only append it when `state.projects` is non-empty. Inside, omit the `INCLUDE_REMOTE` check and omit the "No local projects" placeholder. Iterate sorted local projects directly.
- [ ] 3.13 Add `Remote Projects ▸` submenu construction inside `update_dynamic_region`: only append when `remote_only` (repos in `state.remote_repos` not in `state.projects` AND not present on disk under any watch path) is non-empty. Iterate sorted remote-only repos and call `build_remote_project_submenu` for each.
- [ ] 3.14 Update `refresh_static_labels` to refresh ONLY `signature_combined`, `language`, `quit`. Drop refreshes for the removed handles. The dynamic region's labels are recomputed on every `update_dynamic_region` pass, so locale changes naturally pick them up via the standard event-loop tick.
- [ ] 3.15 Update `dispatch_click` to remove the `INCLUDE_REMOTE` arm.

## 4. Wire-up in main.rs and event_loop.rs

- [ ] 4.1 In `src-tauri/src/main.rs`, replace the two `update_projects` call sites with `apply_state(stage, &state)` (or the equivalent helper that re-computes stage from `(state.enclave_health, credential_health, remote_repo_fetch_status)`). Verify no caller still references `menu.include_remote_checked()`.
- [ ] 4.2 In `src-tauri/src/event_loop.rs`, ensure every place that called `on_state_change(&state)` (lines 121, 141, 161, 193, 202, 209, 216, 222, 432, 503) still triggers a tray menu refresh. The `on_state_change: MenuRebuildFn` callback is the same — it now indirectly calls `apply_state` instead of `set_stage` + `update_projects`.
- [ ] 4.3 Verify `cargo check --workspace` passes.

## 5. Cheatsheet update

- [ ] 5.1 Rewrite `docs/cheatsheets/tray-state-machine.md` to reflect the new visibility table. Replace the old "Visible items" column with the new variable-region composition (status line / sign-in / running stacks / Projects / Remote Projects). Keep `@trace spec:tray-app` annotations.
- [ ] 5.2 Add a row showing the contextual-status-line truth table: which `(active_builds, stage)` combinations produce which text.

## 6. Tests

- [ ] 6.1 In `src-tauri/src/tray_menu.rs` `tests` module, delete `stage_visibility_table_matches_spec` (the table no longer exists). Add `status_text_truth_table` covering the matrix of `(active_builds, stage) → status_text` outputs, asserting `None` for the idle-authed combination.
- [ ] 6.2 Add `running_stacks_orders_by_name` asserting `running_stacks(state)` returns project names in `to_lowercase()` ASCII order regardless of insertion order in `state.running`.
- [ ] 6.3 Add `running_stacks_includes_tool_emojis` asserting that when a project has both `OpenCodeWeb` and `Maintenance` containers, the returned `RunningStack.tool_emojis` contains the `Maintenance` emojis in allocation order.
- [ ] 6.4 Update `dispatch_click_known_actions` to remove the `INCLUDE_REMOTE` assertion.
- [ ] 6.5 Add `dispatch_click_unknown_include_remote_returns_none` to confirm the legacy ID still parses to `None` (defensive — old menu state should never click this, but if it does, we don't crash).
- [ ] 6.6 Run `cargo test --workspace` and confirm green.

## 7. Manual verification on Linux

- [ ] 7.1 `./build.sh --check` passes.
- [ ] 7.2 `./build.sh` (debug) — launch the tray. Open the menu in `Booting`, `NoAuth` (no token), `Authed` (token present, no projects), `Authed` (token present, projects present), `Authed` (with one running forge), `NetIssue` (drop network mid-session). For each: confirm exactly one disabled signature row, no `No local projects` / `No remote projects` placeholders, no `Building […]` row when idle, `🔑 Sign in to GitHub` only present in NoAuth/NetIssue and enabled.
- [ ] 7.3 Click the running-stack submenu's `🌱 Attach Here` — confirm a second browser window opens against the same forge with no second container started (`podman ps` shows one `tillandsias-<project>-forge`).
- [ ] 7.4 Click the running-stack submenu's `🔧 Maintenance` twice — confirm two terminal windows open, both `podman exec`'d into the same forge.
- [ ] 7.5 Quit Tillandsias — confirm `shutdown_all` cleans the running stack (no `tillandsias-*` containers left after exit).

## 8. Trace + version

- [ ] 8.1 Confirm every modified function in `src-tauri/src/tray_menu.rs` carries `// @trace spec:tray-app` near the function definition.
- [ ] 8.2 Run `./scripts/bump-version.sh --bump-changes` after archive (per CLAUDE.md), not now.
