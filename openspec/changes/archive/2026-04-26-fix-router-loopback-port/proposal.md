## Why

The router container is published at `127.0.0.1:80:80` (`src-tauri/src/handlers.rs:902`). Rootless podman cannot bind ports below `net.ipv4.ip_unprivileged_port_start` (default `1024` on Fedora and most distros), so the router's port-80 publish silently fails when the tray runs as a non-privileged user. The browser opens `http://<project>.opencode.localhost/` (port 80 implicit), nothing is listening, and the user sees `ERR_CONNECTION_REFUSED`.

Verified live on the user's machine just now: `sysctl net.ipv4.ip_unprivileged_port_start = 1024`. The router container does not start; consequently `~/.cache/tillandsias/router/` is never created and no Caddy listener exists.

## What Changes

- **BREAKING** Router publish changes from `127.0.0.1:80:80` to `127.0.0.1:8080:80`. Browser-facing URL changes from `http://<project>.opencode.localhost/` to `http://<project>.opencode.localhost:8080/`. The internal Caddy listener stays on `:80` inside the container — only the host-side publish moves.
- `src-tauri/src/browser.rs::build_subdomain_url` returns the new URL with the explicit port.
- `src-tauri/src/handlers.rs::ensure_router_running` publishes `127.0.0.1:8080:80`.
- Health-probe inside the router (`handlers.rs:922-947`) is unchanged — it execs into the container and uses container-internal `127.0.0.1`, not host loopback.
- Tests, cheatsheets, and the `subdomain-routing-via-reverse-proxy` spec updated to reflect the port suffix.

**Considered and rejected**: lowering the host's `ip_unprivileged_port_start` sysctl. Requires root, doesn't survive distro updates cleanly, and violates the "AJ should never need to configure anything" principle.

**Considered and rejected**: rolling back to the per-project port-published `http://<project>.localhost:<port>/<base64dir>/` form. Loses the clean subdomain URL; `<port>` and base64 path segment are ugly. The `:8080` suffix is the smallest user-visible change that makes attach work.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `subdomain-routing-via-reverse-proxy`: router host-side publish moves from `:80` to `:8080`; URLs handed to the browser carry the explicit `:8080` port.

## Impact

- `src-tauri/src/handlers.rs:898-903` — change the publish line.
- `src-tauri/src/browser.rs:163-166` — change the URL builder.
- Existing tests in `src-tauri/src/browser.rs::tests` (`build_subdomain_url_no_ip_no_bare_localhost_no_port`) assert the URL has no port — invert that assertion to require `:8080`.
- `docs/cheatsheets/tray-state-machine.md` — update any URL references.
- No spec change to `tray-app` (the menu doesn't render the URL); only `subdomain-routing-via-reverse-proxy` changes.
- Forge image, locale files, agent paths — all unchanged.
- Manual UX impact: power users typing the URL directly need the `:8080`. Tray-launched browser windows get the right URL automatically.

## Sources of Truth

- `cheatsheets/runtime/networking.md` — enclave network and proxy semantics; this fix is consistent with the existing in-enclave routing model.
- `cheatsheets/runtime/forge-container.md` — confirms forge cannot bind low ports as the unprivileged forge user; same rule applies to the router.
