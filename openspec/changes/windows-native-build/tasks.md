# Tasks: windows-native-build

Status legend: `[x]` done, `[ ]` pending.

## Build pipeline

- [x] `scripts/build-sidecar.sh` — set `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld`
      + `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=yes"`
      when `OSTYPE` matches `msys*` / `cygwin*` / `win32*`.
- [x] `build-local.sh` — invoke `scripts/build-sidecar.sh` before `cargo build`.
- [x] `build-local.ps1` — invoke `scripts/build-sidecar.sh` (via `bash`)
      before `cargo build`.

## Tray binary (Windows compile)

- [x] `src-tauri/src/control_socket/mod.rs` — `#[cfg(unix)] mod unix_impl`
      wraps the existing implementation; `#[cfg(not(unix))] mod stub`
      re-exports only the public consts.
- [x] `src-tauri/src/main.rs` — gate `static CONTROL_SOCKET`, the
      `Server::bind_default()` block, and the body of
      `shutdown_control_socket()` on `#[cfg(unix)]`. Provide a no-op
      `#[cfg(not(unix))]` body so the existing event-loop call site
      compiles.
- [x] `src-tauri/src/launch.rs` — gate the
      `if profile.mount_control_socket { ... }` block on `#[cfg(unix)]`.

## Init flow (Windows)

- [x] `src-tauri/src/embedded.rs` — embed `images/default/cli/tillandsias-logs`
      via `include_str!`, write it from `write_image_sources()`, chmod 0755
      on Unix alongside the other discoverability CLIs.
- [x] `src-tauri/src/init.rs` — Windows `run_with_force` path stages
      `.cheatsheets/` into the forge build context (workspace copy or
      `MISSING.md` placeholder).
- [x] `src-tauri/src/init.rs` — Windows `run_build_only` path mirrors
      the same staging.
- [x] `src-tauri/src/init.rs` — `copy_dir_recursive` helper gated on
      `#[cfg(target_os = "windows")]`.

## Spec convergence

- [ ] `openspec/specs/cross-platform/spec.md` — append REQ-WIN-CONTROL-SOCKET-STUB
      / REQ-WIN-LOCAL-BUILD-SCRIPTS / REQ-WIN-INIT-CHEATSHEETS-STAGING.
- [ ] `openspec/specs/agent-cheatsheets/spec.md` — append REQ-FORGE-CLI-LOGS-EMBEDDED.
- [ ] `openspec/changes/windows-native-build/specs/cross-platform/spec.md` —
      delta artifact carrying the new REQs.
- [ ] `openspec/changes/windows-native-build/specs/agent-cheatsheets/spec.md` —
      delta artifact for FORGE-CLI-LOGS-EMBEDDED.

## Documentation + traces

- [ ] `CLAUDE.md` — Windows Native Build section.
- [ ] `cheatsheets/runtime/windows-native-dev-build.md` — agent-facing
      cheatsheet documenting prerequisites, commands, common pitfalls.
- [ ] `./scripts/generate-traces.sh` — regenerate to refresh
      `openspec/specs/cross-platform/TRACES.md`.

## Smoke test

- [x] `./build-local.sh --install` on the windows-next host (debug build,
      installs to `%LOCALAPPDATA%\Tillandsias\tillandsias.exe`).
- [x] `tillandsias --version` returns `Tillandsias v0.1.170.249`.
- [x] `TILLANDSIAS_WORKSPACE=... tillandsias --init` builds proxy +
      forge + git + inference images successfully.
- [ ] `tillandsias` (no args) launches the tray and the menu renders.
- [ ] After tray launch, "Attach Here" on a project starts a forge
      session. (Out of scope for this change — control-plane stubbed
      out, router profile cannot launch on Windows yet.)

## Follow-ups (separate changes)

- [ ] `windows-control-socket-named-pipes`: tokio Named Pipe server +
      podman-machine-side bind path so the router profile is
      launchable on Windows.
- [ ] `embed-cheatsheets`: bake `cheatsheets/` into the tray binary
      so the workspace fallback in `init.rs` is no longer needed.
- [ ] `build-local-flag-parity`: full flag set (`--release`, `--remove`,
      `--wipe`, `--clean`, `--check`, `--test`) for `build-local.sh`
      and `.ps1`.
