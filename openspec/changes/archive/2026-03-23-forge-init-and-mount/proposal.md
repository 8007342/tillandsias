## Why

The forge entrypoint installs OpenCode and OpenSpec every run because npm globals go to the read-only Nix store and OpenSpec isn't cached. Also, projects mount at `/home/forge/src` flat instead of `/home/forge/src/<project>/`, breaking OpenCode's status bar which should show `src/<project>:main`.

## What Changes

- Entrypoint becomes an idempotent init wrapper: install/upgrade OpenCode and OpenSpec to persistent cache, skip if already present
- OpenSpec installed to cache via `npm install --prefix` (avoids read-only Nix global prefix)
- Mount path changes: `~/src/<project>` → `/home/forge/src/<project>` (preserves hierarchy)
- Working directory set to `/home/forge/src/<project>` so OpenCode shows correct path

## Capabilities

### Modified Capabilities
- `default-image`: Idempotent init wrapper, cached tooling
- `environment-runtime`: Mount at correct hierarchy path
- `podman-orchestration`: Mount path includes project name

## Impact

- Modified: `images/default/entrypoint.sh` — idempotent init with cached installs
- Modified: `src-tauri/src/handlers.rs` — mount path includes project name
- Modified: `src-tauri/src/runner.rs` — mount path includes project name
