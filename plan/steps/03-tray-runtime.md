# Step 03: Tray Lifecycle, Init Path, and Cache Semantics

## Status

pending

## Objective

Converge the tray menu, startup path, cache behavior, and container lifecycle around the current runtime model.

## Included Specs

- `tray-app`
- `tray-ux`
- `tray-minimal-ux`
- `tray-progress-and-icon-states`
- `tray-icon-lifecycle`
- `tray-cli-coexistence`
- `tray-host-control-socket`
- `tray-projects-rename`
- `simplified-tray-ux`
- `no-terminal-flicker`
- `singleton-guard`
- `init-command`
- `init-incremental-builds`
- `forge-cache-dual`
- `forge-staleness`
- `overlay-mount-cache`
- `tools-overlay-fast-reuse`

## Deliverables

- One current tray state model, not multiple overlapping UX contracts.
- Clear status handling for lifecycle and icon changes.
- Retirement of cache/UX variants that no longer describe the live path.

## Verification

- Narrow tray litmus chain.
- `./build.sh --ci --strict --filter <tray-bundle>`
- `./build.sh --ci-full --install --strict --filter <tray-bundle>`

## Notes

- If a UI variant is purely historical, obsoleting it is preferred over preserving a fake active contract.

## Granular Tasks

- `tray/state-machine`
- `tray/icon-transitions`
- `tray/menu-layout`
- `tray/init-command`
- `tray/cache-semantics`
- `tray/legacy-cache-tombstones`

## Handoff

- Assume the next agent may be different.
- Keep progress notes cold-start readable: current branch, file scope, residual risk, checkpoint SHA, dependency tail.
- Treat repeated step updates as idempotent when the task ID and update ID match.
