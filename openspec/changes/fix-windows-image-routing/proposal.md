# Change: fix-windows-image-routing

## Why

On Windows, `run_build_image_script()` in `src-tauri/src/handlers.rs` hardcodes the build context to `images/default/Containerfile` regardless of which image is requested (`forge`, `proxy`, `git`, `inference`). The function correctly computes a versioned tag per image type, but it then runs `podman build` against the forge sources for every call. The result on a fresh Windows install is four image names (`tillandsias-forge`, `tillandsias-proxy`, `tillandsias-git`, `tillandsias-inference`) all pointing at the same image ID — literally the forge image with four tags.

This is invisible until the user clicks "Attach Here" and the launch path tries to start a real proxy or git mirror: it pulls the forge image, runs the forge entrypoint, and either crashes (wrong entrypoint, wrong USER, missing squid binary) or appears to start but does nothing useful. The Linux/macOS path is unaffected because it shells out to `build-image.sh`, which has a `case` that selects the correct `images/<name>/Containerfile`.

This blocks the Windows enclave bring-up entirely. No amount of runner/launch fixes will work until the right images exist.

## What Changes

- Route the Windows direct-podman build branch by `image_name` (matching the existing Linux/macOS logic in `build-image.sh`):
  - `forge` → `images/default/Containerfile` + `images/default/`
  - `proxy` → `images/proxy/Containerfile` + `images/proxy/`
  - `git` → `images/git/Containerfile` + `images/git/`
  - `inference` → `images/inference/Containerfile` + `images/inference/`
  - `web` → `images/web/Containerfile` + `images/web/`
- Add a small `image_build_paths(image_name) -> (Containerfile, context_dir)` helper so the routing lives in one place and is reused if/when the unified Phase-2 path from `direct-podman-calls` lands.
- Add a defensive integration test or a startup self-check that flags duplicate image IDs across `tillandsias-{forge,proxy,git,inference}` tags so this class of bug surfaces immediately next time.
- Bump the build number after the fix so existing Windows installs pick up freshly-built images via the staleness check.

## Capabilities

### Modified Capabilities
- `default-image`: image build routing now respects `image_name` on Windows (was: hardcoded to forge sources).
- `proxy-container`: the proxy image actually contains squid + the proxy entrypoint on Windows, not the forge entrypoint.
- `git-mirror-service`: the git image actually contains git-daemon + the git entrypoint on Windows.
- `inference-container`: the inference image actually contains ollama + the inference entrypoint on Windows.

### New Capabilities
None — this is a defect fix.
