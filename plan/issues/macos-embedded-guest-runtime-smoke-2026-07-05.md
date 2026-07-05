# macOS embedded guest runtime smoke — 2026-07-05

- class: bug-fix+runtime-smoke
- filed: 2026-07-05T21:22:24Z
- owner: macos
- pickup_role: macos
- status: in_progress
- trace: spec:macos-tray-build-and-release, spec:vsock-transport, plan/issues/headless-secure-control-wire-image-refresh-2026-07-05.md

## Evidence

The local `osx-next` tray now builds a signed `dist/Tillandsias.app` with
embedded Linux guest binaries for both supported guest architectures:

- `Contents/Resources/guest/tillandsias-headless-aarch64-unknown-linux-musl`
- `Contents/Resources/guest/tillandsias-headless-x86_64-unknown-linux-musl`

`scripts/build-macos-tray.sh` and `scripts/build-macos-dmg.sh` both completed.
The styled DMG mounted read-only and contained `Tillandsias.app`, the
`Applications` link, the custom background, and both executable guest binaries.

Runtime smoke using the packaged app:

```text
dist/Tillandsias.app/Contents/MacOS/tillandsias-tray --exec-guest /bin/echo TILLANDSIAS_GUEST_OK
[exec-guest] running: ["/bin/bash", "-lc", "/bin/echo TILLANDSIAS_GUEST_OK"]
TILLANDSIAS_GUEST_OK
{"status":"ok","exit_code":0,"signal":null}
```

## Residual blocker

`--list-cloud-projects` reaches the guest control wire, then fails while
bootstrapping Vault:

```text
[tillandsias-vault] | {"msg":"exec container process `/usr/local/bin/tillandsias-vault-entrypoint.sh`: Operation not permitted","level":"error","time":"2026-07-05T21:21:32.279501Z"}
Error: vault container did not report healthy: Health command failed (status Some(125), retry Permanent): podman wait --condition=healthy tillandsias-vault
```

This local `osx-next` worktree has not yet merged the latest `origin/linux-next`
Vault/SELinux fixes (`a649ebf3`, `8e7f457a`) or the completed guest binary build
packet (`5af98306`, `c77c6001`). Next action: checkpoint the macOS packaging
slice, merge `origin/linux-next` into `osx-next`, reconcile the guest-binary
builder duplication, rebuild, and rerun:

```bash
dist/Tillandsias.app/Contents/MacOS/tillandsias-tray --list-cloud-projects
dist/Tillandsias.app/Contents/MacOS/tillandsias-tray --opencode /Users/tlatoani/src/tillandsias --prompt "date && git status --short --branch"
```

## Build warnings

The guest cross-compile emits pre-existing headless warnings for
`pty_handler.rs::RawFd` and unused cloud-project helper functions. They do not
block this macOS packaging slice, but they should be reduced in a Linux-owned
cleanup packet if the current scan bar starts treating build warnings as
findings.
