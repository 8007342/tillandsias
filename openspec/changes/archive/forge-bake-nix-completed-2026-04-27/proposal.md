## Why

Per the user's directive: "make sure nix tools are available in the forge. We will recommend in the methodology that any new projects SHOULD be built using nix tools." Plus `forge-cache-architecture` chose nix as the single shared-cache entry point — that only works if nix is actually present in the forge.

## What Changes

- **MODIFIED** Containerfile installs `nix` (single-user mode — forge has no daemon access), `direnv`, `nix-direnv`. Configures `/etc/nix/nix.conf` with `experimental-features = nix-command flakes`.
- **NEW** Forge entrypoint sets `NIX_CONFIG` and `NIX_PATH` so flakes work out of the box.
- **NEW** Direnv shell hooks added to `bashrc` / `zshrc` / `config.fish` (in `images/default/shell/`) so `.envrc` auto-activates on `cd`.
- The shared `/nix/store/` mount (already added by `forge-cache-architecture`) is what nix reads from. New flake builds populate it host-side.
- **NEW** Cheatsheet `cheatsheets/build/nix-flake-basics.md` (already shipped with the v2 sweep; no DRAFT).
- **MODIFIED** Project + workspace `CLAUDE.md` gain "Nix-First for New Projects" section under the existing methodology.

## Capabilities

### New Capabilities
- `forge-nix-toolchain` — nix + direnv + nix-direnv baked, store mounted.

### Modified Capabilities
- `default-image`: nix layer added (~50 MB).
- `forge-shell-tools`: shell configs include direnv hook.
- `forge-opencode-onboarding`: nix-first.md instruction (depends on `forge-opencode-methodology-overhaul`).

## Impact

- Containerfile +1 layer (nix + direnv + nix-direnv via curl-style installer or Fedora repo if available).
- `/etc/nix/nix.conf` baked.
- `bashrc`/`zshrc`/`config.fish` get one-line direnv hook.
- Image grows ~50 MB.
- Depends on `forge-cache-architecture` (already shipped) for the `/nix/store/` mount.

## Sources of Truth

- `cheatsheets/build/nix-flake-basics.md` — flake authoring (provenance: nix.dev + nixos.org manual + nix-direnv repo).
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — why nix is the right shared-cache entry.
