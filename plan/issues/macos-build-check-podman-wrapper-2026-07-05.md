# macOS build check uses Linux-only Podman wrapper flags — 2026-07-05

- class: bug-fix
- filed: 2026-07-05T21:25:00Z
- owner: macos
- pickup_role: macos
- status: ready
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
