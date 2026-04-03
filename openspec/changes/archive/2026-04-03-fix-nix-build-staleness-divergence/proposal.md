## Why

The `_compute_hash()` function in `build-image.sh` uses `find` to traverse image source directories, which sees all working tree files including untracked ones. But Nix flake builds only see git-tracked files. This divergence means: (1) staleness check triggers on untracked files that Nix ignores, causing unnecessary rebuilds, and (2) staleness check can report "up to date" while Nix is missing newly created but unstaged files, producing silently wrong images.

## What Changes

- Replace `find` with `git ls-files` in `_compute_hash()` so the staleness check sees exactly what Nix sees
- Add a pre-build check that warns if untracked files exist in image source directories
- Fail early with a clear error if untracked files are detected (preventable mistake, not a silent degradation)

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `nix-builder`: Replace "Git-tracked files for flake builds" requirement — instead of documenting the divergence as a known limitation, require that the staleness check uses the git index to match Nix's view

## Impact

- `scripts/build-image.sh` — `_compute_hash()` function rewritten to use `git ls-files`
- No Rust code changes — the embedded source extraction path is unaffected (it always uses compile-time constants)
- No flake.nix changes
