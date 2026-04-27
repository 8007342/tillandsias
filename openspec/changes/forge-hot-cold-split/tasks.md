# Tasks — forge-hot-cold-split

Six independently committable chunks per `docs/strategy/forge-hot-cold-split-plan.md`.

## 1. Sized tmpfs profile model (chunk 1) — IN FLIGHT

- [ ] 1.1 `crates/tillandsias-core/src/container_profile.rs`: replace `pub tmpfs_mounts: Vec<&'static str>` with `pub tmpfs_mounts: Vec<TmpfsMount>` where `TmpfsMount { path: &'static str, size_mb: u32, mode: u32 }`.
- [ ] 1.2 Update all 7 profile constructors. Existing service-profile mounts (`web`, `git_service`) gain `size_mb: 64`.
- [ ] 1.3 `src-tauri/src/launch.rs::build_podman_args`: drop the `if profile.read_only` gate. Emit `--tmpfs=<path>:size=<N>m,mode=<oct>` for every entry.
- [ ] 1.4 Pair `--memory=<N>m` and `--memory-swap=<same>` whenever any tmpfs is present. N = sum of caps + 256MB working-set baseline.
- [ ] 1.5 Tests: `every_profile_with_tmpfs_emits_size_cap`, `web_and_git_service_keep_their_existing_tmpfs_paths`, `tmpfs_emits_sized_flag_with_mode`, `tmpfs_pairs_with_memory_ceiling`, `forge_profiles_no_tmpfs_yet_no_memory_ceiling`.
- [ ] 1.6 `cargo check --workspace --tests` clean; full workspace tests pass.

## 2. Cheatsheets onto a hot mount (chunk 2)

- [ ] 2.1 `images/default/Containerfile`: rename COPY target from `/opt/cheatsheets` to `/opt/cheatsheets-image` (RO image lower layer, baked at build time).
- [ ] 2.2 `images/default/lib-common.sh`: add idempotent `populate_hot_paths()` that does `cp -a /opt/cheatsheets-image/. /opt/cheatsheets/ 2>/dev/null || true`.
- [ ] 2.3 Forge entrypoints (`entrypoint-forge-opencode.sh`, `entrypoint-forge-claude.sh`, `entrypoint-forge-opencode-web.sh`, `entrypoint-terminal.sh`): call `populate_hot_paths` AFTER tmpfs is mounted by podman, BEFORE any agent-visible work.
- [ ] 2.4 `crates/tillandsias-core/src/container_profile.rs::common_forge_mounts`: add `TmpfsMount { path: "/opt/cheatsheets", size_mb: 8, mode: 0o755 }` to the four forge/maintenance profiles' tmpfs_mounts.
- [ ] 2.5 Verify `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` is unchanged in the Containerfile (transparency requirement).
- [ ] 2.6 Test: `forge_profile_includes_cheatsheets_tmpfs_mount`.
- [ ] 2.7 Manual smoke: launch a forge, `findmnt /opt/cheatsheets -no FSTYPE` returns `tmpfs`; `wc -l /opt/cheatsheets/INDEX.md` matches the image-baked count.

## 3. Pre-flight RAM measurement + per-launch project-source budget (chunk 3)

- [ ] 3.1 `src-tauri/src/preflight.rs` (NEW): `check_host_ram(required_mb: u32) -> Result<(), PreflightError>`. Reads `/proc/meminfo` (Linux) / macOS sysctl / Windows GlobalMemoryStatusEx. Returns `Err` if `MemAvailable < required * 1.25`.
- [ ] 3.2 `src-tauri/src/launch.rs`: extend `LaunchContext` with `pub hot_path_budget_mb: u32`.
- [ ] 3.3 `src-tauri/src/launch.rs::compute_hot_budget(project_name, cache_dir)`: runs `git -C <mirror> count-objects -v -H | grep size-pack`, parses + multiplies by `forge.hot_path_inflation` (default 4), clamps to `[256, forge.hot_path_max_mb]`.
- [ ] 3.4 `crates/tillandsias-core/src/config.rs`: add `forge.hot_path_max_mb` (default 4096) and `forge.hot_path_inflation` (default 4) keys.
- [ ] 3.5 `build_podman_args()`: when profile is forge-shaped, append `--tmpfs=/home/forge/src:size=<budget>m,mode=0755`.
- [ ] 3.6 Every forge launch site in `handlers.rs` (search for `start_forge` / `handle_attach_web` / `handle_maintenance_terminal`): call `preflight::check_host_ram(ctx.hot_path_budget_mb + 80)` before invoking podman; emit tray notification on failure.
- [ ] 3.7 Tests: `compute_hot_budget_returns_floor_for_empty_mirror`, `compute_hot_budget_clamps_at_ceiling`, `check_host_ram_refuses_below_threshold`.
- [ ] 3.8 Manual smoke: launch a forge, `findmnt /home/forge/src -no FSTYPE` = tmpfs; `df --output=size /home/forge/src` ≈ the per-launch budget.

## 4. Cap /tmp and formalise /run/user/1000 (chunk 4)

- [ ] 4.1 `crates/tillandsias-core/src/container_profile.rs::common_forge_mounts`: add `TmpfsMount { path: "/tmp", size_mb: 256, mode: 0o1777 }` and `TmpfsMount { path: "/run/user/1000", size_mb: 64, mode: 0o0700 }`.
- [ ] 4.2 Test: `forge_profile_caps_tmp_and_run_user`.
- [ ] 4.3 Manual smoke: inside a forge, `df --output=size /tmp` ≈ 256MB; `dd if=/dev/zero of=/tmp/x bs=1M count=512` fails with ENOSPC at ~256MB.

## 5. Welcome banner + path-taxonomy cheatsheet (chunk 5)

- [ ] 5.1 `images/default/forge-welcome.sh`: under the existing `Mounts` block, add a `RAM` line listing tmpfs paths + caps (read at runtime from `findmnt -t tmpfs`).
- [ ] 5.2 `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md`: add fifth column "Backing store: RAM | Disk | Image"; new "Hot vs Cold" section.
- [ ] 5.3 `cheatsheets/runtime/forge-container.md`: cross-link.
- [ ] 5.4 New `cheatsheets/runtime/forge-hot-cold-split.md` (≤200 lines, full Provenance per agent-cheatsheets template).
- [ ] 5.5 `scripts/regenerate-cheatsheet-index.sh` picks up the new cheatsheet.

## 6. Tray pre-flight surface + observability (chunk 6)

- [ ] 6.1 `src-tauri/src/handlers.rs`: at every `start_forge` / `handle_attach_web` / `handle_maintenance_terminal` call site, emit a structured log with `accountability = true, category = "forge-launch", spec = "forge-hot-cold-split"` recording `host_mem_available_mb`, `budget_mb`, `decision = "launch"|"refuse"`.
- [ ] 6.2 Tray notification surface for refusal cases (chunk 3 added the check; this surfaces it via Tauri notification).
- [ ] 6.3 Test: `tray_preflight_unit_test_decision_refuse_emits_notification`.
- [ ] 6.4 Spec changes: write `openspec/changes/forge-hot-cold-split/specs/forge-hot-cold-split/spec.md` (NEW capability) and delta specs for `forge-cache-dual`, `default-image`, `agent-cheatsheets`, `podman-orchestration`.
- [ ] 6.5 `openspec validate forge-hot-cold-split` — expect 0 errors.
- [ ] 6.6 Archive: `openspec archive forge-hot-cold-split -y`.
