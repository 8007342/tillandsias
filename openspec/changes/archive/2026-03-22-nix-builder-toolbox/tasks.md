## 1. Builder Toolbox Setup

- [x] 1.1 Create `scripts/ensure-builder.sh` — checks if `tillandsias-builder` toolbox exists, creates it with Fedora + Nix if not. Nix installed in single-user mode with flakes enabled.
- [x] 1.2 Test builder toolbox creation: `scripts/ensure-builder.sh` creates toolbox and `nix --version` works inside it

## 2. Nix Flake Definition

- [x] 2.1 Create `flake.nix` at project root with two image outputs: `forge-image` and `web-image`
- [x] 2.2 `forge-image`: uses `dockerTools.buildLayeredImage` with bash, git, gh, curl, jq, ripgrep, nodejs, npm, nix, OpenCode binary, entrypoint.sh, opencode.json
- [x] 2.3 `web-image`: uses `dockerTools.buildLayeredImage` with minimal alpine-like contents + busybox httpd + entrypoint.sh
- [x] 2.4 Generate `flake.lock` by running `nix flake lock` inside builder toolbox
- [x] 2.5 Test: `toolbox run -c tillandsias-builder nix build .#forge-image` produces a loadable tarball

## 3. Build Image Script

- [x] 3.1 Create `scripts/build-image.sh` — takes image name (forge|web), ensures builder toolbox, runs nix build inside it, loads tarball via `podman load`, tags image
- [x] 3.2 Staleness detection: store last build hash, skip if flake.lock + sources unchanged
- [x] 3.3 Support `--force` flag to bypass staleness check
- [x] 3.4 User-friendly output: progress messages, build time, image size

## 4. Integration

- [x] 4.1 Update `build.sh` to call `scripts/build-image.sh` during `--install`
- [x] 4.2 Update handlers.rs to call build-image.sh (via shell) instead of podman build when image is stale
- [x] 4.3 Update runner.rs CLI mode to use build-image.sh for image management
- [x] 4.4 Add `podman load` support to PodmanClient (load_image method)

## 5. Cleanup

- [x] 5.1 Keep Containerfiles as reference documentation (not primary build path)
- [x] 5.2 Add flake.lock to git (reproducibility)
- [x] 5.3 Add .nix-output/ to .gitignore
- [x] 5.4 Update CLAUDE.md with builder toolbox info and image build commands
