---
tags: [tray, pty, vsock, macos, virtualization-framework, terminal-attach, tillandsias]
languages: [rust]
since: 2026-05-26
last_verified: 2026-05-26
sources:
  - internal
  - https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice
authority: internal
status: current
tier: bundled
---

# macOS PTY Attach (Open Shell / GitHub Login)

@trace spec:macos-native-tray, spec:vsock-transport, spec:macos-native-tray.invariant.terminal-attach-no-ssh

**Use when**: implementing or debugging the macOS tray's live PTY-over-vsock
attach for the Open Shell / GitHub login / Agent menu actions. This is the
v0.0.1 macOS answer to "drop the user into a shell running inside the VM
without using SSH."

## Provenance

Built across iters 15–25 of `plan/steps/20-macos-tray-v0_0_1.md` (m4
sub-task B). Final composition lands in commits `d45d6216` (Open Shell live
attach) and `41ea02e1` (GitHub login live attach), with foundations from
`681607e1` (`pty_vsock_bridge`), `9578691d` (`VzRuntime::open_vsock_stream`),
and `6d9a2201` (`connect_pty_bridge` handshake composer).

## The full chain (host-side)

```
                ┌── AppKit menu click ─┐
                │ ("Open Shell" /      │
                │  "GitHub login")     │
                ▼
   TrayActionHost::attach_pty(label, intent)
                │
                ▼  (Tokio runtime.spawn)
   run_pty_attach(vz, intent)  ────────────────────────────┐
                │                                          │
                │ ┌──────────────────────────────────┐     │
                ▼ │ vz.open_vsock_stream(            │     │
   VzRuntime::open_vsock_stream(port, timeout)       │     │
                │ │   port = CONTROL_WIRE_VSOCK_PORT │     │
                │ │   timeout = 30s                  │     │
                │ └──────────────────────────────────┘     │
                │  - clones the Mutex<Option<VmHandle>>    │
                │  - spawn_blocking → connect_to_vm_vsock  │
                │  - VsockStream::from_vsock_fd            │
                ▼                                          │
   VsockStream (AsyncRead + AsyncWrite)                    │
                │                                          │
                │                                          │
                ▼                                          │
   pty_vsock_bridge::connect_pty_bridge(stream, …)         │
                │                                          │
                │  - splits the stream (read/write halves) │
                │  - sends ControlEnvelope{seq=1, Hello}   │
                │    framed as [u32 BE length][postcard]   │
                │  - reads ControlEnvelope{HelloAck}       │
                │  - validates WIRE_VERSION                │
                │  - spawns writer_task (starts at seq=2)  │
                │  - spawns reader_task                    │
                ▼                                          │
   ChannelPtyTransport + BridgeJoin + wire_version: u16    │
                │                                          │
                ▼                                          │
   UnixPtyMaster::open(24, 80)                             │
                │  - openpty(3) + ptsname_r                │
                │  - O_NONBLOCK + AsyncFd                  │
                │  - master fd / slave path captured       │
                ▼                                          │
   launch_spec(intent, project, 24, 80)                    │
                │  - PtyIntent::Shell      → /bin/bash -l  │
                │  - PtyIntent::GithubLogin → gh auth login│
                │  - project=Some(p)       → wraps argv as │
                │    podman exec -it tillandsias-${p}-forge│
                │  - project=None          → bare-VM cmd   │
                ▼                                          │
   PtySession::open(transport, alloc, router, &opts)       │
                │  - allocates session_id                  │
                │  - sends ControlMessage::PtyOpen         │
                ▼                                          │
   pump_io(session, master)                                │
                │  - input task: master reader →           │
                │    PtyData{ToGuest} frames               │
                │  - output task: PtyData{ToHost} →        │
                │    master writer                         │
                ▼ (returns slave_path as Result)           │
   dispatch_to_main_thread(|| { … })  ─────────────────────┘
                │  (libdispatch dispatch_async_f
                │   via _dispatch_main_q)
                ▼
   terminal_attach::spawn_terminal_pty_attach(slave_path)
                │  - applescript_for_screen_attach(slave_path)
                │  - osascript -e 'tell application "Terminal"
                │      do script "screen /dev/ttysNN"
                │      activate'
                ▼
   Terminal.app window with `screen` attached to the slave PTY,
   bridged to /bin/bash (or gh auth login) inside the in-VM
   tillandsias-<project>-forge podman container.
```

## Why `screen <slave>` in Terminal.app

AppleScript can't natively attach Terminal.app to an external PTY device
(no `tty=<path>; exec <$tty >$tty` primitive in AS). `screen <slave_path>`
opens the slave device as a serial-style terminal, reading + writing the
device — which is the master fd that `pump_io` drives. `screen` ships with
every modern macOS (since at least 10.6), so no extra dependency.

Alternatives considered + rejected:
- **`script(1)`**: would work but creates a typescript file; clutters the UX.
- **iTerm2 cross-process attach via Python API**: requires extra setup;
  not portable to Terminal.app users.
- **Custom Cocoa terminal emulator embedded in the tray**: massive scope
  expansion; punted to v0.2+.

## Frame format

Matches the shared `tillandsias-host-shell::vsock_client::Client` framing
so the in-VM headless interop is unchanged:

```
┌────────────────┬─────────────────────────────────┐
│ u32 BE length  │ postcard-encoded ControlEnvelope │
└────────────────┴─────────────────────────────────┘
```

