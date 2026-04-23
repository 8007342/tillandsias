## Context

Tillandsias currently offers two session agents — OpenCode and Claude — both launched by spawning a native terminal emulator and running `podman run -it --rm ...` inside it. The terminal code path differs per platform (`ptyxis`/`gnome-terminal` on Linux, `Terminal.app` on macOS, `wt.exe` on Windows) and has been a recurring source of regressions. The most recent Windows fix (`Stdio::null()` to avoid stale-handle crashes after `FreeConsole`) inadvertently disabled the Linux path: no terminal window appears at all on Fedora now.

OpenCode recently shipped a `serve`/`web` subcommand that starts an HTTP server (default `:4096`) with a full browser-based UI and built-in terminal emulator. Tauri v2 can create `WebviewWindow` instances at runtime on all three platforms using the same builder API. Together these eliminate the need for a platform-specific terminal dance and unlock multi-session workflows against a single long-lived project container.

## Goals / Non-Goals

**Goals:**

- Make "OpenCode Web" the out-of-the-box default session agent.
- Run one persistent forge-family container per project, named `tillandsias-<project>-forge`, launched detached, torn down only on explicit Stop or Tillandsias quit.
- Map OpenCode's `:4096` to a host port bound strictly to `127.0.0.1` — never `0.0.0.0`.
- Open a Tauri `WebviewWindow` per "Attach Here" click; allow multiple webviews to attach to the same container.
- Closing a webview does not stop the container.
- Keep OpenCode CLI and Claude CLI as opt-in escape hatches (unchanged).
- Preserve every enclave-security flag (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, read-only root, enclave network).
- Integrate cleanly with existing `shutdown_all()` and `TrayState::running` machinery.

**Non-Goals:**

- Fixing the Linux terminal regression in this change (side-stepped by the new default; opt-in users can still hit it).
- Cross-project shared containers (each project has its own web container).
- Authentication for the webview (local-loopback only is the entire security model).
- Bundling a browser — the Tauri webview is already WebKitGTK / WebView2 / WebKit.
- Exposing the web server to the LAN — explicitly forbidden.
- Changing how OpenCode/Claude terminal modes work.

## Decisions

### D1. Persistent, detached container per project (not ephemeral per session)

Running `-d` without `--rm` and keeping the container alive across webview sessions.

- **Why**: OpenCode Web is a server. Multi-webview "reattach" semantics require a single long-lived backend. Restarting it per webview would lose state, burn ~2–5s of install/clone per click, and defeat the "multiple sessions, one container" goal the user asked for.
- **Alternative considered**: restart per click with `--rm`. Rejected — wastes time, loses in-flight OpenCode state, and forces every webview to be the only webview.
- **Trade-off**: containers outlive individual clicks. Cleanup must be disciplined. Addressed by `shutdown_all()` integration and a per-project "Stop" menu item.

### D2. Host port bound to 127.0.0.1, not 0.0.0.0

Podman publish string: `-p 127.0.0.1:<host_port>:4096`.

- **Why**: OpenCode web has no auth. Any 0.0.0.0 bind would expose an unauthenticated code-execution agent to the LAN. Non-negotiable.
- **Alternative considered**: bind to container hostname only (no host publish) and reach it via podman machine's internal DNS. Rejected — Tauri webview runs on the host, not in the enclave; it needs a host-reachable URL. Podman machine (macOS/Windows) already proved DNS-alias brittleness (commit `df4c63c`).
- **Enforced** in `tillandsias-podman::launch::publish_args()` by an explicit `"127.0.0.1:"` prefix. A unit test asserts the prefix.

### D3. Single host port per web container, drawn from the existing port allocator

Extend `allocate_port_range()` to support a "single port" variant returning one ephemeral high port (start range 17000–17999). Stored in `ContainerInfo.port_range` as `(p, p)` to keep the field shape stable.

- **Why**: reuse the existing allocator, avoid a second collision-detection scheme.
- **Alternative considered**: fixed port 4096 on host. Rejected — breaks multi-project scenarios (two projects running concurrently would collide).

### D4. Container naming: `tillandsias-<project>-forge`, new `ContainerType` variant

Name: `tillandsias-<project>-forge`. No genus token. Tracked as new `ContainerType::OpenCodeWeb` variant (distinct from the existing `ContainerType::Web` used by the static-httpd "Serve Here" feature).

- **Why `-forge` not `-web`**: the existing "Serve Here" flow already owns `tillandsias-<project>-web`. Reusing that suffix would collide in `podman ps` and mis-classify in `ContainerInfo::parse_web_container_name`.
- **Why new `ContainerType` variant**: lets the tray menu and shutdown logic branch independently from Serve Here. `ContainerType::Web` continues to mean "static httpd"; `ContainerType::OpenCodeWeb` means "persistent forge running opencode serve".
- **Why no genus**: there is at most one OpenCodeWeb container per project. Genus is for visual disambiguation among peers; with exactly one, it's noise. It also gives the Stop action a stable, deterministic name to look up.
- **TrayState**: `ContainerInfo.genus` field still populated (allocator hands one out for icon/label display) but name construction skips it for this variant.

