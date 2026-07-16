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

## Addendum: embedded-assets staleness on image rebuilds (same night)

`--init --force` rebuilt all 10 images but from the BINARY's embedded
runtime assets — which predate any checkout edits made after the binary
was installed. Fix flow for overlay/entrypoint changes is therefore:
(a) `./build.sh --install` (re-embeds assets, bumps VERSION, needs new
images anyway), or (b) developer override `TILLANDSIAS_ROOT=<checkout>
tillandsias --init --force` (used tonight to deliver the Claude
bypass-permissions gate + cross-harness web awareness without another
VERSION hop). Also confirmed: the digest sentinel skips rebuilds on
overlay content changes entirely (`SKIP forge (digest present)`), so
without --force NOTHING invalidates — the containerfile-staleness spec
covers Containerfile mtime and (order 341) skills, but not
entrypoint/lib-common/config-overlay content. Shaped reduction: content
digest over the build CONTEXT (not just Containerfile) as the sentinel
input.

## Addendum 2: TILLANDSIAS_ROOT override is unusable with --init (spec-vs-code contradiction)

`TILLANDSIAS_ROOT=<checkout> tillandsias --init --force` fails
`require_desktop_user_session` because `current_runtime_lane()`
(crates/tillandsias-podman/src/lib.rs) classifies ANY process with
TILLANDSIAS_ROOT set as RuntimeLane::HeadlessServiceAccount — while
spec:init-command explicitly promises "TILLANDSIAS_ROOT SHALL remain
available as an explicit developer override" for exactly this command.
One of them must change; shaped fix: the service-account lane needs its
own dedicated marker (e.g. TILLANDSIAS_SERVICE_LANE=1) instead of
overloading the developer override; the spec's litmus should pin that a
desktop `TILLANDSIAS_ROOT=… --init` run reaches the build phase.
Workaround tonight: full ./build.sh --install to re-embed assets (one
more VERSION hop).

## RESOLVED (2026-07-16T10:15Z, linux coordinator cycle 6b)

Shaped fix 1 implemented: ensure_router_running builds the router image
on demand before starting (block_in_place + ensure_image_exists;
verified live — the publish_local unit test built v0.3.260716.6 mid-run
and passed), and run_status_check's ensure array gains router + web.
Bonus root-cause in the same commit: vault_bootstrap's tokio_runtime()
was a raw current-thread Runtime that panicked from async contexts
(publish → catalog → Service::Vault); now delegates to RuntimeOrHandle.
Residual: publish's web container uses the :latest tag (versioned-web
litmus stays open with fix 2 / the collision packet).
