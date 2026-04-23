Tasks are organized into three waves. Within a wave, tasks are parallelisable; between waves, everything upstream must compile and pass `cargo check`/`cargo test` before the next wave starts.

Every code change MUST carry a `// @trace spec:opencode-web-session` (or relevant spec) annotation. Shell scripts use `# @trace spec:opencode-web-session`. See `CLAUDE.md`.

## 1. Wave 1 — Enum, entrypoint, image wiring, menu strings (parallel, small)

- [x] 1.1 Extend `SelectedAgent` in `crates/tillandsias-core/src/config.rs`: add `OpenCodeWeb` variant, update `as_env_str` (`"opencode-web"`), `from_str_opt`, `display_name` (`"OpenCode Web"`); flip `Default::default()` to `OpenCodeWeb`. Add `is_web()` helper. Update unit tests.
- [x] 1.2 Add new `ContainerType::OpenCodeWeb` variant (distinct from existing `ContainerType::Web` used by Serve Here) in `crates/tillandsias-core/src/state.rs`. Add `ContainerInfo::forge_container_name(project_name: &str) -> String` returning `tillandsias-<project>-forge`, plus `parse_forge_container_name(name: &str) -> Option<String>`. Do NOT rename or alter `ContainerType::Web` / `web_container_name` which belong to Serve Here. (Moved to Wave 2 — the Wave 1 agent left this undone because `ContainerType::Web` already existed.)
- [x] 1.3 Create `images/default/entrypoint-forge-opencode-web.sh` — copy from `entrypoint-forge-opencode.sh`, replace the final `exec opencode "$@"` block with `exec opencode serve --hostname 0.0.0.0 --port 4096`, drop the interactive banner, keep all setup (CA trust, git clone, OpenSpec init, OpenCode install). Add `# @trace spec:opencode-web-session, spec:default-image` header.
- [x] 1.4 Update `images/default/Containerfile` to COPY `entrypoint-forge-opencode-web.sh`, `chmod +x` it, and update `images/default/entrypoint.sh` dispatcher to route `opencode-web) exec /usr/local/bin/entrypoint-forge-opencode-web.sh "$@" ;;`.
- [x] 1.5 Add i18n strings `menu.stop` across 17 locale files (`locales/*.toml`). Agent dropdown labels stay hardcoded in Rust `display_name()`.
- [x] 1.6 Run `toolbox run -c tillandsias cargo check --workspace` — passes (after orchestrator added `forge_opencode_web_profile()` + 2 match arms as Wave 1 follow-ups).
- [x] 1.7 Orchestrator follow-up: add `forge_opencode_web_profile()` in `crates/tillandsias-core/src/container_profile.rs`; add `SelectedAgent::OpenCodeWeb` arms in `src-tauri/src/handlers.rs::forge_profile` and `src-tauri/src/runner.rs` agent dispatch.

## 2. Wave 2 — Orchestration, port allocation, webview builder (parallel, medium)

- [x] 2.1 In `crates/tillandsias-podman/src/launch.rs` add `LaunchMode::Detached` (or equivalent flag on the launch options struct) that emits `-d` and omits `-i -t --rm`. Keep the existing interactive mode untouched.
- [x] 2.2 In `crates/tillandsias-podman/src/launch.rs` add `allocate_single_port(start: u16, end: u16)` returning one free host port in the ephemeral range (default 17000-17999). Include a unit test that two calls return distinct ports.
- [x] 2.3 In `crates/tillandsias-podman/src/launch.rs` extend publish-arg construction so that when the launch mode is web, the `-p` arg is `127.0.0.1:<host_port>:4096`. Unit test: assert the produced arg string starts with `"127.0.0.1:"` and contains no `"0.0.0.0"`.
- [x] 2.4 In `src-tauri/src/launch.rs` add a `forge_opencode_web_profile()` sibling to `forge_opencode_profile()` / `forge_claude_profile()` that sets env `TILLANDSIAS_AGENT=opencode-web`, picks the detached mode, requests the single-port publish, and targets the same forge image.
- [x] 2.5 Create new module `src-tauri/src/webview.rs` exposing `open_web_session(app: &AppHandle, project: &ProjectInfo, genus: &str, host_port: u16) -> tauri::Result<()>`. Uses `tauri::WebviewWindowBuilder::new(app, format!("web-{}-{}", project.name, epoch_ms), url::Url::parse(...)?)`, sets size 1200x800, title `"Tillandsias — {project} ({genus})"`. Wire module in `src-tauri/src/main.rs` via `mod webview;`.
- [x] 2.6 Health-wait helper in `src-tauri/src/webview.rs`: `wait_for_web_ready(host_port: u16, timeout: Duration)` pings `http://127.0.0.1:<host_port>/` with exponential backoff (1s/2s/4s/8s cap, total ~30s) before opening the window. Reuse existing health-check utilities from `tillandsias-podman` if available.
- [x] 2.7 Run `toolbox run -c tillandsias cargo check --workspace && cargo test -p tillandsias-podman` — must pass.

