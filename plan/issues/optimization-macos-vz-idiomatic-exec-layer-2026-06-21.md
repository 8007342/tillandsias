# Optimization/Research — macOS Virtualization idiomatic exec + simplified terminal launch — 2026-06-21

**Filed:** 2026-06-21 (operator-directed, interactive macOS session)
**Kind:** optimization + research (partially-defined; reduction engine to refine)
**Status:** ready (research sub-tasks) / needs_clarification (final design)
**Trace:** `spec:macos-native-tray`, `spec:vm-idiomatic-layer`,
`spec:vsock-transport`, `openspec/changes/control-wire-pty-attach`,
[[macos-tray-github-login-blank-terminal-2026-06-21]]

## Operator framing

Linux runs guest commands via an idiomatic Rust layer over `podman run/exec`;
Windows via idiomatic WSL2 (`wsl --exec` → podman). macOS should have the
**equivalent idiomatic Virtualization.framework layer**, not a hand-rolled
host-PTY ↔ vsock ↔ `screen /dev/ttysNNN` bridge. "Launching a terminal should
not be this hard" — the current fragility means we are doing it wrong. Step
back, research the macOS virtualization layer, and SIMPLIFY the terminal launch.

## Key finding — the idiomatic layer already exists; macOS doesn't implement it

There IS a unified cross-platform trait (`crates/tillandsias-vm-layer/src/lib.rs`):

```rust
#[async_trait::async_trait]
pub trait VmRuntime: Send + Sync {
    async fn provision(&self, manifest: &ProvisionManifest) -> Result<(), VmError>;
    async fn start(&self) -> Result<(), VmError>;
    async fn stop(&self, drain_timeout: Duration) -> Result<(), VmError>;
    async fn exec(&self, argv: &[&str]) -> Result<std::process::ExitStatus, VmError>;
    async fn wait_ready(&self, timeout: Duration) -> Result<(), VmError>;
}
```

- **Windows** `WslRuntime::exec` (`wsl.rs`): shells to `wsl --distribution <d> --exec <argv>`. Implemented.
- **Linux** `FakeVmRuntime::exec` (`fake.rs`): runs argv on host for tests. Implemented.
- **macOS** `VzRuntime::exec` (`vz.rs`): **`Err("VzRuntime::exec ... phase-5 placeholder")` — UNIMPLEMENTED.**

The macOS tray **bypasses the trait entirely**: `action_host.rs::run_pty_attach`
calls the macOS-only `VzRuntime::open_vsock_stream` directly, builds a host
`UnixPtyMaster`, sends a `PtyOpen` over vsock to the in-VM `pty_handler`, runs
`pump_io`, then spawns Terminal.app running `screen <slave>` via
`terminal_attach.rs`. That is the fragile, hand-rolled path that flashes-and-dies.

### Hacks in the current path (from codebase audit, cite file:line)

- `pty_handler.rs:121-128` — `Command::new(argv[0])` + `env_clear()` with only
  `TERM` re-added → **no PATH**; bare-name argv (`gh`, `tillandsias`, `podman`)
  cannot resolve; spawn error not surfaced to the PTY (silent blank).
- `pty/unix.rs:226-230` — `split()` drops the retained slave fd; macOS master
  then returns **EIO** until `screen` re-opens the slave (the pre-attach race;
  partially mitigated by `ATTACH_GRACE` in `pump_io`, but symptom persists).
- `terminal_attach.rs:257-264` — `osascript … do script "screen <slave>"` is
  fire-and-forget; `screen` on an externally-managed PTY device terminates
  immediately ("[screen is terminating]") with no error surface.
- `action_host.rs:993,1010` — bridge/pump JoinHandles discarded (`_bridge_join`,
  `_pump_join`); lifecycle relies on detached tasks + EOF.
