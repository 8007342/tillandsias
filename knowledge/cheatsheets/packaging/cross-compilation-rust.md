---
id: cross-compilation-rust
title: Rust Cross-Compilation
category: packaging/rust
tags: [rust, cross-compilation, cargo-xwin, windows, macos, target-triple, linker]
upstream: https://doc.rust-lang.org/cargo/reference/config.html
version_pinned: "1.85"
last_verified: "2026-03-30"
authority: official
---

# Rust Cross-Compilation

## Target Triples

Format: `<arch>-<vendor>-<os>-<abi>`. Common targets:

| Triple | Use case |
|---|---|
| `x86_64-pc-windows-msvc` | Windows 64-bit (MSVC ABI) |
| `x86_64-pc-windows-gnu` | Windows 64-bit (MinGW ABI) |
| `aarch64-pc-windows-msvc` | Windows ARM64 |
| `aarch64-apple-darwin` | macOS Apple Silicon |
| `x86_64-apple-darwin` | macOS Intel |
| `aarch64-unknown-linux-gnu` | Linux ARM64 (glibc) |
| `x86_64-unknown-linux-musl` | Linux x86_64 (static, musl) |

```bash
# List all available targets
rustc --print target-list

# Show cfg flags for a target (useful for conditional compilation)
rustc --print cfg --target aarch64-apple-darwin

# Add a target via rustup
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-apple-darwin

# Build for a specific target
cargo build --target x86_64-pc-windows-msvc
```

## .cargo/config.toml Linker Configuration

```toml
# Per-target linker overrides
[target.aarch64-unknown-linux-gnu]
linker = "aarch64-linux-gnu-gcc"

[target.x86_64-pc-windows-gnu]
linker = "x86_64-w64-mingw32-gcc"

# osxcross example (Linux -> macOS)
[target.aarch64-apple-darwin]
linker = "aarch64-apple-darwin21-clang"
rustflags = ["-C", "link-arg=-fuse-ld=lld"]

# Environment variables for C/C++ dependencies
[target.x86_64-pc-windows-msvc]
rustflags = ["-C", "target-feature=+crt-static"]

[env]
# Set CC/CXX for cc-rs crate when cross-compiling
CC_x86_64_pc_windows_gnu = "x86_64-w64-mingw32-gcc"
CXX_x86_64_pc_windows_gnu = "x86_64-w64-mingw32-g++"
AR_x86_64_pc_windows_gnu = "x86_64-w64-mingw32-ar"
```

## cargo-xwin: Linux to Windows MSVC

Cross-compile to `x86_64-pc-windows-msvc` without Visual Studio. Downloads
Windows SDK and CRT headers/libs automatically.

```bash
# Install (requires clang for C/C++ deps)
cargo install cargo-xwin

# Build
cargo xwin build --target x86_64-pc-windows-msvc
cargo xwin build --target x86_64-pc-windows-msvc --release

# Test (requires wine)
cargo xwin test --target x86_64-pc-windows-msvc

# cargo-xwin auto-generates CMake toolchain files for crates using cmake-rs
```

Requirements for C/C++ dependencies: `clang`, `llvm`. For assembly: `llvm-tools-preview`
component or system `llvm`.

## Sysroot Management

```bash
# rustup manages Rust sysroots per-target automatically
rustup target add x86_64-unknown-linux-musl
# Installs to: ~/.rustup/toolchains/<toolchain>/lib/rustlib/<target>/

# For C sysroots, you must provide them yourself:
# - Linux: install cross-compiler packages (e.g., gcc-aarch64-linux-gnu)
# - Windows: cargo-xwin handles this; or use xwin standalone
# - macOS: use osxcross to package the macOS SDK

# xwin standalone: download Windows SDK/CRT for custom setups
cargo install xwin
xwin --accept-license splat --output /path/to/sysroot
```

## Cross-Compiling C Dependencies

Common patterns for crates that build C code (`cc`, `cmake`, `pkg-config`):

```bash
# Set environment variables (underscore-separated target triple)
export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc
export CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++
export PKG_CONFIG_SYSROOT_DIR=/usr/aarch64-linux-gnu
export PKG_CONFIG_PATH=/usr/aarch64-linux-gnu/lib/pkgconfig

# OpenSSL cross-compile (common pain point)
# Option 1: Use vendored feature to build from source
cargo build --target aarch64-unknown-linux-gnu --features openssl/vendored

# Option 2: Point to cross-compiled OpenSSL
export OPENSSL_DIR=/path/to/cross-compiled/openssl
export OPENSSL_STATIC=1

# Option 3: Use rustls instead of native OpenSSL (avoids the problem entirely)
```

## Conditional Compilation

```rust
// Single target OS
#[cfg(target_os = "windows")]
fn platform_init() { /* Windows-only */ }

#[cfg(target_os = "macos")]
fn platform_init() { /* macOS-only */ }

#[cfg(target_os = "linux")]
fn platform_init() { /* Linux-only */ }

// Combinators
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn unix_thing() {}

#[cfg(all(target_os = "windows", target_arch = "x86_64"))]
fn win64_thing() {}

#[cfg(not(target_os = "windows"))]
fn non_windows() {}

// In Cargo.toml — platform-specific dependencies
// [target.'cfg(target_os = "windows")'.dependencies]
// windows = "0.58"
//
// [target.'cfg(unix)'.dependencies]
// nix = "0.29"

// Runtime check (always compiled, checked at runtime)
if cfg!(target_os = "macos") {
    println!("running on macOS");
}
```

Key cfg predicates: `target_os`, `target_arch`, `target_family` (`unix`/`windows`/`wasm`),
`target_env` (`gnu`/`msvc`/`musl`), `target_vendor`, `target_pointer_width`.

## macOS Universal Binaries

```bash
# Build for both architectures
cargo build --release --target x86_64-apple-darwin
cargo build --release --target aarch64-apple-darwin

# Combine with lipo
lipo -create \
  target/x86_64-apple-darwin/release/myapp \
  target/aarch64-apple-darwin/release/myapp \
  -output target/release/myapp-universal

# Verify
lipo -info target/release/myapp-universal
# Architectures in the fat file: x86_64 arm64
```

Must be done on macOS (or with osxcross). Both builds must use the same Rust
toolchain version and dependency versions.

## Common Pitfalls

| Problem | Fix |
|---|---|
| `linker 'cc' not found` | Set `[target.<triple>] linker` in `.cargo/config.toml` |
| OpenSSL build fails | Use `openssl/vendored` feature or `rustls` |
| Missing `-lgcc_s` (musl) | Install `musl-tools`; set `RUSTFLAGS="-C target-feature=+crt-static"` |
| `ring` fails cross-compiling to macOS | Needs full SDK via osxcross; consider building on macOS natively |
| CMake can't find cross-compiler | `cargo-xwin` handles this; for others set `CMAKE_TOOLCHAIN_FILE` |
| `pkg-config` finds host libs | Set `PKG_CONFIG_SYSROOT_DIR` and `PKG_CONFIG_PATH` for target |
| Windows .exe missing DLLs | Link CRT statically: `target-feature=+crt-static` |
| Proc macros fail cross-compile | They run on host; ensure host toolchain is also installed |
