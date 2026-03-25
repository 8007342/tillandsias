## Tasks

- [ ] 1. Add `--appimage` flag parsing to `build.sh` (alongside existing `--release`, `--test`, etc.)
- [ ] 2. Add `build_appimage()` function in `build.sh` that:
  - Creates output dir `target/release/bundle/appimage/`
  - Creates cargo cache dir `~/.cache/tillandsias/cargo-registry/`
  - Runs `podman run --rm --device /dev/fuse` with `ubuntu:22.04`
  - Mounts project source as `/src:ro` (or `:Z` for SELinux)
  - Mounts cargo cache as `/root/.cargo/registry:rw`
  - Mounts output dir for AppImage extraction
- [ ] 3. Inside the container: install system deps (build-essential, pkg-config, libgtk-3-dev, libwebkit2gtk-4.1-dev, libappindicator3-dev, librsvg2-dev, libssl-dev, fuse, libfuse2)
- [ ] 4. Inside the container: install rustup + stable toolchain + `cargo install tauri-cli`
- [ ] 5. Inside the container: copy source from /src to a writable build dir, run `cargo tauri build`
- [ ] 6. Inside the container: copy `*.AppImage` from `target/release/bundle/appimage/` to the mounted output dir
- [ ] 7. Print the output path on success: `target/release/bundle/appimage/Tillandsias-linux-x86_64.AppImage`
- [ ] 8. Test: run `./build.sh --appimage` on Silverblue, verify the AppImage is created and executable
