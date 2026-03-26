## Why

The runtime image build pipeline (`build-image.sh` + `ensure-builder.sh`) uses `toolbox create` and `toolbox run` to manage a persistent `tillandsias-builder` toolbox containing Nix. Toolbox is Fedora-specific. Users on macOS, Windows, Ubuntu, Arch, or any non-Fedora Linux cannot run the installed Tillandsias binary because `toolbox` does not exist on their system.

This is a cross-platform blocker. The installed app must build container images on any platform where podman is available.

## What Changes

- **Rewrite `scripts/build-image.sh`** to use `podman run --rm nixos/nix:latest` as an ephemeral build container instead of `toolbox run -c tillandsias-builder`. The `nixos/nix` image has Nix pre-installed, works everywhere podman works, and requires no persistent builder state.
- **Remove `scripts/ensure-builder.sh`** — no longer needed. The `nixos/nix:latest` image IS the builder. Podman pulls it on demand.
- **Remove `ENSURE_BUILDER` embedding** from `src-tauri/src/embedded.rs` and stop writing `ensure-builder.sh` to the temp directory.
- **Update `scripts/uninstall.sh`** to remove the `toolbox rm tillandsias-builder` line.

## Capabilities

### Modified Capabilities
- `nix-builder`: Replaced toolbox-based builder with ephemeral `podman run nixos/nix:latest` container
- `embedded-scripts`: `ensure-builder.sh` removed from the embedded binary; `build-image.sh` is the only build script

### Removed Capabilities
- `ensure-builder`: The entire concept of a persistent builder toolbox is eliminated

## Impact

- **Removed file**: `scripts/ensure-builder.sh`
- **Modified files**: `scripts/build-image.sh`, `src-tauri/src/embedded.rs`, `scripts/uninstall.sh`
- **No new dependencies** — `nixos/nix:latest` is pulled by podman on first use
- **No changes to `build.sh`** — the development build script still uses toolbox as before
- **Staleness detection unchanged** — same hash-based approach, same podman load step
- **Build semantics preserved** — `nix build .#forge-image` produces the same tarball, just inside a different container runtime
