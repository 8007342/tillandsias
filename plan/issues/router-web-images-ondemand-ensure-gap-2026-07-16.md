# Router/web images missing from on-demand ensure on the publish path (2026-07-16)

- **Type**: enhancement (bug-shaped; --init-on-demand coverage gap)
- **Filed by**: linux-tlatoani-claude-20260715T2107Z
- **Status**: open — evidence live, fix shaped
- **Related**: web-share-release-milestone (order 373); operator goal "make
  sure --init on demand works when launching containers or login flows"

## Live repro (fresh v0.3.260716.3 binary, tray-served publish_local)

1. `publish_local {"category":"WEB"}` for `visual-chess` over mcp.sock.
2. Proxy ensure SELF-HEALED: `tillandsias-proxy:v0.3.260716.3` absent →
   built on demand → container Up. (The ensure_versioned_images seam,
   verified earlier the same night with the git image.)
3. Router launch did NOT: `starting router container` → podman run →
   image absent → podman attempted a REGISTRY PULL of
   `localhost/tillandsias-router:v0.3.260716.3` (`dial tcp [::1]:80:
   connection refused`) → 125 → stage 'router' failed. No on-demand build.
4. Also absent from `run_status_check`'s ensure list: router AND web
   (list is proxy, git, inference, chromium-core, chromium-framework,
   forge — main.rs run_status_check).

## Additional same-night evidence (order-314 class, distinct bug)

Version-bumped binary vs live older-version infra: proxy ensure collided
with the still-running v0.3.260716.1 proxy mid-stop (`run --name` without
--replace → 125 name-in-use), then router likewise with the running .1
router. Same family as the windows-filed
`forge-maintenance-session-name-collision` packet — that packet's scope
should cover ALL shared-stack ensure surfaces (proxy/router/vault), not
just the maintenance lane: bare `run --name` + stop-race = collision on
every version handover.

## Shaped fix (smallest)

1. Add `router` and `web` to the on-demand ensure surfaces: the publish
   path (`ensure_service_catalog` / router start) calls
   `ensure_image_exists` before `run`, and `run_status_check`'s images
   array gains both. Verifiable: delete
   `tillandsias-router:v<current>` + `tillandsias-web:v<current>`, run
   publish_local → both build on demand → URL serves (no registry pull
   attempt in the launch events).
2. `--replace` (or stop+wait+rm) on shared-stack ensure runs — fold into
   the existing forge-maintenance-session-name-collision packet as
   extended scope with this repro.
