## Why

Disk usage from Tillandsias artifacts accumulates silently. Podman images (forge, macuahuitl), dangling build layers, stopped containers, Nix build outputs, and Cargo registry caches can grow to several gigabytes without any visibility. Users have no way to inspect or reclaim this space without knowing internal paths and commands.

## What Changes

- **`--stats` CLI flag** — Print a human-readable disk usage report: podman images matching `tillandsias-*` or `macuahuitl*`, running/stopped containers matching `tillandsias-*`, Nix store cache, Cargo registry cache, installed binary size, and a total.
- **`--clean` CLI flag** — Remove reclaimed artifacts: dangling podman images (`podman image prune -f`), stopped tillandsias containers, and the Nix store cache under `~/.cache/tillandsias/nix/`. Prints what was removed and estimated space recovered.
- **`build.sh` image prune** — After every successful build, run `podman image prune -f` to prevent dangling layer accumulation.

## Capabilities

### New Capabilities
- `app-cleanup-flags`: `--stats` and `--clean` CLI subcommands for disk inspection and reclamation

### Modified Capabilities
(none)

## Impact

- **New files**: `src-tauri/src/cleanup.rs`
- **Modified files**: `src-tauri/src/cli.rs` (two new `CliMode` variants), `src-tauri/src/main.rs` (early dispatch for new modes), `build.sh` (prune after builds)
