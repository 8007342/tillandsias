## 1. Welcome Script

- [x] 1.1 Create `images/default/forge-welcome.sh` — the welcome message script
- [x] 1.2 Implement project name display (bold cyan, from `$TILLANDSIAS_PROJECT` env var or directory detection)
- [x] 1.3 Implement OS version display — read guest `/etc/os-release`, format host from `$TILLANDSIAS_HOST_OS`
- [x] 1.4 Implement mount point listing with color-coded access: green (rw), red (ro), blue (encrypted source)
- [x] 1.5 Implement rotating tips pool (~20 one-liners) with keyword highlighting
- [x] 1.6 Add "Project mounted at /home/forge/src/<project>" line before the tip

## 2. Fish Integration

- [x] 2.1 Update `images/default/shell/config.fish` to source the welcome script on interactive login
- [x] 2.2 Embed `forge-welcome.sh` in `src-tauri/src/embedded.rs` via `include_str!`
- [x] 2.3 Add `forge-welcome.sh` to `write_image_sources()` in embedded.rs

## 3. Rust Handler Changes

- [x] 3.1 In `handlers.rs` `handle_terminal()`, change `--entrypoint bash` to `--entrypoint fish`
- [x] 3.2 In `runner.rs`, change `--entrypoint /bin/bash` to `--entrypoint fish` for `--bash` mode
- [x] 3.3 In both handlers, add `-e TILLANDSIAS_HOST_OS=<detected>` to the podman command
- [x] 3.4 Implement `detect_host_os()` helper — read `/etc/os-release` on host, format as "Fedora Silverblue 43" etc.
- [x] 3.5 In both handlers, add `-e TILLANDSIAS_PROJECT=<project_name>` to the podman command

## 4. Image Build

- [x] 4.1 In `flake.nix`, add `forge-welcome.sh` to the image contents (alongside entrypoint.sh)
- [x] 4.2 Stage `images/default/forge-welcome.sh` in git so Nix can see it
- [x] 4.3 Rebuild image: `./scripts/build-image.sh forge --force`

## 5. Verification

- [x] 5.1 Test: open Terminal from tray, verify fish launches with welcome message
- [x] 5.2 Test: `tillandsias ../project/ --bash`, verify fish + welcome
- [x] 5.3 Test: verify mount points shown with correct colors and access levels
