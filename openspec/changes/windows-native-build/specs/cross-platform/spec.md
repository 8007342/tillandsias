## ADDED Requirements

### Requirement: Windows control-socket compiles to a stub

The tray-host control socket module SHALL compile to a no-op stub on `target_os = "windows"`. The stub SHALL re-export the public consts (`MAX_CONNECTIONS`, `IDLE_TIMEOUT`, `BROADCAST_CAPACITY`) but SHALL NOT expose a `Server` type. Tray binding, accept-loop spawn, and shutdown SHALL be `#[cfg(unix)]`-gated in `src-tauri/src/main.rs`. The `mount_control_socket` profile flag SHALL be silently ignored when constructing podman args on Windows (`launch.rs::compute_run_args`).

#### Scenario: cargo check on Windows
- **WHEN** `cargo check -p tillandsias` is run on
  `x86_64-pc-windows-msvc`
- **THEN** the build succeeds with zero unresolved imports for
  `tokio::net::UnixListener`, `std::os::unix::net::*`, or
  `std::os::unix::fs::FileTypeExt`

#### Scenario: tillandsias --init on Windows
- **WHEN** `tillandsias.exe --init` runs on Windows
- **THEN** image builds proceed without binding the control socket
- **AND** no warning about a failed `Server::bind_default()` is
  emitted (the call site is `#[cfg(unix)]`-gated entirely)

#### Scenario: future caller without cfg gate
- **WHEN** new tray code references `crate::control_socket::Server`
  without a `#[cfg(unix)]` attribute
- **THEN** compilation fails on Windows with "cannot find type Server"
  (intentional fail-closed)

### Requirement: Windows local-build scripts stage the router sidecar

`build-local.sh` and `build-local.ps1` SHALL invoke
`scripts/build-sidecar.sh` BEFORE `cargo build`. The sidecar helper
SHALL detect Windows-shell hosts (via `OSTYPE` matching `msys*` /
`cygwin*` / `win32*`) and configure the
`x86_64-unknown-linux-musl` cross-link to use `rust-lld` and
`-C link-self-contained=yes`, so no external `cc` linker is required.
Linux/macOS hosts SHALL be unaffected.

#### Scenario: fresh Windows checkout
- **WHEN** a developer clones the repo on Windows and runs
  `./build-local.sh --install`
- **THEN** `scripts/build-sidecar.sh` cross-compiles the router
  sidecar successfully via `rust-lld`
- **AND** `cargo build -p tillandsias` finds the staged binary at
  `images/router/tillandsias-router-sidecar`
- **AND** the resulting `tillandsias.exe` is installed to
  `%LOCALAPPDATA%\Tillandsias\`

#### Scenario: idempotent re-run
- **WHEN** `./build-local.sh --install` is run twice in a row with no
  source changes
- **THEN** the second sidecar staging step exits via the staleness
  check (`is_stale` returns false) without invoking `cargo build`

### Requirement: Windows --init stages cheatsheets into the forge build context

The Windows `--init` path SHALL stage `.cheatsheets/` into the forge
image build context before invoking `podman build`. The staging
SHALL prefer `$TILLANDSIAS_WORKSPACE/cheatsheets/` when set and a
directory; otherwise it SHALL create a `.cheatsheets/MISSING.md`
placeholder (matching `scripts/build-image.sh:273-283`'s fallback for
non-workspace launches). The forge `Containerfile`'s
`COPY .cheatsheets/ /opt/cheatsheets-image/` SHALL succeed in either
case.

#### Scenario: workspace dev run
- **GIVEN** `TILLANDSIAS_WORKSPACE` points at a checkout with
  `cheatsheets/` populated
- **WHEN** `tillandsias --init` runs on Windows
- **THEN** the forge image build context contains a populated
  `.cheatsheets/` directory mirroring the workspace cheatsheets
- **AND** the forge image's `/opt/cheatsheets-image/` is non-empty

#### Scenario: clean install (no workspace)
- **GIVEN** `TILLANDSIAS_WORKSPACE` is unset
- **WHEN** `tillandsias --init` runs on Windows
- **THEN** the forge image build context contains a `.cheatsheets/`
  directory with only a `MISSING.md` placeholder
- **AND** the forge image still builds successfully (just without the
  cheatsheets layer; agents see `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets`
  as an empty hot mount)
