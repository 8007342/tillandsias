# tasks

## Phase 1 — agent instructions + spec (this commit)

- [x] Spec proposal + delta specs.
- [x] `images/default/config-overlay/opencode/instructions/web-services.md`.
- [x] Wire instruction file into `opencode/config.json` instructions list.
- [x] Embed in `src-tauri/src/embedded.rs` (const + write call).

## Phase 2 — router container + Squid forward (follow-up)

- [ ] `images/router/Containerfile` based on Caddy 2.x.
- [ ] `images/router/Caddyfile.template` with `*.<service>.localhost` patterns.
- [ ] `crates/tillandsias-core/src/container_profile.rs`: `router_profile()`.
- [ ] `src-tauri/src/handlers.rs`: `ensure_router_running()` analogous to proxy.
- [ ] `crate::router::regenerate_caddyfile()` called on each attach.
- [ ] Squid `allowlist.txt` adds `.localhost`; `squid.conf` adds `cache_peer router parent 80 0`.
- [ ] Host-side bind `127.0.0.1:80` only — assert never `0.0.0.0:80`.

## Phase 3 — service-specific port conventions (follow-up)

- [ ] OpenCode Web migrates URL to `<project>.opencode.localhost`.
- [ ] Flutter web instruction wires `--web-hostname 0.0.0.0 --web-port 8080`.
- [ ] Vite/Next/Storybook/Jupyter/Streamlit instructions added.

## Phase 4 — legacy URL removal (follow-up)

- [ ] Remove the random-port `<project>.localhost:<port>` browser launch.
- [ ] Migrate `opencode-web-session` spec to require the new URL exclusively.
