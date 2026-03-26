## 1. Rewrite build-image.sh to use podman run

- [x] 1.1 Replace `toolbox run -c tillandsias-builder` with `podman run --rm nixos/nix:latest` for the nix build step
- [x] 1.2 Mount source directory read-only at `/src` and output directory at `/output`
- [x] 1.3 Enable flakes via `--extra-experimental-features "nix-command flakes"`
- [x] 1.4 Copy the nix build tarball to `/output/result.tar.gz` inside the container
- [x] 1.5 Replace `toolbox run ... cat` tarball pipe with direct `podman load` from output directory
- [x] 1.6 Remove the `ensure-builder.sh` call and `BUILDER_TOOLBOX` variable

## 2. Remove ensure-builder.sh

- [x] 2.1 Delete `scripts/ensure-builder.sh`

## 3. Update embedded.rs

- [x] 3.1 Remove `ENSURE_BUILDER` constant and its `include_str!`
- [x] 3.2 Remove `ensure-builder.sh` from the `write_image_sources()` directory layout
- [x] 3.3 Remove the `ensure-builder.sh` permission setting
- [x] 3.4 Update the doc comment showing the temp directory tree

## 4. Update uninstall.sh

- [x] 4.1 Remove the `toolbox rm -f tillandsias-builder` line from the wipe section

## 5. Verify

- [x] 5.1 Run `cargo check --workspace` -- zero errors
- [x] 5.2 Run `cargo test --workspace` -- all 65 tests pass