### D5. WebviewWindow created at runtime per "Attach Here" click

Use `tauri::WebviewWindowBuilder::new(app, label, url)` inside the attach handler, not declared in `tauri.conf.json`. Label format: `web-<project>-<epoch_ms>` — unique, allowing many concurrent windows.

- **Why**: the window set is dynamic (user-driven), not fixed at compile time. Tauri v2 supports runtime creation.
- **Configuration**: size 1200×800 default, resizable, title `Tillandsias — <project> (<genus>)`. Tauri webviews have no URL bar by default, so "kiosk" is the natural state; no explicit kiosk flag needed.
- **Lifecycle**: window has no linkage to the container. Close → window dies, container keeps running. `shutdown_all()` closes all remaining windows before stopping containers.

### D6. New entrypoint script, not an inline flag on the existing opencode entrypoint

Introduce `entrypoint-forge-opencode-web.sh` as a sibling of `entrypoint-forge-opencode.sh` and route to it from `entrypoint.sh` when `TILLANDSIAS_AGENT=opencode-web`.

- **Why**: the web path doesn't need the TUI banner, may want different logging, and the concerns are simpler to reason about in a dedicated file. Keeping the CLI path bit-for-bit unchanged reduces regression surface for existing OpenCode users.
- **Shared setup** (git clone, OpenSpec init, OpenCode install) is factored into common helpers already used by `lib-common.sh`.

### D7. New `opencode-web-session` capability; other specs get ADDED deltas only

The cross-cutting behavior (server lifecycle, port contract, webview contract, reattach semantics) lives in one new capability. Existing specs (`tray-app`, `podman-orchestration`, `environment-runtime`, `default-image`, `app-lifecycle`) get **ADDED** requirements only — no MODIFIED — because the change is purely additive at the requirement level.

- **Why**: MODIFIED requires copying full original requirement blocks verbatim and invites subtle drift. Pure-ADD deltas are safer and easier to archive.

### D8. Config default flip is breaking but silent

`AgentConfig::selected` default changes from `OpenCode` to `OpenCodeWeb`. Existing installs with an explicit `agent.selected = "opencode"` in `~/.config/tillandsias/config.toml` are unaffected. Fresh installs and installs that relied on the default now open a webview instead of a terminal.

- **Migration note**: documented in cheatsheet; no runtime migration needed — `from_str_opt` continues to accept all three variants.

## Risks / Trade-offs

- **Risk**: Tauri webview deps fail to build in the `tillandsias` toolbox (WebKitGTK). → **Mitigation**: the toolbox already includes WebKitGTK (Tauri tray app depends on it transitively). Add an explicit `build.sh --toolbox-reset` smoke test before merge.
- **Risk**: User closes webview, forgets container is running, accumulates state. → **Mitigation**: tray menu per-project "Stop" item is visible whenever a web container is running; shutdown on quit covers the worst case.
- **Risk**: Port collision with a user's own local service. → **Mitigation**: allocator scans existing listeners and retries; collisions produce a warning and the next free port.
- **Risk**: OpenCode `serve` flags change upstream. → **Mitigation**: entrypoint pinpoints the exact invocation in one place; contract tested via `opencode serve --help` parse in a smoke test (soft — skipped if binary absent).
- **Risk**: Detached containers outlive Tillandsias on hard crash. → **Mitigation**: existing orphan sweep in `shutdown_all()` (`podman ps --filter name=tillandsias-`) already catches `tillandsias-*-web`; startup also reconciles `TrayState` against live containers.
- **Risk**: 127.0.0.1 bind silently regressing to 0.0.0.0 in a future refactor. → **Mitigation**: unit test asserting publish arg begins with `"127.0.0.1:"`; `@trace spec:opencode-web-session` annotation makes grep-auditing trivial.
- **Trade-off**: web-mode container is not ephemeral, so uncommitted changes persist longer than in CLI mode. Documented in cheatsheet and banner.

## Migration Plan

1. Ship change on `linux-next` with the default still flipped; validate on Fedora.
2. Rebuild forge image (`scripts/build-image.sh forge`) to include new entrypoint.
3. Test on Linux locally — one project, single webview; same project, multiple webviews; multiple projects concurrently.
4. Merge to `main`, bump version with `./scripts/bump-version.sh --bump-changes`, trigger `release.yml`.
5. Rollback: if regressions appear, revert the `AgentConfig::default()` to `OpenCode` (one line) and release a patch — infrastructure stays in place for opt-in use.

## Open Questions

- Should "Stop" be a top-level Seedlings action or a per-project submenu item? Current plan: per-project submenu item, consistent with existing "Attach Here". (Settled — no blocker.)
- Should the webview remember window size/position? Out of scope for v1; Tauri handles this with a plugin we can add later if users ask.