`MAX_MESSAGE_BYTES = 65_536` (control-wire crate constant). Larger frames
on either direction abort the reader/writer task.

## Seq coordination

Per-connection monotonic. `connect_pty_bridge` does the handshake at seq=1
(Hello/HelloAck), then the bridge writer task starts at seq=2 via
`spawn_pty_bridge_with_seq(stream, router, capacity, 2)`. Callers that did
their own handshake before handing the stream over should use
`spawn_pty_bridge_with_seq` directly; callers that want the composed
handshake-then-frame should use `connect_pty_bridge`.

## Cross-host alignment

Both macOS and Windows trays consume the same shared
`tillandsias_host_shell::pty::launch_spec(intent, project, rows, cols)` so
the in-VM target is identical:

- `project = Some(p)` → `podman exec -it tillandsias-${p}-forge <inner_argv>`
  → forge container (canonical target per
  `plan/issues/tray-convergence-coordination.md` 2026-05-26 alignment).
- `project = None` →  bare VM (Shell = debug escape hatch; GithubLogin =
  user-level pre-attach; Agent = invalid / disabled menu).

macOS today passes `project=None` until `MenuStructure` carries the active
project; once that lands, slice 5b' will surface the selection.

## Manual repro (gated on a booted VM with in-VM headless on port 42420)

```bash
# 1. Build + launch the tray.
./scripts/build-macos-tray.sh
open dist/Tillandsias.app

# 2. Tail stderr to watch the dispatch lifecycle.
tail -f /tmp/tillandsias-tray.stderr.log  # (or run binary directly to see stderr live)

# 3. Click Start VM → eventually menu flips Ready.

# 4. Click Open Shell → expected stderr:
#      [tillandsias-tray] Open Shell: spawning attach worker
#      [tillandsias-tray] Open Shell: PTY attached at /dev/ttys005
#    And: Terminal.app opens with `screen /dev/ttys005`.

# 5. Click GitHub login → same path with PtyIntent::GithubLogin →
#    Terminal.app window runs `gh auth login` device-code flow.

# 6. Spec invariant terminal-attach-no-ssh check:
#      pgrep -f ssh   # must return nothing (no SSH involved).
```

## Failure modes

| Symptom on click                                            | Probable cause                                                                                                     |
|-------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `Open Shell: no VM running. Start VM first.`                | `ivars.vm` is None — user hasn't clicked Start VM yet.                                                             |
| `vsock connect: VM not started`                             | Race — VM handle was taken between the `is_some` check and `open_vsock_stream`. Rare; click again.                 |
| `vsock connect: VZ connect error: …`                        | In-VM headless isn't listening on port 42420 (boot still in progress, or `tillandsias-headless` crashed).          |
| `control-wire handshake: wire version mismatch: …`          | In-VM headless built from an older recipe; `WIRE_VERSION` skew. Rebuild + republish the recipe artifact.           |
| `openpty: …`                                                | Host-side PTY allocation failed (rare; usually fd exhaustion).                                                     |
| `PtyOpen: PtyOpen requires a non-empty argv`                | `launch_spec` returned empty argv — bug.                                                                           |
| Terminal.app opens but stays blank                          | `screen` not on `$PATH` for the user's login shell, OR the slave device closed before `screen` opened it.          |

## Gating chain

For first-launch UX to work end-to-end:
1. Linux's recipe-publish CI run succeeds (currently failing on rootless
   buildah's `/tmp` not being exposed — see integration loop 2026-05-26).
2. CI uploads `tillandsias-rootfs-aarch64.img` to the GitHub release.
3. CI emits the aggregate SHA256SUMS; maintainer commits the pinned SHA
   into `images/vm/manifest.toml [output.expected_rootfs_sha]`
   (replaces `"pending-ci"`).
4. Tray rebuild bumps `CARGO_PKG_VERSION` to include the new SHAs (the
   manifest is embedded via `include_str!` at compile time).
5. First user `Start VM` click: `fetch_recipe_artifact` resolves the URL
   from `manifest.artifact_url(...)`, downloads, verifies the SHA, writes
   to `~/Library/Application Support/tillandsias/rootfs.img`.
6. `VzRuntime::start` boots; `wait_ready` completes Hello/HelloAck on
   vsock 42420; menu flips Ready.
7. User clicks Open Shell → the chain above runs → Terminal.app appears.

## Test coverage

Unit tests live alongside each layer:

- `pty_vsock_bridge`: `tokio::io::duplex` round-trips for writer framing,
  reader routing, and the full handshake composer (3 tests).
- `terminal_attach`: AppleScript escaping + screen-attach envelope shape
  (4 tests covering escape edge cases).
- `action_host::run_start_reports_pending_sha_until_l9_step5`: verifies
  the SHA gate fails gracefully when manifest still has `"pending-ci"`.
- `vz::open_vsock_stream_errors_when_vm_not_started`: gates the no-VM path.
- `vz::fetch_recipe_artifact_*` (2 tests): gating for missing template
  + placeholder-SHA refusal.

E2E exercise is gated on m5 (a booted VM with reachable in-VM headless);
once that lands, `m8/appkit-action-smoke-and-stub-polish` covers the
manual 7-step click-through smoke (see `plan/issues/osx-next-work-queue-
2026-05-25.md`).