- Guest binary is `/usr/local/bin/tillandsias-headless` (vz.rs/wsl.rs), but
  `launch_spec` agent intents still use bare `tillandsias` (won't resolve).

## Target (what "idiomatic" means here)

1. **Implement `VzRuntime::exec`** over the vsock control-wire (non-TTY:
   stream stdio + propagate exit code), mirroring `WslRuntime::exec`.
2. **Add an interactive/TTY guest-attach** primitive in the vm-layer (e.g.
   `VmRuntime::attach_interactive(argv) -> ...`) so the tray asks the idiomatic
   layer for an attached shell instead of hand-rolling PTY+screen.
3. **Simplify terminal launch.** Strong candidate (needs the pending web
   research): Terminal.app/iTerm2 runs a single command that owns its OWN
   controlling tty — e.g. `ssh` over a vsock ProxyCommand (the guest sshd gives
   native PTY; boot banner already advertises `ssh vsock%3`), or a tiny
   `tillandsias attach` client that bridges its own tty over vsock. This removes
   the host `UnixPtyMaster` + `screen <slave>` contraption entirely.

## Sub-tasks (verifiable closure; partially-defined)

- `macos-vz/research-ecosystem` (research) — RE-RUN the web research (the two
  web agents hit a session limit before reporting): how lima/colima, Apple's
  `Virtualization` sample, vfkit, krunkit, podman-machine applehv, Tart, UTM,
  and `apple/containerization` run guest commands and attach a terminal (SSH
  over vsock? virtio-console? guest agent?). Closure: a cited comparison report
  filed here with a recommended idiomatic approach. **(do first)**
- `macos-vz/terminal-launch-options` (research) — diagnose why `screen
  <externalPTY>` self-terminates on macOS; rank simpler launch mechanisms
  (Terminal `do script "ssh …"`, vsock ProxyCommand via socat, an attach
  client). Closure: a decision record with the chosen mechanism + rationale.
- `macos-vz/impl-exec` (optimization) — **DONE (protocol slice), 2026-06-22.**
  Implemented `VzRuntime::exec` over the control wire via a new self-contained
  client `crates/tillandsias-vm-layer/src/vsock_exec.rs` (`exec_over_stream`):
  `Hello`/`HelloAck` → `PtyOpen(argv)` → drain `PtyData{ToHost}` → `PtyClose`
  exit. Self-contained because `host-shell` depends on `vm-layer` (no reuse of
  the host-shell PTY bridge without a cycle). macOS `VzRuntime::exec` wires
  `open_vsock_stream` → `exec_over_stream` → `ExitStatus` (unix `from_raw`).
  Closure MET at the protocol level: 3 unit tests (happy path asserts
  `stdout=="HELLO\n"` + exit 0, non-zero exit propagation, empty-argv reject)
  against an in-memory duplex fake guest — `cargo test -p tillandsias-vm-layer`
  18/18 PASS, no real VM needed. Mirrors `WslRuntime::exec` for parity.
- `macos-vz/impl-exec-integration` (optimization) — **DONE, 2026-06-22.**
  Real-path proof on a booted VM via a new headless `--exec-guest <argv...>`
  tray mode (`diagnose::exec_guest_main`): boots the VM, waits ready, runs the
  command in the guest over the control wire, prints output + exit, stops.
  Result: `tillandsias-tray --exec-guest /bin/echo HELLO-FROM-GUEST` →
  `HELLO-FROM-GUEST` + `{"status":"ok","exit_code":0,"signal":null,
  "stdout_bytes":18}`. **Confirms the whole control-wire + guest `pty_handler`
  path works end-to-end on macOS** (Hello→PtyOpen→PtyData→PtyClose, guest spawns
  + runs + returns output/exit).
  - **Defect found + fixed in the same slice (`macos-vz/headless-vsock-connect`):**
    the first attempts timed out at the exec vsock connect (30s) on BOTH cold and
    warm boots. Root cause: VZ delivers `connectToPort:` completion on the **main
    dispatch queue**, serviced only while the main thread pumps the CFRunLoop.
    `open_vsock_stream` offloads the connect to `spawn_blocking` — fine for the
    tray (NSApp pumps the main runloop) but it hangs a headless caller that parks
    the main thread in `block_on`. Added `VzRuntime::open_vsock_stream_current_thread`
    (connect on the calling/main thread; established socket I/O stays
    reactor-driven) and used it in `--exec-guest`. `wait_ready` already connected
    on the main thread, which is why it passed while the worker-thread connect
    timed out — the diagnostic that pinpointed the cause.
  - Closure MET: live real-VM run returns the guest's stdout + exit 0.
  - Follow-up (optional): wire `--exec-guest /bin/echo` as a post-provision step
    in the macOS `/build-install-and-smoke-test-e2e` gate for a standing
    real-path regression check.
- `macos-vz/exec-stdin` (optimization) — **DONE, 2026-06-22.** Added
  `vsock_exec::exec_over_stream_with_input` (delivers a fixed `input` to the
  guest child's stdin + `/dev/tty` via `PtyData{ToGuest}` after `PtyOpen`, then
  drains output). `--exec-guest` forwards piped host stdin. **Decision: NO
  ssh-over-vsock** — the proven control-wire exec path covers one-shot exec and
  near-interactive (single-value) flows like the github-login token paste.
  Closure MET: unit test `exec_over_stream_with_input_delivers_stdin` +
  **real-VM proof** `printf 'PINGPONG-SECRET\n' | tillandsias-tray --exec-guest
  /bin/bash -lc 'read -r X; echo "GOT:[$X]"'` → `GOT:[PINGPONG-SECRET]`, exit 0.
  This is the EXACT pattern `run_github_login`'s `read -rs TOKEN < /dev/tty`
  uses — the token-paste keystone, proven, with the token never in argv.
- `macos-vz/finalize-github-login` (optimization, NEXT — needs operator PAT) —
  add a NON-interactive guest login entry (token from stdin; git identity from
  env/existing config — `run_github_login` currently reads name+email via stdin
  prompts then the token via /dev/tty, brittle to feed blind), and a headless
  `tillandsias-tray --github-login` that boots the VM and drives it via
  `exec_over_stream_with_input` with the PAT. Cannot be verified without a real
  GitHub PAT + network (and must not auth the operator's account unprompted), so
  the final step is operator-attended. Closure: `printf '<PAT>\n' |
  tillandsias-tray --github-login` writes the token to the guest Vault and the
  tray status poll flips logged-out → logged-in.
- `macos-vz/finalize-github-login` — **IN PROGRESS (operator-attended).** Built
  headless `tillandsias-tray --github-login`: prompts each end user for THEIR
  OWN git name/email/PAT (token echo suppressed via `stty -echo`; nothing
  defaulted from the operator's host config), boots the VM, and drives the
  released guest `--github-login` via `exec_over_stream_expect`. First live run
  (operator) surfaced two concrete defects, both fixed:
  - **desktop-session gate**: guest `--github-login` errored
    `requires a real desktop user session with a writable XDG_RUNTIME_DIR`. The
    control-wire exec env is cleared, so the lane is `DesktopUserSession` but
    `XDG_RUNTIME_DIR` is unset. Fix: the login wrapper now
    `export XDG_RUNTIME_DIR=/run/user/0; mkdir -p` before exec.
  - **terminal escape spill** (`^[[37;1R`, `+q6E616D65`): the guest serial getty
    probes the terminal (DSR/XTGETTCAP); `vz.rs` routed guest serial to host
    **stderr** (`serial_writer_fd: None` → dup STDERR), so those queries reached
    the operator's Terminal, which replied with CPR that then spilled into zsh
    after exit. Fix: `VzRuntime::set_serial_to_log(true)` routes guest serial to
    `console.log` for the headless CLI modes (tray unchanged). Filed as the
    terminal-management defect the operator flagged.
  - **HOME gate**: next run failed `HOME is not set` (git-identity write needs
    $HOME). Wrapper now also `export HOME=/root`. Confirmed working —
    `Git identity saved: /root/.cache/tillandsias/secrets/git/.gitconfig`.
  - **Now blocked at Vault bootstrap**: the flow reaches `[tillandsias-vault]
    bootstrap starting`, pulls the vault image, then `Error: vault did not become
    healthy within 60s`. This is a **guest-side** issue (`wait_for_vault_ready`,
    released binary, shared with Linux/forge) — NOT a macOS-driving bug. Tracked
    separately in [[macos-github-login-vault-bootstrap-timeout-2026-06-22]].
  - **Progress**: `--github-login` now drives the released guest flow correctly
    through 5 cleared blockers (gate → serial → identity prompts → HOME →
    networks/vault-pull). The macOS exec/expect/serial/env plumbing is proven;
    the remaining blocker is guest Vault bring-up.
  - Token-at-rest: handled by the released `--rm` ephemeral container; cross-host
    verification filed as [[github-login-token-at-rest-audit-2026-06-22]].
- `macos-vz/impl-attach-interactive` (optimization) — a LIVE bidirectional shell
  (Open Shell) still needs a terminal bridge (the one-shot exec+input path does
  not stream interactive I/O). Lower priority than login. Closure: a usable,
  non-self-terminating interactive shell in Terminal.app.
- `macos-vz/guest-no-path-fix` (optimization) — **DONE, 2026-06-22.** Fixed the
  foundational guest defect: `pty_handler` `env_clear()`'d the child with no
  `PATH`, so bare-name argv (`gh`, `podman`, `tillandsias-headless`) failed
  ENOENT (the blank-terminal root cause). Added `child_env()` which seeds a sane
  default `PATH` (`/usr/local/sbin:…:/bin`) when the caller supplies none, while
  preserving the no-host-env-leak intent. Also made the `TIOCSCTTY` ioctl cast
  portable so the guest handler compiles + unit-tests on a macOS dev host (the
  sole macOS worker can now verify guest logic locally). Closure MET: 3
  `child_env` unit tests + full `pty_handler` suite green on macOS (5 passed, 0
  failed, 2 pre-existing ignores). This unblocks BOTH `exec` and the interactive
  attach to actually resolve commands in the guest.
- `macos-vz/retire-hacks` (optimization) — once attach is idiomatic, remove the
  host `UnixPtyMaster`+`screen` bridge and the `pump_io` EIO grace hack if no
  longer needed; fix the `pty_handler` no-PATH defect or make it moot. Closure:
  the fragile path is deleted and tests/litmus stay green.

## Notes

- This supersedes the point-fixes in
  [[macos-tray-github-login-blank-terminal-2026-06-21]] (argv parity + EIO
  tolerance) — those remain as interim robustness but the real fix is the
  idiomatic layer.
- Methodology allows this packet to remain partially-defined; the
  `/meta-orchestration` reduction engine refines the design sub-tasks into
  concrete, verifiable slices over successive cycles.
