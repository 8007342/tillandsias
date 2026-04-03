# Proposal: Windows Full Support

## Problem

Tillandsias had no working Windows support despite having cross-compilation and CI builds for Windows. Multiple issues prevented the app from functioning on a Windows host:

1. **Install script broken** — TLS 1.0 default in PowerShell 5.1, wrong asset name, no Podman bootstrap
2. **Embedded scripts had CRLF** — `include_str!` with `core.autocrlf=true` baked `\r\n` into container scripts
3. **Shell scripts not executable** — `Command::new(&script)` for `.sh` files doesn't work on Windows
4. **No podman machine lifecycle** — App didn't auto-init machines, only auto-started them
5. **Menu rebuilds steal focus** — `set_menu()` called on every state change, stealing window focus
6. **Language switching required restart** — i18n strings cached in LazyLock, not reloadable
7. **OS detection returned "Unknown OS"** — No Windows branch in `detect_host_os()`

## Solution

Fix all seven issues to make Tillandsias fully functional on Windows 11 with Podman WSL2 backend.

## Scope

- `scripts/install.ps1` — Complete rewrite with TLS 1.2, NSIS silent install, Podman bootstrap
- `scripts/uninstall.ps1` — NSIS uninstaller support
- `src-tauri/src/embedded.rs` — `write_lf()` helper to strip `\r` from all embedded files
- `src-tauri/src/handlers.rs` — Bash dispatch for `.sh` scripts, `.sh` terminal detection
- `src-tauri/src/runner.rs` — Bash dispatch + podman machine init/start
- `src-tauri/src/init.rs` — Bash dispatch
- `src-tauri/src/main.rs` — Menu fingerprinting, podman machine init
- `src-tauri/src/i18n.rs` — RwLock-based reloadable string table
- `src-tauri/src/event_loop.rs` — Live language reload
- `crates/tillandsias-core/src/config.rs` — Windows OS detection
- `crates/tillandsias-podman/src/client.rs` — `has_machine()` and `init_machine()` methods

## Non-goals

- Windows code signing (remains unsigned for now)
- Native Windows build script (cargo build works directly)
- Windows notifications (still no-op)
