# macOS build check uses Linux-only Podman wrapper flags — 2026-07-05

- class: bug-fix
- filed: 2026-07-05T21:25:00Z
- owner: macos
- pickup_role: macos
- status: done
- trace: spec:dev-build, scripts/common.sh

## Finding

On macOS with Homebrew Podman installed at `/opt/homebrew/bin/podman`,
`./build.sh --check` fails in `require_podman` before the Rust check starts:

```text
ERROR: podman must be installed and available on PATH
```

The generated wrapper is the real failure:

```text
/var/folders/.../tillandsias-podman-wrapper/podman --version
Error: unknown flag: --root
See 'podman --help'
```

`scripts/common.sh` builds a local wrapper that always passes Linux storage
flags (`--root`, `--runroot`, `--tmpdir`) to Podman. Homebrew Podman on macOS is
a remote-machine client and rejects those flags, even though `podman --version`
itself works.

## Impact

The macOS packaged tray and runtime smoke can pass while the repository-wide
`./build.sh --check` integration gate is unavailable on this host. This is a
host-wrapper compatibility bug, not a Rust compile failure.

## Next action

Teach `scripts/common.sh` to detect Darwin/Homebrew Podman and avoid generating
the Linux storage wrapper there, or route through the supported macOS Podman
machine connection. Verification should prove:

```bash
PATH="/opt/homebrew/bin:$PATH" ./build.sh --check
```

starts the actual cargo check phase on macOS instead of failing in
`require_podman`.

## Fixed — 2026-07-06T17:15Z (order 201)

Root cause confirmed exactly as diagnosed: Homebrew Podman on macOS is
ALWAYS a remote-machine client (never supports `--root`/`--runroot`/
`--tmpdir`, even when a machine happens to be running). The wrapper-
selection logic in `scripts/common.sh` required a `podman info`
connectivity probe to succeed before skipping the Linux-storage wrapper;
when it failed (e.g. no machine currently running, as on this dev host),
macOS fell through to the local-VFS-wrapper branch and hit the flag
rejection. Fixed by having macOS unconditionally take the "skip the
wrapper, use direct podman" branch (unless an explicit
`TILLANDSIAS_PODMAN_REMOTE_URL`/`CONTAINER_HOST` override forces
otherwise) — matching how its Podman client actually behaves. A macOS host
with no machine running now gets Podman's own honest "no machine running"
error immediately, instead of a confusing flag-rejection failure.

That fix unblocked `./build.sh --check` far enough to reach real
compilation for the first time on this macOS host, which surfaced 2 more
`-D warnings` blockers in Linux-owned crates — both the same shape (a
helper whose only non-test caller lives inside a
`#[cfg(target_os = "linux")]` block, so a non-Linux build sees it as
dead/unused code): `tillandsias-podman::path_is_writable` (was gated
`unix`/`not(unix)`, but its only caller is Linux-gated — regated to
`target_os = "linux"` and dropped the pointless stub) plus
`require_desktop_user_session`/`require_headless_service_account`'s
`operation` parameter, and `tillandsias-headless::vault_bootstrap::vault_service_base_url`.
Fixed with minimal, platform-scoped `#[cfg_attr(not(target_os = "linux"),
allow(...))]` attributes — no behavior change on Linux. Marked "PLEASE
REVIEW (linux)" per the unblock-with-NOOP convention since these are
Linux-owned crates.

**Verified**: `./build.sh --check` now exits 0 on macOS — fmt check,
type-check, and strict clippy all pass. This is the first time that
command has completed successfully on this host. `cargo test -p
tillandsias-podman -p tillandsias-headless`: all pass except
`test_missing_image_error_handling`, which requires an actual running
Podman machine connection (none is running on this dev host — a pre-
existing environment gap, not caused by this fix; see the sibling note in
`plan/issues/litmus-full-suite-macos-first-run-findings-2026-07-06.md` for
the same class of macOS-has-no-running-Podman-session gap).

Commit: `be2968c5` on `osx-next`.
