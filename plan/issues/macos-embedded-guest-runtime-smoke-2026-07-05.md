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

## Update 2026-07-06T17:25Z — old next-action done, NEW blocker found (local machine, not code)

`osx-next` has since merged `origin/linux-next` many times over (most recently
`5a4985d1`), so the "merge linux-next" next-action above is stale/satisfied.
But re-running the smoke itself is not currently possible on this dev
machine: there is no way to get a Podman connection at all right now.

- `podman machine list` shows `podman-machine-default` exists (created 6 days
  ago) but has **never been started** ("LAST UP: Never").
- `podman machine start` fails: `Error: exec: "krunkit": executable file not
  found in $PATH`. `krunkit` (the libkrun hypervisor helper Homebrew Podman's
  `libkrun` provider needs on this Mac) is not installed and is not in
  Homebrew core (`brew search krunkit` finds nothing) — it ships via a
  third-party tap (e.g. `slp/krunkit`) or Podman Desktop, neither of which is
  installed here.
- This is the same root cause behind `scripts/e2e-preflight.sh eligibility`
  returning `skip:no-podman-user-session` all cycle, and behind
  `cargo test -p tillandsias-headless`'s `test_missing_image_error_handling`
  failure (see order 201) — every macOS finding this cycle that needed a live
  Podman connection hit this same wall.

**This is a one-time local dev-machine setup gap, not a repo bug.** Installing
a third-party Homebrew tap to get a hypervisor backend running is outside
what an unattended agent cycle should do unprompted (adding an unofficial
tap + a system-level hypervisor component). Left `status: blocked` with the
precise next action for whoever has hands-on access to this machine:

```bash
brew tap slp/krunkit   # or install Podman Desktop, which bundles krunkit
brew install krunkit
podman machine start
# then re-run the smoke commands in "Residual blocker" above
```

No code or plan changes needed here beyond this note — this ticket stays
blocked until a human runs the krunkit bootstrap once on this machine.
