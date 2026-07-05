# Impl: install the agent harnesses fresh EVERY_LAUNCH (always latest) — 2026-07-04

- class: enhancement (forge image)
- filed: 2026-07-04
- owner: linux
- status: pending (blocked on persistence prereq)
- depends_on: forge-persistent-tool-cache-mount-2026-07-04.md
- trace: spec:default-image, spec:codex-tray-launcher

## Why

`Containerfile.base` npm-pins the harnesses at BUILD:
`@openai/codex@0.137.0`, `@anthropic-ai/claude-code@2.1.168`, `opencode-ai@1.16.2`,
plus the Antigravity CLI via a `curl … | bash` (currently DUPLICATED in the WIP
tree). Result: a FRESH forge reports "newer version available" for Codex/Claude —
which shouldn't happen. The operator wants the harnesses themselves reinstalled
fresh on EVERY launch so a fresh forge always runs latest.

## Scope

- Remove the harness npm-pins + the Antigravity curl block(s) from
  `Containerfile.base` (and collapse the accidental Antigravity duplication).
- Add an EVERY_LAUNCH step in the forge entrypoint (lib-common) that, per launch:
  - `npm install -g @openai/codex @anthropic-ai/claude-code opencode-ai` (latest)
    into the persistent `$NPM_CONFIG_PREFIX` (so the download is cached but the
    version check runs each launch and upgrades when a newer one exists), and
  - installs/updates the Antigravity CLI via its supported install path.
- Egress: these go through the enclave proxy (NODE_USE_ENV_PROXY already routes
  npm/node through it — order 175); confirm the npm registry + antigravity host
  are allowlisted (proxy). File an allowlist delta if `npm install` hits a denied
  host.
- Keep it FAST + resilient: if the registry is unreachable this launch, fall back
  to the cached version already in `$NPM_CONFIG_PREFIX` (do NOT fail the launch).

## Decision to record
Whether `every-launch` means "npm install -g each launch" (npm dedupes/short-
circuits when already-latest — cheap) or "npx@latest at exec". Prefer
`npm install -g` into the persistent prefix: one cached copy, upgraded in place,
launch still works offline from cache.

## Exit criteria
- No harness version pinned in the Containerfile; Antigravity dedup removed.
- A fresh forge (post cache-refresh) runs the latest published harness versions;
  "newer version available" no longer appears on a fresh forge.
- Offline/registry-denied launch still starts using the cached harness (no hard
  failure).
- Litmus: the forge entrypoint contains the every-launch harness update step
  gated to route through the proxy; `./build.sh --check` passes.
