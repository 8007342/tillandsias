## 1. build-osx.sh

- [x] 1.1 Create `build-osx.sh` at project root with flag parsing for: (none), --release, --test, --check, --clean, --install, --remove, --wipe, --help
- [x] 1.2 Implement platform check (exit with error if not Darwin)
- [x] 1.3 Implement architecture detection (arm64 → aarch64-apple-darwin, x86_64 → x86_64-apple-darwin)
- [x] 1.4 Implement prerequisite checks (cargo, xcode-select) with install instructions
- [x] 1.5 Implement tauri-cli auto-installation if `cargo tauri --version` fails
- [x] 1.6 Implement default build: `cargo build --workspace`
- [x] 1.7 Implement --release: `cargo tauri build --target <arch>` with .dmg bundle
- [x] 1.8 Implement --test: `cargo test --workspace`
- [x] 1.9 Implement --check: `cargo check --workspace`
- [x] 1.10 Implement --clean: `cargo clean`
- [x] 1.11 Implement --install: release build + copy .app from bundle to ~/Applications/ + CLI symlink to ~/.local/bin/
- [x] 1.12 Implement --remove: remove ~/Applications/Tillandsias.app + CLI symlink
- [x] 1.13 Implement --wipe: remove target/, ~/.cache/tillandsias/
- [x] 1.14 Add unsigned build warning with xattr -cr hint
- [x] 1.15 Auto-increment build number via bump-version.sh

## 2. Fix install.sh macOS path

- [x] 2.1 Replace .dmg download-only with: hdiutil mount → find .app → cp to ~/Applications/ → detach → cleanup
- [x] 2.2 Create CLI symlink at ~/.local/bin/tillandsias → .app/Contents/MacOS/Tillandsias
- [x] 2.3 Remove manual .app bundle construction (Info.plist, sips icon conversion)
- [x] 2.4 Fix unconditional "Installed to ~/.local/bin/tillandsias" message (Linux-only now)
- [x] 2.5 Add error handling for mount/extract failures with fallback message

## 3. Documentation

- [x] 3.1 Update CLAUDE.md Build Commands section with build-osx.sh usage
