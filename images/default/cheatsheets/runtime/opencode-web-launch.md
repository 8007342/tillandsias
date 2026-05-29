---
tags: [opencode, chromium, router, tray, readiness]
languages: [bash, rust]
since: 2026-05-19
last_verified: 2026-05-20
sources:
  - https://opencode.dev/
  - https://caddyserver.com/docs/caddyfile/directives/forward_auth
  - https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# OpenCode Web Launch

Use this when changing `tillandsias --opencode-web`, the tray OpenCode Web
action, router auth, or the isolated Chromium app window.

## Current Contract

- Forge web container serves OpenCode through `sse-keepalive-proxy.js` on
  `0.0.0.0:4096`; raw `opencode serve` is the loopback upstream on `4097`.
- Browser URL is `http://opencode.<project>.localhost[:port]/`, where the
  port is the router host port selected by the launcher.
- No-cookie route probe must return `401`; this proves Caddy and the sidecar
  auth gate are wired.
- Registered-cookie route probe must return `2xx` or `3xx`; this proves the
  route reaches OpenCode Web before Chromium opens.
- The browser runs in `tillandsias-chromium-framework:v<VERSION>` through the
  typed Podman launch profile, not Tauri and not the daily host browser.
- Git identity comes from GitHub Login's cached
  `~/.cache/tillandsias/secrets/git/.gitconfig`; the launcher injects
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*`, and the entrypoint writes repo-local
  `user.name`/`user.email`.
- Project bind mounts are protected with `TILLANDSIAS_PROJECT_HOST_MOUNT=1`.
  Forge entrypoints must use `/home/forge/src/<project>` in place and must
  never wipe or clone over that path.
- Stack containers rely on Podman DNS aliases and dynamic IPAM. Do not add
  hard-coded `--ip 10.0.42.x` launch args.
- Debug launches emit `event:container_launch stage=... state=...` lines plus
  an initial `[tillandsias] version: ...` line for log correlation.

## Common Fixes

- White/light UI usually means the web entrypoint skipped
  `apply_opencode_config_overlay` or bypassed `sse-keepalive-proxy.js`.
- Wrong or unselected project usually means `TILLANDSIAS_PROJECT` was not set,
  the project was not mounted at `/home/forge/src/<project>`, or the entrypoint
  did not `cd` into `PROJECT_DIR`.
- `git commit` complaining about unknown author usually means the host launch
  argv did not propagate GitHub Login identity or the entrypoint did not run
  `configure_git_identity` after entering the project directory.
- Unauthorized landing page means `IssueWebSession` was not acknowledged or
  the sidecar never received the session before Chromium loaded the data URL.
- `--no-sandbox` belongs to the Chromium framework entrypoint only. The
  entrypoint probes whether the selected Chromium binary supports the switch
  before appending it. It is not a top-level `tillandsias` option.

## Verification

```bash
cargo test -p tillandsias-headless opencode_web_readiness_status_contract_is_auth_gated -- --exact
./scripts/run-litmus-test.sh opencode-web-startup-sequence
```
