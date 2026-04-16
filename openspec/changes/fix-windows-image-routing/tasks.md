# Tasks: fix-windows-image-routing

## Investigation
- [x] Confirm that all four `tillandsias-{forge,proxy,git,inference}:v0.1.157.180` tags share image ID `a440b0730aba` on Windows
- [x] Confirm root cause is the hardcoded `images/default/` path in the Windows branch of `run_build_image_script` in `src-tauri/src/handlers.rs`

## Fix
- [x] Add `fn image_build_paths(source_dir, image_name) -> (PathBuf, PathBuf)` helper in `src-tauri/src/handlers.rs`
- [x] Replace the two hardcoded `images/default/` paths in the Windows `#[cfg(target_os = "windows")]` block with calls to the helper
- [x] Confirm `crate::embedded::write_image_sources()` extracts proxy/git/inference Containerfiles + entrypoints (read `src-tauri/src/embedded.rs`)
- [x] Add `// @trace spec:default-image, spec:fix-windows-image-routing` comments at the helper and at the call site

## Defensive guard
- [x] Unit test for `image_build_paths` covering forge/proxy/git/inference/web/unknown
- [ ] (Optional, debug-only) On startup, run `podman image inspect` over the four enclave tags and warn if any two share an ID, with `spec = "default-image, fix-windows-image-routing"` log field

## Build + verify
- [x] `./scripts/bump-version.sh --bump-build` to invalidate stale cache + tag new builds distinctly (bumped to 0.1.157.181)
- [x] Wipe stale podman tags: `podman rmi localhost/tillandsias-{forge,proxy,git,inference}:v0.1.157.180` (these all point at the same image)
- [x] Build locally: `./build-local.sh` (also fixed the script — package was renamed `tillandsias-tray` → `tillandsias`)
- [x] Verify each enclave image now has a distinct image ID via `podman image ls` — confirmed: 4705bbb6ecaf forge / 98231ceae962 proxy / ff08a13fe6a1 git / ae0b5a57cc27 inference
- [x] Verify the proxy image has squid installed — Squid Cache: Version 6.9
- [x] Verify the git image has git-daemon — `/usr/libexec/git-core/git-daemon`
- [x] Verify the inference image has ollama — `/usr/local/bin/ollama` v0.20.7

## Cheatsheet
- [x] Update `docs/cheatsheets/windows-setup.md` with the `podman rmi` recovery command for users who installed v0.1.157.180 or earlier on Windows

## Trace + commit
- [ ] Commit message body includes `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Afix-windows-image-routing&type=code`
- [x] OpenSpec validate: `npx openspec validate fix-windows-image-routing` — valid
