# Transport layer overhead audit — negligible overhead guarantee

**Order 137** — filed 2026-06-30

## Context

The current host↔guest transport stack (HvSocket → tokio TcpStream → postcard
framing → ControlMessage routing) adds layers. As more commands flow through
it (GitHub login, PTY attach, status polling), we must guarantee that the
overhead of these layers is negligible vs. the work being done.

The user's concern: "Our layers should add a NEGLIGIBLE OVERHEAD at any time."
Wire-degraded/recovered oscillations were observed during testing — these are
caused by the in-VM headless process crashing/restarting (process stability),
NOT by buffer underruns or backpressure on the transport layer itself. Both
concerns are tracked here.

## Current architecture

```
Host (Windows)                   Guest (Fedora / systemd)
┌────────────────────────┐        ┌─────────────────────────┐
│ notify_icon.rs         │        │ tillandsias-headless     │
│  - LIVE_CLIENT (persistent)     │  - control_wire listener │
│  - refresh every 30s   │◄──────►│  - PtyOpen handler      │
│  - spawn_wsl_terminal  │        │  - VmStatus poll         │
└────────────────────────┘        └─────────────────────────┘
        │ AF_HYPERV (HvSocket) ←→ AF_VSOCK (vsock port 42420)
        │ one persistent TCP stream per LIVE_CLIENT lifetime
        │ new connection on each LIVE_CLIENT miss (wire down)
```

### What is NOT overhead

- One HvSocket connection per "LIVE_CLIENT alive" period (not per request)
- Postcard framing: length-prefixed, zero-copy decode, O(1) per message
- The 30s polling interval is coarse-grained by design (not tight-loop)

### What IS a problem (wire oscillation)

The "wire degraded / wire recovered" oscillation seen 2026-06-30 is caused by
the in-VM headless SERVICE crashing and restarting, not by transport buffering.
Evidence: each oscillation maps to one LIVE_CLIENT teardown + reconnect. The
headless likely crashes because Vault or podman is not yet stable when it tries
to initialize.

**Separate tracking**: headless startup stability → investigate why headless
crashes during "Ready" phase (possibly Vault TLS cert not yet provisioned, or
a missing XDG_RUNTIME_DIR in the service unit).

## Overhead guarantees to enforce

| Layer | Requirement | How to verify |
|-------|-------------|---------------|
| HvSocket connect | Amortized over connection lifetime (not per-request) | LIVE_CLIENT persists until failure; single reconnect on drop |
| Postcard framing | O(1) per message, no dynamic allocation in the hot path | Code audit: postcard::from_slice is zero-copy |
| Status poll | ≤1 poll per 30s while wire is healthy; zero extra polls while degraded | No tight-loop retries in refresh_vm_status |
| GitHub-login exec | Single HvSocket round-trip per `--github-login` invocation | No polling inside the exec path |
| PTY frames | Bounded channel (SESSION_CHANNEL_CAPACITY=256) prevents unbounded buffering | Already implemented in PtyRouter |

## Audit exit criteria

- [ ] Confirm LIVE_CLIENT is truly persistent (not re-opened on every poll tick)
- [ ] Confirm no tight-loop retries in `refresh_vm_status` or `refresh_github_login`
- [ ] Profile: postcard decode path has no heap allocation in steady state
- [ ] Document: "transport layers add O(1) framing overhead per message, amortized
      O(0) connection setup overhead in steady state"
- [ ] Investigate and fix headless-crash root cause causing wire oscillations
- [ ] Add `litmus:no-polling-noops` — assert no `loop { sleep(n) }` patterns
      in vsock refresh paths (static analysis via grep patterns in litmus)

## Owner

Windows (LIVE_CLIENT + notify_icon polling audit),
Linux (headless crash investigation + litmus).
