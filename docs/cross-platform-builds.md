# Cross-Platform Build Strategy

Tillandsias targets Linux, macOS, and Windows. This document explains the build strategy for each platform and why certain local build options are not available.

## CI-First Approach

GitHub Actions is the authoritative build pipeline for all platforms. The release workflow (`.github/workflows/release.yml`) builds native artifacts on each platform's own runner:

| Platform | Runner | Target | Artifacts |
|----------|--------|--------|-----------|
| Linux | `ubuntu-22.04` | `x86_64-unknown-linux-gnu` | AppImage, deb, rpm |
| macOS (ARM) | `macos-latest` | `aarch64-apple-darwin` | .dmg |
| macOS (Intel) | `macos-latest` | `x86_64-apple-darwin` | .dmg |
| Windows | `windows-latest` | `x86_64-pc-windows-msvc` | .exe, .msi, NSIS |

All release artifacts are signed (Tauri Ed25519 for updates, Cosign for supply chain verification). Only CI can produce signed artifacts.

## Local Linux Builds

```bash
./build.sh              # Debug build
./build.sh --release    # Release build (deb, rpm)
./build.sh --test       # Run tests
```

See the main [CLAUDE.md](../CLAUDE.md) for full build.sh usage.

## Local Windows Cross-Compilation

```bash
./build-windows.sh              # Debug cross-build
./build-windows.sh --release    # Release cross-build (unsigned)
./build-windows.sh --check      # Type-check only (fast)
./build-windows.sh --test       # Compile tests (not executed)
```

Uses [cargo-xwin](https://github.com/rust-cross/cargo-xwin) to cross-compile from Linux to `x86_64-pc-windows-msvc`. Runs inside a dedicated `tillandsias-windows` toolbox.

### Limitations

- **Unsigned**: Cross-compiled artifacts are NOT signed. Windows SmartScreen will block them.
- **Experimental**: Tauri cross-compilation is labeled experimental. NSIS bundle generation may fail for some configurations.
- **No test execution**: Windows binaries cannot run on Linux. Tests are compiled but not executed.
- **Microsoft SDK**: cargo-xwin downloads Microsoft's CRT and Windows SDK headers on first use. See [license terms](https://go.microsoft.com/fwlink/?LinkId=2086102).

### When to Use

- Catching compilation errors before pushing to CI
- Testing dependency changes that affect the Windows target
- Debugging Windows-specific `#[cfg(target_os = "windows")]` code paths

For production Windows builds, always use CI.

## macOS Builds: CI Only

Local macOS cross-compilation from Linux is **not available** for two reasons:

### Legal Constraints

Apple's macOS EULA (Section 2B) permits macOS installation only on "Apple-branded hardware." This applies to VMs and containers. Running macOS in any form on non-Apple hardware violates the license.

The Xcode and Apple SDKs Agreement further prohibits installing Apple SDKs on non-Apple computers. Tools like `osxcross` that extract the macOS SDK operate in a legal gray area.

### Technical Constraints

Tauri depends on native macOS frameworks (WebKit, AppKit) that only exist on macOS. Unlike pure Rust projects, Tauri apps cannot be cross-compiled for macOS from Linux.

### Alternatives for Faster macOS CI

If GitHub Actions macOS runners are too slow or expensive:

- **[Cirrus Runners](https://cirrus-runners.app/)**: Drop-in GitHub Actions replacement using Apple Silicon hardware. Claimed 2-3x faster than GitHub's macOS runners.
- **[Tart](https://github.com/cirruslabs/tart)**: Open-source macOS VM tooling for Apple Silicon. Self-host on Mac Mini cluster.
- **[MacStadium](https://www.macstadium.com/)**: Hosted Mac infrastructure with per-node pricing.
