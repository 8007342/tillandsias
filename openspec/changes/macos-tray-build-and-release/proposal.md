## Why

The macOS host-shell wave already has specs for the runtime behavior (`macos-native-tray`), the VM abstraction (`vm-idiomatic-layer`), the wire (`vsock-transport`), and the in-VM provisioning (`vm-provisioning-lifecycle`, refined by `vm-recipe-provisioning`). What's missing is the **build and release pipeline** that turns the `tillandsias-macos-tray` crate into a downloadable `Tillandsias.app` end-users can install via `curl install-macos.sh | bash`. Today nothing assembles the bundle, signs it, runs it through macOS CI, or uploads it as a GitHub release asset. v0.0.1 cannot ship without this.

This change establishes the macOS counterpart to the existing Linux release flow in `.github/workflows/release.yml`, mirroring the Windows-equivalent work that already landed (`windows-native-build`). It is intentionally narrow: just the host-side packaging and release plumbing. Codesigning is **ad-hoc only** for v0.0.1 per owner decision (right-click-Open Gatekeeper bypass); Developer ID / notarization are post-v0.0.1.

## What Changes

- **ADDED** `scripts/build-macos-tray.sh` — host build driver: `cargo build --release -p tillandsias-macos-tray --target aarch64-apple-darwin`, assemble `Tillandsias.app/Contents/{MacOS/tillandsias-tray, Resources/icon.icns, Info.plist}` with `@VERSION@` / `@VERSION_SHORT@` / `@MIN_MACOS@` placeholder substitution from `crates/tillandsias-macos-tray/assets/Info.plist.template`, ad-hoc codesign with the new entitlements file, output `dist/Tillandsias.app` and `dist/tillandsias-tray-<version>-macos-arm64.tar.gz`.
- **ADDED** `crates/tillandsias-macos-tray/assets/Tillandsias.entitlements` — minimal entitlements for v0.0.1: `com.apple.security.virtualization=true` (required by VFR) + `com.apple.security.get-task-allow=true` (dev). Mirrors the shape proven in `research/vfr-spike/vfr-spike.entitlements`.
- **ADDED** `scripts/install-macos.sh` — curl-able installer: gate Apple Silicon (refuse on Intel), fetch the matching `tillandsias-tray-<version>-macos-arm64.tar.gz` from GitHub releases, SHA-256 verify against the release's published SHA256SUMS, extract to `/Applications/Tillandsias.app` (or `~/Applications/Tillandsias.app` if `/Applications/` is not writable without sudo), register as a Login Item via `osascript`, print Gatekeeper right-click-Open hint, `open -a Tillandsias.app` to drop the menubar icon.
- **MODIFIED** `.github/workflows/ci.yml` — add a `macos-build` job on `runs-on: macos-latest` running `scripts/build-macos-tray.sh` end-to-end and uploading `Tillandsias.app.tar.gz` as a CI artifact. The existing Linux job is untouched.
- **MODIFIED** `.github/workflows/release.yml` — add a `macos-release` job after the existing Linux job, gated on the same VERSION resolution, that runs `scripts/build-macos-tray.sh`, signs the artifact with Cosign (matching the Linux flow), and uploads `tillandsias-tray-<version>-macos-arm64.tar.gz` + its `.cosign.bundle` as release assets. Adds `install-macos.sh` to the release-asset list. The Linux upload path is untouched.
- **MODIFIED** `crates/tillandsias-macos-tray/Cargo.toml` — pin `objc2-virtualization` to a specific patch version under `[target.'cfg(target_os = "macos")'.dependencies]` so CI and dev builds match.
- **ADDED** an `[Capability: macos-tray-build-and-release]` spec capturing the contract: what scripts exist, what `Info.plist` substitution looks like, what gets signed, what the release artifact name shape is.

No breaking change: macOS host-shell artifacts have never shipped. The Linux release flow is additive-only.

## Capabilities

### New Capabilities

- `macos-tray-build-and-release`: covers the macOS-specific host build, packaging, ad-hoc codesigning, install script, CI build job, and release artifact upload.

### Modified Capabilities

(none)

## Impact

- **No spec deltas to existing capabilities**: this is a new capability covering host-side infra that did not previously exist.
- **New scripts**: `scripts/build-macos-tray.sh`, `scripts/install-macos.sh`.
- **New asset**: `crates/tillandsias-macos-tray/assets/Tillandsias.entitlements`.
- **CI cost**: the `macos-build` CI job uses `runs-on: macos-latest` minutes (~$0.08/min × 5–10 min ≈ $0.40–$0.80 per CI run). Gated to PR + push on `linux-next` only to control cost.
- **Release cost**: `macos-release` job runs only on `workflow_dispatch` releases, same as Linux today. Negligible monthly burn.
- **Distribution**: GitHub releases gain a third asset family alongside Linux (`tillandsias-linux-x86_64`) and Windows (`tillandsias-tray-<version>.exe`). Same Cosign-signed bundle pattern.
- **User-facing install UX (v0.0.1, ad-hoc signed)**: `curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash` puts the .app in /Applications/ and prints "If macOS Gatekeeper blocks the first launch, right-click Tillandsias.app and choose Open." This is acceptable for the alpha audience; Developer ID notarization comes in a post-v0.0.1 change.
- **Build dependencies on the developer's Mac**: standard Xcode CLT (provides `codesign`, `xcrun`, `cargo` toolchain), Rust 1.x with `aarch64-apple-darwin` target. No third-party tooling required.
