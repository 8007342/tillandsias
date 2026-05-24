## 1. Entitlements + Info.plist scaffolding

- [ ] 1.1 Create `crates/tillandsias-macos-tray/assets/Tillandsias.entitlements` with `com.apple.security.virtualization=true` and `com.apple.security.get-task-allow=true`.
- [ ] 1.2 Audit `crates/tillandsias-macos-tray/assets/Info.plist.template` — confirm `@VERSION@`, `@VERSION_SHORT@`, `@MIN_MACOS@` placeholders exist; add `LSUIElement`, `NSPrincipalClass`, `CFBundleIdentifier=com.tillandsias.tray` if missing.
- [ ] 1.3 Create a placeholder `crates/tillandsias-macos-tray/assets/icon.icns` (a 1024×1024 "T" PNG → iconutil .iconset → .icns is acceptable; a future change replaces with real art).

## 2. `scripts/build-macos-tray.sh`

- [ ] 2.1 Create the script with `set -euo pipefail`, shebang `#!/usr/bin/env bash`.
- [ ] 2.2 Arch gate: `[[ "$(uname -m)" == "arm64" ]] || { echo "error: build host must be Apple Silicon"; exit 1; }`.
- [ ] 2.3 Toolchain check: `rustup target list --installed | grep -q aarch64-apple-darwin || { echo "error: install with 'rustup target add aarch64-apple-darwin'"; exit 1; }`.
- [ ] 2.4 Resolve VERSION via `scripts/bump-version.sh --print`.
- [ ] 2.5 `cargo build --release -p tillandsias-macos-tray --target aarch64-apple-darwin`.
- [ ] 2.6 Assemble bundle: `dist/Tillandsias.app/Contents/{MacOS,Resources}`; copy binary; copy icon; substitute `Info.plist.template` with `sed`.
- [ ] 2.7 Ad-hoc codesign with the entitlements file.
- [ ] 2.8 Verify with `codesign --verify --deep --strict --verbose=2`.
- [ ] 2.9 Tar+gzip + write `dist/SHA256SUMS`.
- [ ] 2.10 Print a one-line summary: `built dist/tillandsias-tray-<v>-macos-arm64.tar.gz (<sha256>)`.

## 3. `scripts/install-macos.sh`

- [ ] 3.1 Arch + macOS-version gate per spec scenarios.
- [ ] 3.2 Resolve version: env `TILLANDSIAS_VERSION` overrides; default fetches latest via GitHub releases API (`gh release view --json tagName` if `gh` available, else `curl https://api.github.com/repos/8007342/tillandsias/releases/latest`).
- [ ] 3.3 Download tarball + `SHA256SUMS` to a tempdir.
- [ ] 3.4 Verify SHA-256 via `shasum -a 256 -c SHA256SUMS`.
- [ ] 3.5 Determine install location (`/Applications/` if writable without sudo else `~/Applications/`).
- [ ] 3.6 Detect + cleanly stop a running previous tray; back up existing `.app` to `.app.bak`.
- [ ] 3.7 Extract tarball to install location.
- [ ] 3.8 Optional `--login-item` flag wires `osascript` to add to System Events login items.
- [ ] 3.9 Print Gatekeeper right-click-Open hint.
- [ ] 3.10 `open -a Tillandsias.app`.
- [ ] 3.11 Add `--verify-cosign` opt-in flag that downloads the .cosign.bundle and runs `cosign verify-blob`; skip with informative message if cosign not installed.

## 4. CI `macos-build` job

- [ ] 4.1 Edit `.github/workflows/ci.yml`: add a `macos-build` job with `runs-on: macos-latest`.
- [ ] 4.2 Steps: actions/checkout@v4 → setup Rust stable + aarch64-apple-darwin target → cargo cache → run `scripts/build-macos-tray.sh`.
- [ ] 4.3 Upload `dist/tillandsias-tray-*-macos-arm64.tar.gz` as a workflow artifact named `macos-tray-build`.
- [ ] 4.4 Confirm Linux job is unchanged.

## 5. Release `macos-release` job

- [ ] 5.1 Edit `.github/workflows/release.yml`: add `macos-release` job with `runs-on: macos-latest`, `needs: build-linux` (so Linux runs first; failures don't auto-block macOS but the dependency captures the typical happy-path ordering).
- [ ] 5.2 Resolve VERSION same way the Linux job does.
- [ ] 5.3 Run `scripts/build-macos-tray.sh`.
- [ ] 5.4 Cosign keyless OIDC sign — reuse the existing setup-cosign-installer pattern.
- [ ] 5.5 Upload to the release: tarball, .cosign.bundle, install-macos.sh, SHA256SUMS for the macOS artifact.
- [ ] 5.6 Update release notes generation to include the macOS curl-install command (per spec Requirement 7).

## 6. Cargo.toml pin

- [ ] 6.1 In `crates/tillandsias-macos-tray/Cargo.toml`, pin `objc2-virtualization` to a specific patch version under `[target.'cfg(target_os = "macos")'.dependencies]`.
- [ ] 6.2 Confirm `Cargo.lock` is checked in and the pinned version resolves cleanly.

## 7. Spec sync

- [ ] 7.1 Run `openspec validate macos-tray-build-and-release` — expect "valid".
- [ ] 7.2 Run `/opsx:sync macos-tray-build-and-release` to add `macos-tray-build-and-release` as a new spec in `openspec/specs/`.
- [ ] 7.3 Cross-reference `openspec/specs/macos-native-tray/spec.md` and `openspec/specs/ci-release/spec.md` to point at the new capability.

## 8. Verify

- [ ] 8.1 `openspec validate macos-tray-build-and-release` returns "valid".
- [ ] 8.2 Local on dev Mac: `scripts/build-macos-tray.sh` produces a valid `.app`; `codesign --verify --deep --strict dist/Tillandsias.app` passes.
- [ ] 8.3 Double-click the .app from Finder; right-click-Open if Gatekeeper blocks; menubar icon appears.
- [ ] 8.4 `scripts/install-macos.sh` works against a test-release tag (manual `gh release create`).
- [ ] 8.5 CI: push a no-op commit, observe `macos-build` job green; download artifact; inspect it locally.
- [ ] 8.6 Release dry-run: `gh workflow run release.yml -f version=v0.2.260524.7-rc1` on a throwaway tag; observe `.tar.gz` and `.cosign.bundle` uploaded.
- [ ] 8.7 `cosign verify-blob --bundle <bundle> <tarball>` exits zero.

## 9. Archive

- [ ] 9.1 After Phases 1–5 of the v0.0.1 plan complete and a real release ships, run `/opsx:archive macos-tray-build-and-release`.
