## Why

The Windows native dev path (`./build-local.sh --install && tillandsias --init`)
was broken end-to-end after the recent merges:

1. `src-tauri/build.rs` panics if `images/router/tillandsias-router-sidecar`
   is missing. `build-local.sh` never staged it. Linux/macOS go through
   `build.sh` which calls `scripts/build-sidecar.sh`; Windows had no equivalent.
2. `scripts/build-sidecar.sh` cross-compiled the sidecar to
   `x86_64-unknown-linux-musl` assuming a system `cc` linker. Git Bash on
   Windows has no `cc` in `PATH`, so the link step failed before producing
   the binary.
3. `src-tauri/src/control_socket/mod.rs` uses `std::os::unix::net::*` and
   `tokio::net::UnixListener` unconditionally — the entire module fails
   to compile on `target_os = "windows"`. The tray-host control-socket
   landed Unix-only with no Windows gate.
4. `src-tauri/src/embedded.rs` embeds three discoverability CLIs but not
   the new `tillandsias-logs` binary that landed with `external-logs-layer`.
   The forge `Containerfile` has `COPY cli/tillandsias-logs ...` so the
   build context is missing a file on every platform — Windows just
   surfaces it first because Linux's `build-image.sh` silently masked the
   issue with a fresh extraction at every build.
5. `src-tauri/src/init.rs` Windows path bypasses `scripts/build-image.sh`
   and calls `podman build` directly. That bypass skipped the
   `cp -r cheatsheets/ images/default/.cheatsheets/` staging step. The
   forge `Containerfile`'s `COPY .cheatsheets/` then fails.

