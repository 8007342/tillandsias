# Packet 357: Web Publish Local MVP

## Implementation Details

- Created `crates/tillandsias-headless/src/main.rs` functions: `publish_local_service`, `service_status`, `service_stop`.
- `publish_local_service` starts the `tillandsias-web` container using Podman with the worktree bind-mounted at `/var/www` as read-only.
- Added dynamic Caddy routing configuration by appending `RouterRoute` with `public = true` to allow access via `https://www.<project>.localhost`.
- Implemented `McpFrame` handling in `crates/tillandsias-headless/src/tray/mod.rs` to receive MCP tool calls (`publish_local_service`, `service_status`, `service_stop`) over the control socket.
- Ensured idempotency by stopping and removing the existing container and routes before recreating them.
- Implemented `ensure_service_catalog` in `container_deps.rs` for dependency tracking.
- Resolved module visibility and cross-platform conditional compilation gating (`#[cfg(feature = "tray")]`).
- Successfully built `images/web` (Alpine + busybox httpd) and verified functionality.
- Verified build and static analysis using `./build.sh --check`.
