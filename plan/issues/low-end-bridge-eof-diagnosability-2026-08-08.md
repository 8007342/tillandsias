# low-end-bridge-eof-diagnosability — socat bridge failures collapse into bare "early eof" on slow hosts

Filed 2026-08-08 from the Intel N100 field host. Deliverable for the packet of
the same id.

trace: order 312 (non-elevated transport fallback), order 291 (stderr capture),
crates/tillandsias-vm-layer/src/transport_windows.rs

## Why

The non-elevated control-wire path is `wsl.exe -d tillandsias -- socat STDIO
VSOCK-CONNECT:1:42420`; startup death is only detected within
`BRIDGE_STARTUP_GRACE = 250ms`. On N100-class hardware `wsl.exe` launch latency
alone exceeds the grace window, so EVERY distinct socat failure (no listener,
`vsock_loopback` missing → `Network is unreachable`, socat absent, distro
stopped) degrades to the handshake's bare `early eof`. This is exactly why the
July–August field logs on this host show hundreds of undiagnosable
`handshake: early eof` lines with the real cause (`connect ... Network is
unreachable`) surfacing only twice, when a race happened to catch the exit.

## Fix (implemented this session)

`transport_windows.rs`: `WslStdioBridge` now keeps the shared stderr capture
buffer, and `poll_read` distinguishes EOF-with-dead-child: when the stream
returns EOF and `child.try_wait()` reports a non-zero exit, the read fails with
`wsl stdio bridge exited (<status>): <captured stderr>` (still
`ErrorKind::UnexpectedEof`) instead of a clean EOF. Best-effort by design: a
child not yet reapable leaves the clean EOF standing, and exit-0 EOFs (normal
close) are unchanged.

## Exit criteria / follow-ups

- [ ] On this host, a deliberately broken guest (listener stopped) produces a
      handshake error naming socat's stderr, not bare "early eof".
- [ ] Follow-up (ready): consider scaling BRIDGE_STARTUP_GRACE with observed
      wsl.exe spawn latency, or removing the upfront sleep entirely now that
      EOF-time attribution exists (saves 250ms per wire open).
- [ ] Follow-up (ready): a litmus pinning the enriched error shape.

## Evidence / handoff

- Branch: code on windows-next; this note + fragment on linux-next.
- Owned files: crates/tillandsias-vm-layer/src/transport_windows.rs.
- Next action: verify via the local build's first failing connect attempt (if
  any) or a forced-stop fixture; append the observed error line here.
