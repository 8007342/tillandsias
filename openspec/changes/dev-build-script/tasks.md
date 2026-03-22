## 1. Build Script

- [x] 1.1 Create `build.sh` at project root with flag parsing for: (none), --release, --test, --check, --clean, --install, --remove, --wipe, --toolbox-reset, --help
- [x] 1.2 Implement toolbox auto-detection and creation: check `toolbox list`, create if missing, install system deps (gtk3-devel, webkit2gtk4.1-devel, libappindicator-gtk3-devel, librsvg2-devel, openssl-devel, pkg-config, gcc)
- [x] 1.3 Implement tauri-cli auto-installation inside toolbox if `cargo tauri --version` fails
- [x] 1.4 Implement default build: `toolbox run -c tillandsias cargo build --workspace`
- [x] 1.5 Implement --release: `toolbox run -c tillandsias cargo tauri build`
- [x] 1.6 Implement --test: `toolbox run -c tillandsias cargo test --workspace`
- [x] 1.7 Implement --check: `toolbox run -c tillandsias cargo check --workspace`
- [x] 1.8 Implement --clean: `toolbox run -c tillandsias cargo clean`
- [x] 1.9 Implement --install: release build + `cp` binary to `~/.local/bin/tillandsias`
- [x] 1.10 Implement --remove: `rm ~/.local/bin/tillandsias`
- [x] 1.11 Implement --wipe: remove `target/`, `~/.cache/tillandsias/`
- [x] 1.12 Implement --toolbox-reset: `toolbox rm -f tillandsias` then recreate
- [x] 1.13 Support flag combinations (e.g., `--clean --release --install`)
- [x] 1.14 Make script executable and test default build succeeds

## 2. Documentation

- [x] 2.1 Update CLAUDE.md with build.sh usage
- [x] 2.2 Update README.md build section to reference build.sh
