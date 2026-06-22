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
- `macos-vz/impl-exec-integration` (optimization, NEXT) — exercise
  `VzRuntime::exec` against a **booted** VM: `start()` → `exec(["/bin/echo","HELLO"])`
  → assert stdout/exit. This is the real-path proof (uses absolute argv to dodge
  the guest `pty_handler` no-PATH defect). Closure: a gated integration test or
  a smoke step on a macOS host with a provisioned VM.
- `macos-vz/impl-attach` (optimization) — implement the interactive attach via
  the chosen mechanism; rewire the tray's GitHub-login / Open-Shell / agent
  intents to use it. Closure: AX smoke (`scripts/macos-tray-ax-smoke.sh`) shows
  a usable, non-self-terminating shell/login prompt; GitHub login reaches the
  paste-token prompt and the status poll flips to LoggedIn.
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
