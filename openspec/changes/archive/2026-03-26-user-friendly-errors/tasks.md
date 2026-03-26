## 1. Audit developer-facing error strings

- [x] 1.1 Review `src-tauri/src/handlers.rs` for all `Err()` strings containing image tags, script names, exit codes, or internal paths
- [x] 1.2 Review `src-tauri/src/runner.rs` for developer-facing `eprintln!` in image-not-found path
- [x] 1.3 Review `src-tauri/src/init.rs` for build failure error string

## 2. Sanitize handlers.rs

- [x] 2.1 `run_build_image_script` — replace "Failed to run build-image.sh: {e}" with setup failure message
- [x] 2.2 `run_build_image_script` — replace "build-image.sh failed (exit {code})" with setup failure message
- [x] 2.3 `handle_attach_here` — replace "Image {tag} still not found after build-image.sh completed" with environment-not-ready message
- [x] 2.4 `handle_attach_here` — replace "Failed to build image {tag}: {e}" with setup failure message
- [x] 2.5 `handle_attach_here` — replace "Image build task panicked: {e}" with setup failure message
- [x] 2.6 `handle_terminal` — replace "Forge image not found. Run ./build.sh --install first." with environment-not-ready message
- [x] 2.7 `handle_github_login` — replace "Failed to extract gh-auth-login.sh: {e}" with installation-incomplete message

## 3. Sanitize runner.rs

- [x] 3.1 CLI image-not-found path — replace `"Image {} not found. Run: ./build.sh --install"` with environment-not-ready message
- [x] 3.2 `run_build_image_script` — replace "Failed to run build-image.sh: {e}" with setup failure message
- [x] 3.3 `run_build_image_script` — replace "build-image.sh exited with code {code}" with setup failure message

## 4. Sanitize init.rs

- [x] 4.1 `build_forge_image` — replace "Failed to run build-image.sh: {e}" with setup failure message
- [x] 4.2 `build_forge_image` — replace "build-image.sh exited with code {code}" with setup failure message

## 5. Verification

- [x] 5.1 `./build.sh --check` passes with no type errors
