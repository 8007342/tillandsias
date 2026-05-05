---
tags: [windows, build, dev, cross-platform, podman]
languages: [bash, powershell, rust]
since: 2026-04-26
last_verified: 2026-04-26
sources:
  - https://rustup.rs/
  - https://podman.io/docs/installation#windows
  - https://docs.microsoft.com/en-us/windows/wsl/install
authority: high
status: current
---

# Windows native dev build

@trace spec:cross-platform
@cheatsheet runtime/forge-container.md

## Provenance

- rustup install: <https://rustup.rs/> — confirmed `rustup-init.exe`
  pulls a `stable-x86_64-pc-windows-msvc` toolchain into `~/.rustup`
  with `rust-lld.exe` preinstalled at
  `<toolchain>/lib/rustlib/<host>/bin/rust-lld.exe` (no separate
  install).
- Podman Windows install: <https://podman.io/docs/installation#windows>
  — confirmed `winget install RedHat.Podman` is the supported path
  (NOT `RedHat.Podman-Desktop`, which is the GUI). `podman machine
  init && podman machine start` produces a WSL-backed Linux VM.
- WSL: <https://docs.microsoft.com/en-us/windows/wsl/install> — confirmed
  `wsl --install --no-distribution` is the minimum Tillandsias needs;
  podman provides its own distribution.
- **Last updated**: 2026-04-26

**Use when**: developing Tillandsias on a Windows host (not
cross-compiling from Linux). The `build-local.sh` flow installs to
`%LOCALAPPDATA%\Tillandsias\tillandsias.exe` and is suitable for
smoke-testing a freshly merged main into `windows-next`.

## Prerequisites

| Tool | How to verify | Install |
|---|---|---|
| **Rust toolchain** | `rustc --version` returns 1.90+ | <https://rustup.rs/> |
| **musl Linux target** | `rustup target list --installed` lists `x86_64-unknown-linux-musl` | `rustup target add x86_64-unknown-linux-musl` (auto-installed by `scripts/build-sidecar.sh`) |
| **Podman** | `podman --version` returns 5.x | `winget install RedHat.Podman` |
| **podman machine** | `podman machine list` shows a row | `podman machine init` |
| **Git Bash** | `bash --version` works | Installed with Git for Windows |

`scripts/install.ps1` automates the WSL + podman parts when you do not
have them yet (it is also the path the one-line web installer takes).

## The smoke-test recipe

```bash
# from C:\Users\<you>\src\tillandsias on Git Bash:
PATH="$HOME/.cargo/bin:$PATH" ./build-local.sh --install
TILLANDSIAS_WORKSPACE="$(pwd -W)" \
    "$LOCALAPPDATA/Tillandsias/tillandsias.exe" --init
```

What each step does:

1. `build-local.sh --install` runs `scripts/build-sidecar.sh` to
   cross-compile the router sidecar (Linux musl ELF, ~3 MB, linked
   with `rust-lld`), then `cargo build -p tillandsias`, then copies
   `target/debug/tillandsias.exe` to `%LOCALAPPDATA%\Tillandsias\`.
2. `tillandsias --init` extracts embedded image sources to
   `%TEMP%\tillandsias-embedded\image-sources-<pid>\`, stages
   `cheatsheets/` from `$TILLANDSIAS_WORKSPACE` into
   `images/default/.cheatsheets/`, and runs `podman build` for
   proxy + forge + git + inference. Successful run looks like:
   ```
   ✓ proxy: tillandsias-proxy:v0.1.170.249
   ✓ forge: tillandsias-forge:v0.1.170.249
   ✓ git:   tillandsias-git:v0.1.170.249
   ✓ inference: tillandsias-inference:v0.1.170.249
   ```

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `pre-built router sidecar binary missing at images/router/...` | `build-local.sh` skipped the staging step | Use the version of `build-local.sh` that calls `scripts/build-sidecar.sh` (after this change). Or run `./scripts/build-sidecar.sh` manually. |
| `linker `cc` not found` during sidecar build | `OSTYPE` not detected by `build-sidecar.sh` (older shell, exotic terminal) | Set explicitly: `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=yes" ./scripts/build-sidecar.sh` |
| `cannot find type Server in module crate::control_socket` | New Windows-affected code added a control-socket call without `#[cfg(unix)]` | Wrap the call site in `#[cfg(unix)]` (see `src-tauri/src/main.rs` `bind_default()` block as the canonical example) |
| `COPY .cheatsheets/ ...: no such file or directory` during forge build | `TILLANDSIAS_WORKSPACE` unset or pointing somewhere without a `cheatsheets/` dir | Set `TILLANDSIAS_WORKSPACE` to your repo root, or accept the `MISSING.md` placeholder fallback (forge image still builds, just without baked cheatsheets) |
| `COPY cli/tillandsias-logs ...: no such file or directory` | Tray binary predates the `external-logs-layer` embed fix | Rebuild against `windows-next` ≥ 2026-04-26; the file is now embedded via `include_str!` in `embedded.rs` |

## Things this recipe does NOT do

- **Tray launch** — `tillandsias` (no args) starts the tray icon, but
  the control socket (router profile session OTPs) is `#[cfg(unix)]`
  on Windows today. Profiles that set `mount_control_socket = true`
  will not launch correctly until the Named Pipes follow-up lands.
- **Release bundle** — `build-local.sh --release` produces a debug-style
  install of a release binary, not an NSIS / MSI bundle. For installable
  artifacts, run the CI release path
  (`gh workflow run release.yml -f version="X.Y.Z.B"`) which drives
  `build-windows.sh` from a Linux runner.
- **Cross-compile from Linux** — see `build-windows.sh`. That path
  uses a Fedora toolbox with `cargo-xwin` and the MSVC SDK; it is the
  canonical CI build, not this dev recipe.

## Sources of Truth

- `scripts/build-sidecar.sh` — sidecar cross-compile, `rust-lld`
  fallback for Windows hosts.
- `scripts/install.ps1` — production one-line installer (downloads NSIS
  bundle from GitHub Releases). Different code path; this cheatsheet
  is for source builds only.
- `openspec/specs/cross-platform/spec.md` — `REQ-WIN-CONTROL-SOCKET-STUB`,
  `REQ-WIN-LOCAL-BUILD-SCRIPTS`, `REQ-WIN-INIT-CHEATSHEETS-STAGING`.
- `openspec/changes/windows-native-build/` — the change that wired up
  this recipe end-to-end.