## 3. Wave 3 — Attach flow, Stop action, shutdown, tests (integration)

- [x] 3.1 In `src-tauri/src/handlers.rs` refactor `handle_attach_here` to branch on `global_config.agent.selected.is_web()`: web path calls new `handle_attach_web(...)`; else falls through to existing terminal path unchanged.
- [x] 3.2 Implement `handle_attach_web(...)` in `src-tauri/src/handlers.rs`:
  1. Look up existing `tillandsias-<project>-forge` in `TrayState::running` and via `podman ps` — if present, reuse its host port.
  2. Otherwise: allocate port, ensure enclave prerequisites (forge image, proxy, git service, inference) via existing helpers, start detached container, register in `TrayState::running` with `container_type = Web`.
  3. Wait for `http://127.0.0.1:<port>/` to become ready (exponential backoff).
  4. Call `webview::open_web_session(...)` to spawn a new `WebviewWindow`.
  5. Log each step via `trace_lifecycle!` with `@trace spec:opencode-web-session`.
- [x] 3.3 Add `handle_stop_project(project_path)` in `src-tauri/src/handlers.rs`: stops the project's web container via launcher, removes it from state, closes every `WebviewWindow` whose label starts with `web-<project>-`, releases the port.
- [x] 3.4 In `src-tauri/src/menu.rs` add the "OpenCode Web" Seedlings option first; update active-choice rendering. Add per-project "Stop" item rendered only when `TrayState::running` contains a `Web` container for that project. Add new `MenuCommand::StopProject` variant and wire through `src-tauri/src/event_loop.rs`.
- [x] 3.5 In `src-tauri/src/handlers.rs::shutdown_all()` ensure the existing loop over `state.running` stops web containers (the generic launcher.stop path already handles them once `ContainerType::Web` is recognised — verify no special casing is needed). Extend the orphan-sweep filter to match `tillandsias-*-forge` (likely already covered by the existing `tillandsias-` prefix filter — verify and document). Before stopping containers, call `app.webview_windows()` and close all whose label starts with `"web-"`.
- [x] 3.6 Add cheatsheet `docs/cheatsheets/opencode-web.md` — one-pager covering: default agent, port contract (127.0.0.1 only), persistent container, multi-webview semantics, Stop action, shutdown behaviour. Include `@trace spec:opencode-web-session`.
- [x] 3.7 Integration tests added (launch arg assertions in `src-tauri/src/launch.rs` tests; single-port allocator tests in `tillandsias-podman`) in `src-tauri/tests/` (or appropriate test crate) for: (a) launch arg assembly for web mode produces `-d`, no `--rm`, `127.0.0.1:P:4096`; (b) single-port allocator returns distinct ports.
- [x] 3.8 `cargo test --workspace` (252 passed, 1 pre-existing flake in isolation-only test) + `cargo clippy --workspace` (no new warnings).
- [x] 3.9 Rebuild forge image: `scripts/build-image.sh forge` — built `localhost/tillandsias-forge:latest`, new entrypoint confirmed present, dispatcher routes `opencode-web` correctly.
- [x] 3.10 Headless smoke test: launched `entrypoint-forge-opencode-web.sh` in a detached container with `-p 127.0.0.1:17500:4096`; confirmed `opencode serve` listens on 0.0.0.0:4096 inside, HTTP 200 returned on `http://127.0.0.1:17500/` after ~6s. Full UI-side smoke test (webview open, Stop, quit) deferred to user since the agent environment has no display.
- [ ] 3.11 `./scripts/bump-version.sh --bump-changes`, commit with `@trace spec:opencode-web-session` URL, push `linux-next`.

## 4. Wave 4 — Merge and release

- [ ] 4.1 After successful local validation: merge `linux-next` to `main`.
- [ ] 4.2 `./scripts/bump-version.sh --bump-build`, tag if convention requires.
- [ ] 4.3 `gh workflow run release.yml -f version="<new_version>"` from `main`.
- [ ] 4.4 `/opsx:verify add-opencode-web-agent` then `/opsx:archive add-opencode-web-agent`.
