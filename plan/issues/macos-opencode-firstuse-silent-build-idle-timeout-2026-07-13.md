# P1: first-use macOS `--opencode` can never succeed — silent in-guest forge image build trips the 300s vsock idle timeout, and the lane tears the VM down mid-build

- Date: 2026-07-13
- Class: bugfix (P1 on the macOS forge lane cold path)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-13T22:43Z
- Discovered by: /build-install-and-smoke-test-e2e (macos), §4 forge lane, tray git 66d8b134
- Related: order 270 (macos-attach-first-use-materialization-blackout — the UX half of this), Windows sibling finding "windows-attach silent forge-base build" (2026-07-12 cycle), crates/tillandsias-vm-layer/src/vsock_exec.rs:195/317/555
- Pickup: linux (vm-layer + headless are shared code; macOS host verifies)

## Repro (live, cold substrate, 2026-07-13)

```
$ tillandsias-tray --opencode /home/forge/src/tillandsias --prompt "Use the /meta-orchestration skill"
[opencode] starting VM…
[opencode] waiting for VM phase Ready…
[opencode] control wire ready; launching forge in guest…
tillandsias-egress
tillandsias-enclave
{"error":"opencode: vsock_exec: no data from guest for 300s — connection stale"}
```

Exit 1 after ~6.5 min. Host-side sampling during the window shows the guest
hard at work the whole time (VZ XPC process pinned at ~200% CPU, guest disk
grown to 4.6 GiB) — the "stale" connection is actually a healthy guest
building `forge-base` with its build output not routed to the exec stream.

Evidence: target/build-install-smoke-e2e/20260713T224400Z/
04-bigpickle-meta-orchestration.log + monitor-host-samples.log
(22:51-22:57Z window).

## Why this is fatal, not cosmetic

- `exec_over_stream_with_input_streaming` enforces `IDLE_TIMEOUT_SECS = 300`
  (vsock_exec.rs:195, 317, 555 — three copies of the constant).
- The first-use forge-base build on a 4-vCPU aarch64 guest takes well over
  300s and emits nothing on the stream after the two network-create lines.
- On timeout the lane calls `vz.stop()` — killing the build mid-flight. The
  next attempt restarts the build with cold layer cache; if it also exceeds
  300s of silence, the loop never converges. First-use `--opencode` on
  macOS is structurally dead on arrival.

## Fix directions (complementary, pick at least 1+2)

1. **Stream the build**: headless `--opencode` path must route
   `podman build` progress (or at minimum a heartbeat line per layer/step)
   to its stdout/stderr so the exec stream sees liveness. This is also
   order 270's ask — same fix serves both.
2. **Liveness ≠ output**: the idle timeout should distinguish "no bytes"
   from "peer dead". A cheap wire-level heartbeat (control-wire ping or
   zero-byte keepalive frame every 60s while the guest process is alive)
   makes the 300s constant safe regardless of workload verbosity.
3. Deduplicate `IDLE_TIMEOUT_SECS` (three literal copies) into one
   constant, env-overridable for constrained hosts.

## Workaround used by this cycle (idiomatic, no boundary hacks)

Pre-build via the control-wire exec layer with streamed output, then attach:

```
tillandsias-tray --exec-guest /bin/bash -lc "… tillandsias-headless --debug --init"
tillandsias-tray --opencode /home/forge/src/tillandsias --prompt "…"
```

## Verifiable closure

- litmus: cold-substrate `--opencode` on a guest with no
  `localhost/tillandsias-forge*` images reaches the agent prompt without
  tripping the idle timeout (or fails loud with an actionable pre-build
  instruction), pinned on Linux CI with a synthetic slow-build fixture.

## Implementation checkpoint (2026-07-14, Linux)

- `vsock_exec.rs` now owns one `IDLE_TIMEOUT_SECS = 300` policy and the
  `TILLANDSIAS_VSOCK_EXEC_IDLE_TIMEOUT_SECS` override. Invalid values and
  values below 60 seconds fail loudly.
- Exec clients advertise `pty.heartbeat@v1`; the guest emits empty
  `PtyData{ToHost}` frames every 30 seconds only after that capability is
  negotiated. Interactive clients therefore receive no new frames during a
  mixed-version rollout, and host terminal routing defensively ignores empty
  data.
- `litmus:vsock-exec-heartbeat` passes 4/4. Its synthetic guest remains silent
  beyond multiple injected idle windows, stays live on heartbeats, delivers
  the eventual output/close, and still times out when no frame arrives.
- Missing on-demand images now print an unconditional build-start line before
  the currently buffered Podman build call, giving the operator immediate
  progress evidence and partially serving order 270.

The remaining completion gate is the original cold-substrate macOS run: remove
all forge images, launch `--opencode`, observe at least one negotiated
heartbeat interval, and confirm the agent prompt is reached without VM teardown.
