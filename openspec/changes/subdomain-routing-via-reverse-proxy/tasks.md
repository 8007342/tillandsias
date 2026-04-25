# tasks

## Phase 1 — agent instructions + spec (this commit)

- [x] Spec proposal + delta specs.
- [x] `images/default/config-overlay/opencode/instructions/web-services.md`.
- [x] Wire instruction file into `opencode/config.json` instructions list.
- [x] Embed in `src-tauri/src/embedded.rs` (const + write call).

## Phase 2 — router container + Squid forward

- [x] `images/router/Containerfile` based on Caddy 2.x.
- [x] `images/router/base.Caddyfile` with default 404 + remote_ip allowlist.
- [x] `images/router/entrypoint.sh` merging base + dynamic Caddyfiles.
- [x] `images/router/router-reload.sh` for `caddy reload` after dynamic edits.
- [x] `crates/tillandsias-core/src/container_profile.rs`: `router_profile()`.
- [x] `src-tauri/src/handlers.rs`: `ensure_router_running()` + `stop_router()`.
- [x] Bind-mount the dynamic Caddyfile at `/run/router/dynamic.Caddyfile`.
- [x] Squid `squid.conf` adds `acl localhost_subdomain dstdomain .localhost`,
      `cache_peer router parent 80 0`, `never_direct`, `http_access`.
- [x] Host-side bind `127.0.0.1:80` only — never `0.0.0.0:80`.
- [x] Wire into `ensure_infrastructure_ready` (after proxy) and `shutdown_all`.
- [x] `scripts/build-image.sh` recognises `router` image name.
- [x] Embed router source files in `src-tauri/src/embedded.rs`.
- [x] Smoke-tested locally: 404 on unknown hosts, dynamic route injection
      + `caddy reload` produces 200 on the new route.

## Phase 3 — service-specific port conventions (follow-up)

- [ ] OpenCode Web migrates URL to `<project>.opencode.localhost`.
- [ ] Flutter web instruction wires `--web-hostname 0.0.0.0 --web-port 8080`.
- [ ] Vite/Next/Storybook/Jupyter/Streamlit instructions added.

## Phase 4 — legacy URL removal (follow-up)

- [ ] Remove the random-port `<project>.localhost:<port>` browser launch.
- [ ] Migrate `opencode-web-session` spec to require the new URL exclusively.
