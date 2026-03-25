## Decisions

### D1: Build AppImage inside a podman Ubuntu container

Instead of manually assembling an AppDir (fragile, duplicates Tauri's bundler logic), spin up a disposable `ubuntu:22.04` container with FUSE support and run the full `cargo tauri build` inside it. This produces the same AppImage as CI.

### D2: Container build flow

```
./build.sh --appimage
    │
    ├── podman run --rm -it --device /dev/fuse ubuntu:22.04
    │   ├── Install: curl, build-essential, pkg-config, libgtk-3-dev,
    │   │           libwebkit2gtk-4.1-dev, libappindicator3-dev,
    │   │           librsvg2-dev, libssl-dev, fuse, libfuse2
    │   ├── Install: rustup, cargo, tauri-cli
    │   ├── Mount: project source as /src (read-only)
    │   ├── Mount: cargo registry cache (read-write, speeds up rebuilds)
    │   ├── cargo tauri build  (produces AppImage with Tauri's linuxdeploy)
    │   └── Copy AppImage to mounted output dir
    │
    └── Output: target/release/bundle/appimage/Tillandsias-linux-x86_64.AppImage
```

### D3: --appimage is a standalone flag, not combined with --release

Since the build happens inside a separate container (not the toolbox), it's a self-contained operation. `--appimage` does NOT require prior `--release` — it handles everything internally.

### D4: Cache cargo registry across builds

Mount `~/.cache/tillandsias/cargo-registry/` into the Ubuntu container as the cargo registry. First build is slow (downloads all deps), subsequent builds reuse the cache.

### D5: --device /dev/fuse for FUSE access

The Ubuntu container needs `--device /dev/fuse` to allow linuxdeploy to create AppImages. This works even on Silverblue because podman has access to `/dev/fuse` on the host.
