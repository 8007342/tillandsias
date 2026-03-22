## 1. Workflow Foundation

- [x] 1.1 Create `.github/workflows/release.yml` with `on: push: tags: ['v*']` trigger, `permissions: contents: write`, and concurrency group to prevent duplicate release runs
- [x] 1.2 Add version validation job: extract version from `github.ref_name`, read version from workspace `Cargo.toml`, fail with clear error if they don't match
- [x] 1.3 Define matrix strategy with three targets: `x86_64-unknown-linux-gnu` on `ubuntu-latest`, `aarch64-apple-darwin` on `macos-latest`, `x86_64-pc-windows-msvc` on `windows-latest`

## 2. Platform Build Jobs

- [x] 2.1 Add Rust toolchain setup step using `dtolnay/rust-toolchain@<sha>` (stable channel) with appropriate target triple per matrix entry
- [x] 2.2 Add platform-specific system dependency installation: Linux (`libwebkit2gtk-4.1-dev`, `libappindicator3-dev`, `librsvg2-dev`, `patchelf`), macOS (none needed beyond Xcode CLI tools), Windows (none needed beyond MSVC)
- [x] 2.3 Add Rust compilation caching via `Swatinem/rust-cache@<sha>` scoped to the release workflow
- [x] 2.4 Add Tauri CLI installation step (`cargo install tauri-cli` or `npm install @tauri-apps/cli`)
- [x] 2.5 Add `tauri build` step for each matrix target, producing platform-native bundles
- [x] 2.6 Add post-build artifact rename step: find Tauri output artifacts and rename to `tillandsias-{version}-{os}-{arch}.{ext}` convention
- [x] 2.7 Upload renamed artifacts via `actions/upload-artifact@<sha>` for consumption by the release job

## 3. Checksum Generation

- [x] 3.1 Create `scripts/checksum.sh` that takes a directory of artifacts and produces a `SHA256SUMS` file using `sha256sum`
- [x] 3.2 Add checksum job to the workflow (needs all build jobs): download all artifacts via `actions/download-artifact@<sha>`, run checksum script, upload `SHA256SUMS` as artifact

## 4. GitHub Release

- [x] 4.1 Add release job (needs build + checksum jobs): download all artifacts and `SHA256SUMS`, create GitHub Release via `softprops/action-gh-release@<sha>` or `gh release create`
- [x] 4.2 Configure release to use tag name as title, auto-generated release notes, and attach all platform artifacts plus `SHA256SUMS`
- [x] 4.3 Set release as draft initially (can be changed to auto-publish later)

## 5. Dependency Pinning and Hardening

- [x] 5.1 Pin all third-party actions by full commit SHA with human-readable version comments
- [x] 5.2 Scope `GITHUB_TOKEN` permissions to minimum required (`contents: write`)
- [x] 5.3 Add `concurrency` group to prevent parallel release runs for the same tag

## 6. Verification

- [ ] 6.1 Test the workflow by pushing a `v0.1.0-rc.1` tag and verifying all three platform builds succeed
- [ ] 6.2 Verify artifact naming matches the convention for all platforms
- [ ] 6.3 Verify `SHA256SUMS` file contains entries for all artifacts and `sha256sum -c` passes
- [ ] 6.4 Verify GitHub Release is created with all assets attached
