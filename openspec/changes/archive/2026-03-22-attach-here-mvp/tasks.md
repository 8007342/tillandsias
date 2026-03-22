## 1. Container Image

- [x] 1.1 Create `images/default/Containerfile` — Fedora Minimal with microdnf, git, gh, curl, jq, ripgrep, nodejs, npm, nix (single-user), OpenCode binary (glibc variant)
- [x] 1.2 Create `images/default/entrypoint.sh` — bootstrap cache dirs, deferred OpenSpec install, welcome banner, launch OpenCode as foreground process
- [x] 1.3 Create `images/default/opencode.json` — minimal OpenCode config (OpenCode provider, bash/edit/read tools enabled)
- [x] 1.4 Test image builds with `podman build -t tillandsias-forge:latest images/default/` (838MB, verified)

## 2. Podman Client: Image Build

- [x] 2.1 Add `build_image(containerfile_path, image_name, context_dir)` async method to PodmanClient
- [x] 2.2 Add `ensure_image(image_name, containerfile_path, context_dir)` — builds only if image doesn't exist

## 3. Attach Here Handler

- [x] 3.1 Update handlers.rs `handle_attach_here` to: check/build image, start container with interactive terminal, mount project dir + cache
- [x] 3.2 Container started with `-it` flag and entrypoint, not detached — user gets terminal directly
- [x] 3.3 Open host terminal emulator running `podman exec` or direct `podman run -it` into the container
- [x] 3.4 Detect terminal emulator: check $TERMINAL, x-terminal-emulator, then fallback list (gnome-terminal, konsole, alacritty, kitty, foot, xterm)

## 4. Image Path Resolution

- [x] 4.1 Handler resolves image source from executable-relative path or ~/.local/share/tillandsias/images/default/
- [x] 4.2 Update build.sh --install to copy images/default/ to ~/.local/share/tillandsias/images/default/

## 5. Build and Test

- [x] 5.1 Build workspace, verify compilation
- [ ] 5.2 Test: click Attach Here → image builds → terminal opens with OpenCode → project mounted at /home/forge/src (requires manual interactive test)
