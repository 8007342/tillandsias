# Design: windows-native-build

## Context

The `windows-next` branch holds platform-specific work; the merge from
`main` (102 commits) brought in cross-platform work that landed Unix-only
or with implicit dev-host assumptions:

- `tray-host-control-socket` (sidecar OTP wiring): Unix-domain socket,
  no Windows compile path.
- `external-logs-layer` (forge-side log reader): added a Containerfile
  COPY but no embed in the tray binary.
- `forge-hot-cold-split` (cheatsheets on tmpfs): added a build-time
  staging step that lives inside `scripts/build-image.sh`, not in the
  Windows `init.rs` direct-podman path.
- `opencode-web-session-otp` (per-window cookies): `build.rs` now
  panics when the router sidecar is missing — `build-local.sh` doesn't
  stage it.

The smoke test (`build-local.sh --install && tillandsias --init`) was
the forcing function: each layer of brokenness surfaces sequentially as
the previous one is fixed.

## Locked Decisions

### D1. Stub the control socket on Windows; don't translate to Named Pipes here

**Decision**: `control_socket/mod.rs` compiles to an empty
`mod stub { ... }` on `target_os = "windows"`. The `Server` type is
absent (not faked), so any `#[cfg(unix)]`-missing caller fails at
compile time rather than silently ignoring the issue at runtime.

**Why**: Named Pipes have a different connection lifecycle (each accept
is an independent server-side instance) and a different mount story
(podman-machine on Windows would need an SMB-style export to make a
host pipe visible inside the Linux VM). That work is real and deserves
its own openspec change. The smoke-test goal here is `tillandsias --init`,
which only builds container images and never touches the control plane.

**How to apply**: any future caller of control-socket APIs MUST gate on
`#[cfg(unix)]` until the Named Pipes change lands. The compile-fail
posture is intentional — silent runtime no-ops would mask shipping bugs.

### D2. `rust-lld` + `link-self-contained=yes` for musl cross-compile

**Decision**: when host is `msys` / `cygwin` / `win32`,
`scripts/build-sidecar.sh` exports
`CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld` and
`CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=yes"`.
Linux/macOS hosts skip the export (default `cc` resolution still works).

**Why considered**: alternatives were (a) install `musl-gcc` via MSYS2
package, (b) install LLVM toolchain via winget, (c) ship a vendored
musl linker. (a)–(c) all add a heavyweight prerequisite. `rust-lld`
ships inside the rustup toolchain at
`<host>/lib/rustlib/<host>/bin/rust-lld.exe`, so the only cost is one
env-var per build.

**How to apply**: env-var route over `.cargo/config.toml` so Linux
hosts (which already work) aren't affected. The OSTYPE check is
narrow — Git Bash sets `OSTYPE=msys`, MSYS2 shells set the same, and
Cygwin sets `OSTYPE=cygwin`. PowerShell-launched bash inherits the
parent shell's OSTYPE.

### D3. Cheatsheets staging duplicates Linux behavior verbatim

**Decision**: `init.rs` Windows path inlines the same fallback policy
as `scripts/build-image.sh:273-283`: prefer
`$TILLANDSIAS_WORKSPACE/cheatsheets/`, fall back to a
`MISSING.md`-only directory. No new policy.

**Why considered**: alternative was to make `init.rs` shell out to
`bash scripts/build-image.sh` on Windows. Rejected because (a) it
introduces a hard dependency on Git Bash being on `PATH` for tray
launches (today's `--init` works without it), (b) the script's
`OSTYPE`-conditional Homebrew block and absolute-path probes are
Linux/macOS-shaped, and (c) the smoke test path is short — duplicating
20 lines is cheaper than maintaining `bash` parity.

**How to apply**: any future addition to the Linux build-image
staging block (e.g. `.git/` layer, `cheatsheet-sources/`, etc.) MUST
also land in `init.rs`'s Windows block. The proposal flags this as a
follow-up: embed cheatsheets into the binary so both paths converge to
"emit from `embedded.rs` writers".

### D4. `tillandsias-logs` embed is a real bug fix, not Windows-only

**Decision**: add `FORGE_CLI_LOGS` to `embedded.rs` unconditionally;
write it from `write_image_sources()` and chmod 0755 on Unix. This
restores parity between `images/default/Containerfile` (which has the
COPY) and the embedded extraction (which lacked the file).

**Why**: on Linux the failure was masked by `scripts/build-image.sh`'s
fresh extraction at every build (the tar copy of the workspace happened
to also include the `cli/tillandsias-logs` file because the workspace
has it on disk, but the extraction-from-binary path used by the deployed
tray would have failed identically). Treating this as Windows-only would
defer the fix to a release.

### D5. No flag-set expansion for `build-local.sh`

**Decision**: don't expand `build-local.sh` to match `build.sh`'s full
flag set (`--release` / `--install` / `--remove` / `--wipe` / `--clean`
/ `--check` / `--test`). Only add the sidecar staging.

**Why**: scope discipline. The smoke test is `--install`-shaped; the
existing script already builds-and-installs. Flag parity is a
convergence improvement worth doing in its own change after the
control-plane Named Pipes work, when the Windows dev workflow's
contours are clearer.

## Verification

Smoke test on `windows-next` host (Windows 11, podman 5.8.2 + WSL):

```
PATH="/c/Users/bullo/.cargo/bin:$PATH" ./build-local.sh --install
TILLANDSIAS_WORKSPACE="C:\Users\bullo\src\tillandsias" \
  "$LOCALAPPDATA/Tillandsias/tillandsias.exe" --init
```

Expected output (verified 2026-04-26):

```
✓ proxy: tillandsias-proxy:v0.1.170.249
✓ forge: tillandsias-forge:v0.1.170.249
✓ git:   tillandsias-git:v0.1.170.249
✓ inference: tillandsias-inference:v0.1.170.249
Ready. Run: tillandsias
```

## Out of Scope

- Named Pipes implementation for the Windows control socket.
- Embedding `cheatsheets/` into the tray binary (today they're staged
  from `$TILLANDSIAS_WORKSPACE` or fall through to a placeholder).
- Flag parity between `build-local.sh` and `build.sh`.
- macOS native equivalents for any of the Windows-specific changes
  (macOS has its own `build-osx.sh` path and isn't broken).
- `build-windows.sh` (the Linux-host cross-compile path); it's
  separately tested by CI release.
