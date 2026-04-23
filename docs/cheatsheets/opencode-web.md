# OpenCode Web

Tillandsias ships OpenCode Web as the default session agent. Attach Here runs `opencode serve` inside a persistent per-project forge container and opens a Tauri webview pointed at the local HTTP server.

`@trace spec:opencode-web-session`

## Contract at a glance

| Aspect | Value |
|-|-|
| Default agent | `SelectedAgent::OpenCodeWeb` (env `opencode-web`) |
| Container name | `tillandsias-<project>-forge` (no genus) |
| Container mode | `-d` detached, **no** `--rm` — persistent across sessions |
| Container entrypoint | `/usr/local/bin/entrypoint-forge-opencode-web.sh` |
| Final exec | `opencode serve --hostname 0.0.0.0 --port 4096` (inside container) |
| Host port | Allocated 17000–17999, bound **only** to `127.0.0.1` |
| Publish arg | `-p 127.0.0.1:<host_port>:4096` (never bare, never `0.0.0.0`) |
| Webview URL | `http://127.0.0.1:<host_port>/` |
| Webview label | `web-<project>-<epoch_ms>` (unique per click) |
| Webview window title | `Tillandsias — <project> (<genus>)` |
| Escape hatches | Menu → Seedlings → OpenCode (CLI) or Claude (CLI) |

## Lifecycle

```
Attach Here ──► Container starts? ──► wait for http://127.0.0.1:P/ (exp backoff 1→2→4→8s, 30s cap)
                      │ yes: reuse          │
                      └──►──────────────────┴──► open new WebviewWindow
```

- Closing a webview window does **not** stop the container.
- Clicking Attach Here again on the same project spawns another webview against the same URL.
- Per-project tray **Stop** item (visible only when a forge container is tracked) stops the container and closes every webview whose label starts with `web-<project>-`.
- Quitting Tillandsias closes all web sessions (`close_all_web_sessions_global()`) and then runs the existing `shutdown_all()` container sweep — orphan forges matching `tillandsias-*` are caught too.

## Security invariants

- Host bind is **127.0.0.1** — asserted by unit test in `src-tauri/src/launch.rs`. A regression to `0.0.0.0` would fail tests.
- `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id` applied unconditionally via `build_podman_args()`.
- Container joins `tillandsias-enclave` network → proxy, git mirror, inference all reachable internally. External DNS stays walled off.
- Forge containers have **zero credentials** — unchanged from the existing forge-offline model.

## Collision notes

- `tillandsias-<project>-forge` (persistent forge, OpenCodeWeb) is distinct from `tillandsias-<project>-web` (static httpd, Serve Here). Different `ContainerType` variants, different entrypoints, different container names.
- Legacy genus-suffixed forge containers (`tillandsias-<project>-<genus>`) are still used when a user opts into OpenCode (CLI) or Claude from the Seedlings submenu.

## Where the pieces live

| Concern | File |
|-|-|
| Agent enum + default flip | `crates/tillandsias-core/src/config.rs` |
| `ContainerType::OpenCodeWeb` + `forge_container_name` | `crates/tillandsias-core/src/state.rs` |
| `forge_opencode_web_profile()` | `crates/tillandsias-core/src/container_profile.rs` |
| `persistent` / `web_host_port` in `LaunchContext` | `crates/tillandsias-core/src/container_profile.rs` |
| 127.0.0.1 publish + `--rm` skip | `src-tauri/src/launch.rs::build_podman_args` |
| Host-port allocator `allocate_single_port` | `crates/tillandsias-podman/src/launch.rs` |
| WebviewWindow builder + readiness probe | `src-tauri/src/webview.rs` |
| Attach branch + `handle_attach_web` / `handle_stop_project` | `src-tauri/src/handlers.rs` |
| Seedlings menu entry + per-project Stop | `src-tauri/src/menu.rs` |
| `MenuCommand::StopProject` + dispatch | `crates/tillandsias-core/src/event.rs`, `src-tauri/src/event_loop.rs` |
| Image entrypoint | `images/default/entrypoint-forge-opencode-web.sh` |

## Debugging

- "Webview is blank" → `curl -v http://127.0.0.1:<port>/` from the host. If curl works, the Tauri webview loaded too early — the readiness probe should have blocked. Check logs for `wait_for_web_ready`.
- "Can't reach from another machine" → working as designed (127.0.0.1 only). There is no LAN mode.
- "Container persists after crash" → `shutdown_all()` orphan sweep cleans `tillandsias-*-forge` on the next start; you can also run `podman ps --filter name=tillandsias- -a` and `podman rm -f` manually.
- "Linux terminal stopped working" → expected; the default path no longer spawns terminals. Switch to OpenCode (CLI) in Seedlings to exercise the terminal code path.
