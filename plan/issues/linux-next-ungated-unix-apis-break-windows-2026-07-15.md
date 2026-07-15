# linux-next un-gated unix-only APIs break the Windows workspace compile (enhancement)

Filed: 2026-07-15T06:05Z, windows-bullo-fable5-20260715T0523Z (windows lane)
Class: enhancement (cross-target verification gap)

## What happened

Order 357's catalog slice (b1404180, linux-next) added three unix-only usages
to `crates/tillandsias-headless/src/main.rs` without cfg gates:

- `use std::os::unix::net::UnixStream;` (import, un-gated while the sibling
  `std::os::unix::process::CommandExt` import right below it IS gated)
- `libc::getuid()` in `control_socket_host_dir()` (the `/run/user/<uid>`
  fallback)
- `libc::getuid()` + `UnixStream::connect` in `send_issue_web_session()`

`./build.sh --check` on Linux compiles only the Linux cfg universe, so
linux-next stayed green while every Windows checkout of the workspace broke
with E0433/E0425 (3 errors). The Windows lane inherited the breakage through
the mandated pre-push merge of origin/linux-next and repaired it forward on
windows-next (cfg gates + two `PLEASE REVIEW: linux` stubs: probe returns
"not listening", OTP handoff returns Err — both are the correct no-control-
socket behaviors on Windows).

## Why it matters

- The pre-push merge cadence means ANY un-gated unix API in linux-next stalls
  every sibling-platform cycle at its integration gate (or worse, lands
  broken if the gate is fumbled — see near-miss below). This is the
  cross-platform twin of the E0428/orphan-marker incidents the Integration
  Verification Gate was written for.
- Windows/macOS host code reviews cannot prevent it; only the Linux-side
  check can, at authoring time.

## Smallest next action (linux lane)

Add a cross-target cfg probe to the Linux pre-push/CI path, e.g.
`rustup target add x86_64-pc-windows-gnu` (std only, no linker needed for
`cargo check`) + `cargo check --workspace --target x86_64-pc-windows-gnu`,
or at minimum a litmus greping headless/podman/core crates for un-gated
`std::os::unix`/`libc::getuid|geteuid|fork|exec` outside `#[cfg(unix)]`
items. Verifiable constraint: the check fails loud on exactly the three
sites this issue documents when the fix commit is reverted.

## Near-miss to not repeat (windows lane process note)

The windows cycle's substitute compile gate (`cargo check --workspace 2>&1 |
tail`) reported the PIPE's exit status, not cargo's — `echo $?` after a pipe
is the tail exit. The broken tree was pushed before the failure was noticed
(repaired ~15 min later on the same branch). Rule for non-build.sh hosts:
capture `${PIPESTATUS[0]}` (bash) or run the check unpiped; the gate verdict
must come from the compiler process itself.
