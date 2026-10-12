## Why

On 2026-10-12 the operator asked a cold-start forge, with no other context, to
"start this [web] project and serve it locally" (project `visual-chess`, a
Wrangler + wasm app). The forge agent took the sanctioned path,
`host-browser publish_local`, and was stopped on every runtime profile.

- `auto` and `wrangler` refused with "initialize the managed runtime image
  before publication". Nothing in the product ever builds that image, and the
  agent cannot either.
- `static` failed with "Podman operation failed", which names no step.
- `service_status` said nothing.
- The forge also could not build a wasm project (no `wasm32-unknown-unknown`
  target).
- `gh` failed with a misleading "permission denied" from a root-owned
  quarantine directory.

Evidence and the trunk verification:
`plan/issues/research/forge-web-preview-cold-start-2026-10-12.md`, packets
1625-un54, 1625-6iwd, 1625-bax2, 1625-grk8 and 1625-9qyw.

## What Changes

- ADDED `local-web-preview`: managed runtime images materialize host-side
  without any agent action. A publish never refuses with a step that only an
  operator could perform.
- ADDED `local-web-preview`: publish failures carry a stable step-qualified
  reason, and status reports the last failure. Raw podman output stays
  withheld.
- ADDED `local-web-preview`: cold-start acceptance. "Serve this web project
  locally" reaches a browser-loadable URL with no operator action.
- MODIFIED `forge-offline` "Forge containers have no credential mounts":
  `~/.config/gh` and `~/.ssh` exist as EMPTY forge-owned quarantine
  directories, consistent with `default-image`. `gh` reports "not logged in".
  Upstream findings leave the forge as a `research/` branch pushed through
  the mirror.
- ADDED `default-image`: the forge can build `wasm32-unknown-unknown`
  projects with its system toolchain.

## Impact

- `crates/tillandsias-headless/src/main.rs` (INIT_IMAGES, image_specs, forge
  quarantine tmpfs options)
- `crates/tillandsias-headless/src/local_web_preview.rs` (image ensure, step
  reasons, last-failure status)
- `images/default/` (wasm32 target std; forge instructions on research
  branches)
- `openspec/litmus-tests/` (cold-start acceptance litmus, 1625-9qyw)

Non-goal: project-specific egress, e.g. `tests.stockfishchess.org`. The
allowlist is unchanged; projects use their own reachable mirrors.
