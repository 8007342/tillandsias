## Context

On macOS, there's no toolbox — Tauri builds natively using Xcode Command Line Tools + Rust. The .dmg from `cargo tauri build` contains a proper signed .app bundle. The install script needs to mount this .dmg and extract it, not try to build an .app from scratch.

## Goals / Non-Goals

**Goals:**
- Single `./build-osx.sh` covers the macOS dev lifecycle (mirrors build.sh for Linux)
- No toolbox dependency — runs cargo/tauri directly on the host
- `--install` copies the Tauri .app bundle to ~/Applications/ and symlinks CLI binary
- Fix `install.sh` to properly handle .dmg files on macOS
- Works on both Apple Silicon (aarch64) and Intel (x86_64)

**Non-Goals:**
- Code signing / notarization (CI handles this)
- Universal binary (fat binary for both architectures)
- Replacing CI release pipeline

## Decisions

### D1: build-osx.sh Flag Design

Mirrors build.sh flags where applicable:

| Flag | Action |
|------|--------|
| (none) | Debug build (`cargo build --workspace`) |
| `--release` | Release build (`cargo tauri build --target <arch>`) |
| `--test` | Run tests (`cargo test --workspace`) |
| `--check` | Type-check only (`cargo check --workspace`) |
| `--clean` | `cargo clean` |
| `--install` | Release build + copy .app to ~/Applications/ + CLI symlink |
| `--remove` | Remove installed .app + CLI symlink |
| `--wipe` | Remove target/, ~/.cache/tillandsias/ |

No `--toolbox-reset` or `--appimage` since those are Linux-only concepts.

### D2: No Toolbox

macOS has Xcode CLT which provides the C toolchain, and Tauri v2 on macOS uses WebKit (built-in). No containerized build environment needed.

### D3: install.sh .dmg Handling

The installer uses `hdiutil attach` to mount the .dmg, finds the .app inside, copies it to ~/Applications/, detaches, and cleans up. Creates a CLI symlink at ~/.local/bin/tillandsias pointing into the .app bundle. Removes the old code that tried to manually construct an .app bundle from a raw binary.

### D4: Unsigned Build Warning

Local builds won't be codesigned or notarized. The script warns about this and provides the `xattr -cr` command to bypass Gatekeeper for local testing.
