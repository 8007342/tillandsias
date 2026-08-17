# Least-privilege design for the guest headless — DRAFT decision record

<!-- provenance: order 309 (headless-least-privilege-split), criterion 1.
     Written on macOS from source measurement; the macOS half of criterion 2
     was discharged 2026-08-17 (cycle 9) — the vz guest units carry zero
     hardening directives, so the order-308 hazard is confirmed absent here. -->
<!-- freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-17 verdict=refreshed scope=309 design draft -->

**STATUS: DRAFT — needs The Tlatoāni's signature before implementation.**
This is an architecture decision (it moves a trust boundary), so per
`methodology/distributed-work.yaml` → `ambitious_milestone_reduction` it is
research + a proposed decision, not a change to start.

## What order 308 actually proved

Order 308 removed `NoNewPrivileges=yes` and
`CapabilityBoundingSet=CAP_NET_BIND_SERVICE` from the headless unit because
they wedged every podman operation. The mechanism, quoted from that commit,
is the part that constrains every design here:

> cap-stripped uid-0 podman selects rootless mode and wedges every ensure

Podman does not merely *need* capabilities — it **inspects its own
capability state and switches mode**. A confined uid-0 podman decides it is
rootless and takes a path that does not work in this guest. So:

> **You cannot confine the process that forks podman without changing
> podman's behaviour.** Any least-privilege design must therefore separate
> the confined part from the podman-forking part — the split is not one
> option among several, it is the only shape that can work.

## Measured constraints (all from source at HEAD)

1. **Podman is reached by forking the CLI, not the API.** `podman_cmd_sync()`
   builds a `std::process::Command`; `crates/tillandsias-headless/src/main.rs`
   alone has 47 `Command::new`/`podman_cmd_sync` sites, and
   `tillandsias-podman/src/client.rs` shells out too.
2. **The network-facing half is also a podman-forking half.**
   `pty_handler.rs` builds `Command::new(&argv[0])` for every `PtyOpen`, and
   its argv allowlist admits `podman exec -it tillandsias-<project>-forge …`.
   So today the vsock listener forks podman directly — the two roles the
   packet wants separated are entangled in the same code path, not merely the
   same process.
3. **The listener needs no special privilege of its own.** The control wire
   binds vsock port 42420 — well above 1024, so not even
   `CAP_NET_BIND_SERVICE` is required. `CAP_NET_BIND_SERVICE` was the one
   capability order 308's unit kept, and nothing needed it.
4. **Today there is no confinement at all.** The macOS guest units
   (`vz.rs`) carry zero directives from the hardening family — swept for
   `NoNewPrivileges`, `CapabilityBoundingSet`, `Protect*`, `PrivateTmp`,
   `RestrictAddressFamilies`, `SystemCallFilter`, `ReadOnlyPaths`,
   `LockPersonality`, `MemoryDenyWriteExecute`: **0 hits**, and the same for
   the Windows/WSL unit. The headless runs as unconfined root. That is the
   debt this packet exists to retire; the 308 hazard is confirmed absent.

## Option A — confined listener, unconfined orchestrator (RECOMMENDED)

Two units. The **listener** owns the vsock socket, the wire protocol, framing,
session bookkeeping, and the argv policy check. It runs fully confined:
`NoNewPrivileges=yes`, an empty `CapabilityBoundingSet`, `ProtectSystem=strict`,
`PrivateTmp`, `RestrictAddressFamilies=AF_VSOCK AF_UNIX`. It forks nothing.

The **orchestrator** owns every podman interaction and runs exactly as the
headless runs today — unconfined — because that is what podman requires. It
listens on a local unix socket with `0600` ownership, accepts a *typed*
request set (ensure-image, run-container, exec-session, …), and re-validates
the argv allowlist on its own side.

Why this is worth doing even though the orchestrator stays unconfined:

- The **attack surface that faces the network** is the wire parser, and that
  is precisely the half that becomes confined. A memory-safety or protocol
  bug in envelope handling no longer sits in a process holding
  `CAP_SYS_ADMIN`.
- The argv allowlist becomes a **trust boundary rather than an internal
  check**. Today a compromised listener can fork any podman command it can
  construct, because the check and the fork are the same process. After the
  split, the orchestrator re-validates, so the listener cannot exceed the
  typed request set even if it is fully controlled.
- It is **incremental**: the orchestrator is the current code with a socket
  front-end; no podman call site changes.

Cost, stated honestly: a new IPC protocol and its versioning; PTY sessions
must proxy their fds across the socket (`SCM_RIGHTS` fd-passing, which is the
fiddliest part and where the design most likely needs a second look); two
units to supervise; and a failure mode that does not exist today (orchestrator
down while listener up) which needs a defined, loud behaviour.

## Option B — podman API socket delegation (NOT recommended now)

Give the headless only client rights on `podman.sock`.

Rejected for two independent reasons:

1. **Cost**: ~50 CLI-forking sites would have to become REST calls. That is a
   rewrite of the podman layer, with its own regression surface, for a
   security property that is largely illusory —
2. **because the podman socket is not a reduced authority.** Anything that
   can talk to it can create privileged containers with host mounts. Holding
   "only client rights" on that socket is approximately holding root. The
   confinement would look real in the unit file and buy very little.

Worth revisiting only if the podman layer is being rewritten for other
reasons.

## Proposed verifiable closure (criterion 3)

A litmus that runs a **headless-driven podman operation under the shipped
unit constraints** — not under a hand-written unit in the test. The order-308
regression is precisely "the unit as shipped differs from the unit as
tested", so the check must read the unit text the guest actually installs
(`vz.rs` for macOS, the WSL equivalent for Windows) and exercise an ensure
through it. Negative control: the same litmus against a unit with the
order-308 directives restored must FAIL, or it proves nothing.

## Open questions for the signature

1. Is the security gain (confining the wire parser, making the allowlist a
   real boundary) worth a new IPC protocol plus fd-passing?
2. Should the orchestrator socket be per-boot and unlinked at shutdown, or a
   systemd-activated socket unit?
3. Does the split apply to Windows/WSL in the same shape, or is WSL's
   different lifecycle a reason to confine only on the VZ path first?
