# Design: fix-windows-image-routing

## Root cause

`src-tauri/src/handlers.rs` (~line 2099-2148, `#[cfg(target_os = "windows")]` branch of `run_build_image_script`):

```rust
let containerfile = source_dir.join("images").join("default").join("Containerfile");
let context_dir = source_dir.join("images").join("default");
```

These two lines run for every value of `image_name`. The tag computed above (`proxy_image_tag()`, `git_image_tag()`, etc.) is correct, so podman happily creates a tag pointing at whatever the forge build produces. There is no error, no warning — just four tags on the same image ID.

The Linux/macOS branch shells out to `scripts/build-image.sh`, which has the right `case` statement (lines 130–144 of build-image.sh). The Windows fix is to mirror that `case` in Rust.

## Approach

Introduce a private helper:

```rust
fn image_build_paths(source_dir: &Path, image_name: &str) -> (PathBuf, PathBuf) {
    let subdir = match image_name {
        "proxy" => "proxy",
        "git" => "git",
        "inference" => "inference",
        "web" => "web",
        _ => "default", // forge falls through here
    };
    let dir = source_dir.join("images").join(subdir);
    (dir.join("Containerfile"), dir)
}
```

Use it in the Windows branch instead of the hardcoded `default` paths. Same helper can be lifted to a shared call site when Phase 2 of `direct-podman-calls` unifies the platforms — that change is the natural home for the helper to graduate to a reusable spot.

## Embedded sources verification

`crate::embedded::write_image_sources()` extracts a temp directory containing all five image subdirectories. Verify by reading `src-tauri/src/embedded.rs` to confirm the proxy/git/inference Containerfiles + entrypoints are actually included in the binary. If they are missing, fix `embedded.rs` first or the helper still won't work — `podman build` will fail with "no such file or directory" instead of silently building the wrong image. (This is strictly better than the current silent failure but still bad.)

## Defensive integration test

Add a small Rust unit test in `handlers.rs` (or a new module) that asserts `image_build_paths` returns the expected subdirectory for each known image name. Cheap, runs in CI, and would have caught this bug when it was introduced.

Optionally, on app startup (debug builds only) emit a warning if `podman image inspect` shows the same image ID for two different `tillandsias-*` repository tags. Useful for catching this class of bug if it recurs after refactor.

## Build-number bump

The staleness check in `build-image.sh` (and any future Rust port) hashes Containerfile content + sources. The hash is the same for the wrong build as for the right one (since the `proxy` Containerfile content didn't change — what changed is which Containerfile we pass). To force a rebuild on existing Windows installs:

1. `./scripts/bump-version.sh --bump-build` so the versioned tag changes (`v0.1.157.181` instead of `v0.1.157.180`)
2. The cache hash file is keyed by tag (`HASH_SUFFIX="$(echo "$IMAGE_TAG" | tr ':/' '--')"`), so a new tag bypasses any stale cache entry
3. After the new images are built, manually `podman rmi` the old identical-ID tag set: `podman rmi localhost/tillandsias-{forge,proxy,git,inference}:v0.1.157.180`

This is documented in the Windows-setup cheatsheet.

## Out of scope

- Unifying Windows and Linux/macOS branches into a single direct-podman call — that's `direct-podman-calls` Phase 2.
- Performance work on the launch path — separate change.
- Making the inference container start async — separate change.