The smoke test on the Windows host (this branch's target) is the
forcing function — without it, none of these regressions would have been
caught until a release-candidate build, when correcting them would block
shipping.

## What Changes

### Build pipeline (Windows host)

- **MODIFIED** `scripts/build-sidecar.sh` — when `OSTYPE` matches
  `msys*` / `cygwin*` / `win32*`, export
  `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld` and
  `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=yes"`.
  Rust ships `rust-lld.exe` under `~/.rustup/toolchains/<host>/lib/rustlib/<host>/bin/`,
  so no external toolchain is required. Linux/macOS hosts unchanged
  (default `cc` resolution is fine on those).
- **MODIFIED** `build-local.sh` and `build-local.ps1` — stage the
  router sidecar via `scripts/build-sidecar.sh` BEFORE `cargo build`,
  matching the structure of `build.sh::_stage_sidecar`. Idempotent.

### Tray binary (Windows compile)

- **MODIFIED** `src-tauri/src/control_socket/mod.rs` — wrap the
  Unix-domain socket implementation in `#[cfg(unix)] mod unix_impl { ... }`
  with `#[cfg(unix)] pub use unix_impl::*`. Provide a
  `#[cfg(not(unix))] mod stub` that re-exports only the public consts
  (`MAX_CONNECTIONS`, `IDLE_TIMEOUT`, `BROADCAST_CAPACITY`); the
  `Server` type is intentionally absent so any caller added without a
  `#[cfg(unix)]` gate fails closed at compile time.
- **MODIFIED** `src-tauri/src/main.rs` — gate `static CONTROL_SOCKET`,
  the `Server::bind_default()` block in the Tauri `setup` callback, and
  the synchronous body of `shutdown_control_socket()` on
  `#[cfg(unix)]`. `#[cfg(not(unix))] async fn shutdown_control_socket()`
  is a no-op stub so the existing `event_loop.rs` call-site compiles
  without extra cfgs.
- **MODIFIED** `src-tauri/src/launch.rs` — gate the
  `if profile.mount_control_socket { ... }` block on `#[cfg(unix)]`.
  The router profile (the only v1 consumer that sets the flag) cannot
  launch on Windows yet; this is documented behaviour, not a regression.

### Init flow (Windows)

- **MODIFIED** `src-tauri/src/embedded.rs` — add `FORGE_CLI_LOGS` const
  with `include_str!("../../images/default/cli/tillandsias-logs")`,
  write it to `cli/tillandsias-logs` in `write_image_sources()`, and
  `chmod 0755` it on Unix alongside the other discoverability CLIs.
  This is a fix for the `external-logs-layer` change that affects every
  platform.
- **MODIFIED** `src-tauri/src/init.rs` — both Windows code paths
  (`run_with_force` and `run_build_only`) now stage `.cheatsheets/`
  into the forge build context before invoking `podman build`. Source
  order: `$TILLANDSIAS_WORKSPACE/cheatsheets/` (workspace runs), then a
  `MISSING.md` placeholder mirroring `scripts/build-image.sh:273-283`.
  New helper `copy_dir_recursive` is `#[cfg(target_os = "windows")]`.

### Documentation

- **NEW** Windows Native Build section in `CLAUDE.md` next to the macOS
  Native Build section. Documents `./build-local.sh --install` and
  `tillandsias --init` and notes that the existing `build-windows.sh`
  cross-compile path remains for non-Windows hosts.
- **NEW** `cheatsheets/runtime/windows-native-dev-build.md` — concrete
  recipe for "build + install + smoke-test on Windows", listing the
  prerequisites already checked into `scripts/install.ps1` (rustup,
  podman, WSL, podman-machine init).

## Capabilities

### Modified Capabilities

- `cross-platform`:
  - **REQ-WIN-CONTROL-SOCKET-STUB (new)** — the tray-host control-socket
    module SHALL compile to a no-op stub on `target_os = "windows"`.
    Tray binding, accept loop, and shutdown SHALL be `#[cfg(unix)]`-gated
    in `main.rs`. The `mount_control_socket` profile flag SHALL be
    silently ignored on Windows containers (router will be re-wired to
    Named Pipes in a follow-up change).
  - **REQ-WIN-LOCAL-BUILD-SCRIPTS (new)** — `build-local.sh` and
    `build-local.ps1` SHALL stage the router sidecar via
    `scripts/build-sidecar.sh` before `cargo build`. The sidecar
    helper SHALL configure `rust-lld` + `link-self-contained=yes` for
    the `x86_64-unknown-linux-musl` target when `OSTYPE` indicates a
    Windows shell.
  - **REQ-WIN-INIT-CHEATSHEETS-STAGING (new)** — the Windows `--init`
    path SHALL stage the cheatsheets layer (workspace dir or
    placeholder) into the forge build context. Behaviour matches
    `scripts/build-image.sh` lines 273-283.

- `agent-cheatsheets`:
  - **REQ-FORGE-CLI-LOGS-EMBEDDED (new)** — the tray binary SHALL embed
    `images/default/cli/tillandsias-logs` and write it into the forge
    build context alongside the other discoverability CLIs. This is the
    forge-side reader for the external-logs layer; the Containerfile
    already has the COPY directive.

## Impact

- **Build scripts**: `scripts/build-sidecar.sh`, `build-local.sh`,
  `build-local.ps1`.
- **Tray binary**: `src-tauri/src/control_socket/mod.rs`,
  `src-tauri/src/main.rs`, `src-tauri/src/launch.rs`,
  `src-tauri/src/init.rs`, `src-tauri/src/embedded.rs`.
- **Spec / docs**: `openspec/specs/cross-platform/spec.md`,
  `openspec/specs/agent-cheatsheets/spec.md`, `CLAUDE.md`,
  `cheatsheets/runtime/windows-native-dev-build.md`.
- **CI / release**: unchanged. The CI release path uses
  `build-windows.sh` (cross-compile from Linux toolbox), which is
  unaffected by this change.
- **Linux / macOS**: the `tillandsias-logs` embed and the
  `OSTYPE`-gated linker config are no-ops; behaviour identical to today.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms
  cheatsheets are baked into the image at build time.
- `cheatsheets/runtime/networking.md` — control-socket Unix-only
  primitive and the future Named Pipes plan for Windows.
- `openspec/specs/cross-platform/spec.md` — REQ-WIN-CRLF / REQ-WIN-BASH
  / REQ-WIN-MACHINE established the cross-platform delta this change
  extends.
- `openspec/specs/dev-build/spec.md` — `--install` semantics for the
  Linux `build.sh`; this change extends the same semantics to
  `build-local.sh`.
- Verified locally on `windows-next` host (2026-04-26): all four
  enclave images (proxy, forge, git, inference) built successfully via
  `tillandsias --init` after the changes were applied.

## Open Questions (resolve in design.md before /opsx:apply)

- **Named Pipes for the Windows control socket**: this change ships the
  stub, not the implementation. Follow-up change should wire
  `tokio::net::windows::named_pipe::*` so the router profile is
  launchable on Windows.
- **Cheatsheets at install time**: the smoke test relies on
  `TILLANDSIAS_WORKSPACE` being set, which is fine for dev. For an
  installed binary on Windows we should embed the cheatsheets at
  compile time (matching how scripts and Containerfiles are embedded).
  Follow-up change.
- **`build-local.sh` flag parity with `build.sh`**: today the local
  Windows script always builds-and-installs; users opt out by not
  invoking it. Convergence with `build.sh --install` / `--release` /
  `--clean` / `--check` / `--test` / `--remove` / `--wipe` is desirable
  but out of scope for this smoke-test fix. Follow-up.
