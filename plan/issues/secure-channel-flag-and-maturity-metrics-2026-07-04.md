# Research: secure-channel runtime flag propagation + maturity-gate metrics — 2026-07-04

- class: research (security)
- filed: 2026-07-04
- owner: linux (coordinator)
- status: claimed (2026-07-04T23:00Z, lease: secure-channel-flag-and-maturity-metrics-claim-1)
- depends_on: secure-channel-maturity-ladder-2026-07-04.md
- trace: order 141 (primitive), order 145 (cutover), spec:control-wire
- lead: linux-antigravity-20260704T2300Z

## Q1 — Flag propagation (boot-time, enclave-wide, NOT per-connection)

### Current state (as of 2026-07-04)

The flag `TILLANDSIAS_SECURE_CONTROL_WIRE` (∈ {off, on}) is read independently
by each process from its own OS environment. There is NO centralized propagation
service or agreement check.

| Component | Reads flag now? | Default when absent |
|---|---|---|
| headless `vsock_server.rs` | ✅ `maybe_secure_stream()` | Off (fail-closed on garbage) |
| host-shell `vsock_client.rs` | ✅ `connect_with_handshake()` | Off (fail-closed on garbage). **Landed 2026-07-04.** |
| macOS tray `diagnose.rs` | ❌ Not wired. Will land on osx-next. | Off (no effect until wired) |
| Windows tray `hvsocket.rs` / `wsl_lifecycle.rs` | ❌ Transport is still stubs (order 186). | Off by default |

### How the flag reaches each process

| Process | Path | Currently injected env vars |
|---|---|---|
| Linux native headless (host) | OS environment (systemd user service) | N/A — reads all OS env |
| macOS VM headless | cloud-init user-data → systemd unit `Environment=` (vz.rs:508) | Only `TILLANDSIAS_VAULT_API_BASE_URL` |
| Windows WSL2 headless | systemd unit template `Environment=` (wsl_lifecycle.rs:411-413) | `HOME`, `XDG_RUNTIME_DIR`, `TILLANDSIAS_VAULT_API_BASE_URL` |
| Host-shell (shared) | OS environment of the tray process | System env |
| Forge containers | Explicit `ContainerSpec.env()` or `podman run --env` args | Proxy, PATH, HOME, identity, provider keys. **No TILLANDSIAS_SECURE_CONTROL_WIRE.** |

### Propagation recommendations per maturity gate

**M1 (flag OFF by default, opt-in for testing):**
No propagation infrastructure needed. Each process reads the flag from its own
environment independently. The operator who opts in:
1. Sets `TILLANDSIAS_SECURE_CONTROL_WIRE=on` in the tray/terminal launch env
2. Ensures the headless VM systemd unit receives it (see below)
3. Flag mismatch between initiator and responder causes a garbled-data disconnect
   (fail-closed by the Noise protocol — an initiator sending Noise handshake bytes
   to a plaintext responder → early EOF → connection closed). This is acceptable
   for M1 because only operators testing the feature encounter it.

**M1 → M2 prep (add flag injection for VM headless before gate evidence):**
Before the M1→M2 gate can be met, each host MUST inject the flag into the
headless VM so the responder can be turned ON:
- macOS: Add `Environment=TILLANDSIAS_SECURE_CONTROL_WIRE=%s` to the systemd unit
  template in `vz.rs:generate_cidata_iso()`
- Windows: Add `Environment=TILLANDSIAS_SECURE_CONTROL_WIRE=%s` to the systemd
  unit template in `wsl_lifecycle.rs`
- Forge container (GuestContainer hop): Add `TILLANDSIAS_SECURE_CONTROL_WIRE` to
  the forge agent run-args env list in `main.rs` forge-args builder

**M3 (default ON, flag flips):**
Same injection paths but the default value changes in all places at once.
The coordinated flip becomes: change the default in the flag parser (Off → On)
AND inject the flag everywhere as `TILLANDSIAS_SECURE_CONTROL_WIRE=on` so it's
explicit. All platforms go ON together in one commit.

**M3 → M4 (pre-flight agreement check):**
At M3 the flag is ON everywhere and the escape hatch is `TILLANDSIAS_SECURE_CONTROL_WIRE=off`.
Two safety measures:
1. **Add a pre-flight field to Hello/HelloAck:** The Hello envelope gets an
   optional `secure_wire: bool` field. The responder checks: if the initiator
   says `secure_wire: false` but the responder's flag is ON → reject with a new
   `ControlMessage::Error { code: ErrorCode::ProtocolViolation, message: "secure
   control wire flag mismatch: initiator says off, responder says on" }`.
   Similarly, the initiator checks HelloAck for a `secure_wire` field and fails
   early if it disagrees.
2. **Log a clear error instead of garbled-data timeout:** Without the Hello field,
   a mismatch drops the connection with a generic "handshake failed: early eof".
   The Hello field turns that into a diagnostic error.

**M4 (insecure removed):**
The flag is deleted. No propagation, no agreement check. The handshake is
unconditional. Relevant env var injection paths are cleaned up.

### Fail-closed on disagreement (already built in)

The Noise handshake itself provides fail-closed behaviour:
- Initiator with flag=ON sends Noise handshake message → responder with flag=OFF
  reads it as a length-prefixed envelope → `read_exact` gets unexpected bytes →
  EOF or deserialization failure → connection closed. No PtyOpen served.
- Initiator with flag=OFF sends Hello → responder with flag=ON waits for Noise
  handshake → garbled → EOF → connection closed. No downgrade.

This is adequate for M1-M2. The pre-flight Hello agreement check (M3) adds
diagnostic clarity but is not a security requirement — the protocol is already
fail-closed.

### WIRE_VERSION interaction

Already handled: the PSK derivation `channel_psk(build_version, WIRE_VERSION, hop)`
binds the key to both versions. A host/guest pair whose WIRE_VERSION or
build_version differs will derive different PSKs → Noise handshake fails →
connection rejected. This is part of the anti-downgrade property.

---

## Q2 — Maturity-gate metrics (N/D/M/E ratification)

### Project release cadence

Based on git history (July 2026): **multiple releases per day, ~2-5 per day**
on linux-next. `main` releases are cut on demand (workflow_dispatch).
The N=3 releases target covers < 1 day of linux-next commits; D=14 days is
the real constraint for M2→M3.

### Ratified targets

| Gate | Metric | Proposed | Ratified | How measured |
|---|---|---|---|---|
| M2→M3 | Consecutive releases N | 3 | **3 releases** (not commits — use `main` tags) | Count distinct `v0.3.YYYYMMDD.X` tags that include the secure-channel wiring; each must have a green VM-smoke recorded in the ledger |
| M2→M3 | Soak days D | 14 | **14 days** (not calendar days — "days with a non-zero number of linux-next commits carrying the flag-ON path") | Count days between the first and last qualifying commit's author-date on linux-next; update a counter in `plan/loop_status.md` each cycle |
| M3→M4 | Stable releases M | 4 | **4 consecutive releases** with secure-by-default (flag ON for all) | Same as N but counting releases where `TILLANDSIAS_SECURE_CONTROL_WIRE` default was ON; each must have zero escape-hatch invocations and zero encrypted-path regressions |
| M3→M4 | Escape-hatch soak E | 30 | **30 days** with zero escape-hatch invocations | Count consecutive days where the telemetry counter `tillandsias_secure_control_wire_off_total` stayed at zero |

### Measurement methods

**"Release" definition:**
A `v0.3.YYYYMMDD.X` semver tag published via `release.yml` (workflow_dispatch).
Each release binary embeds the source tree at the tagged commit. Track which
commits carry the flag and which tag advances which rung.

**M2→M3 counter:**
Maintain a `plan/loop_status.md` field:
```
secure_channel_soak:
  start_date: 2026-07-05
  days_elapsed: 0
  qualifying_commits: 0
  first_release_tag: null
  third_release_tag: null
```
Update on each advance-work cycle. Gate passes when both N=3 releases AND
D=14 days with qualifying commits are met, plus zero encrypted-path regressions.

**M3→M4 counter:**
Same pattern but tracking `tillandsias_secure_control_wire_off_total` counter
(see Q3). Gate passes when M=4 releases AND E=30 days at zero escape-hatch
count.

### Recommended telemetry additions to support measurement

New Prometheus counters to add to `tillandsias-metrics`:
- `tillandsias_handshake_total{hop="host_guest|guest_container",platform="linux|macos|windows",result="success|failure"}` — per-hop handshake outcome
- `tillandsias_secure_control_wire_off_total` — increments each time a process
  starts with `TILLANDSIAS_SECURE_CONTROL_WIRE=off` (or absent with default OFF)
  — measures escape-hatch usage at M3
- `tillandsias_handshake_version_mismatch_total` — wire-version or build-version
  disagreement at handshake time

---

## Q3 — Observability for the gates

### What exists today

- **No handshake-specific Prometheus counters**. Only image-build metrics exist.
- Handshake failures are logged via `tracing::warn!` or `tracing::debug!`:
  - Server: `"secure control wire handshake failed"` (warn, vsock_server.rs:299)
  - Client: caller-dependent — Windows tray logs `"handshake failed: {err}"` at debug
  - Success: NOT explicitly logged as an `info!` event
- Windows tray surfaces handshake state via `StatusReport { error }` and
  `VmLaneStatus::ControlWireUnreachable`
- macOS tray tracks handshake failures via `VmLaneStatus`
- No cross-platform handshake-success evidence is recorded

### What to add for gate observability

**Before M2 (opt-in soak starts):**
1. Add `tillandsias_handshake_total` counter to the Prometheus metrics crate
   (gated behind the metrics feature, not pulling it into host-shell if unused)
2. Increment it in `client_handshake` (success path) and at each failure site
   in `vsock_server.rs` / `vsock_client.rs`
3. Add `tillandsias_secure_control_wire_off_total` counter, incremented once per
   process start in the flag parser (`parse_secure_control_wire_mode`)
4. Add an `info!` log on handshake success (server: after `maybe_secure_stream`
   returns Ok; client: after `connect_with_handshake` returns Ok) so structured
   log aggregation can track handshake outcomes

**Before M3 (default-ON flip, M2 gate passes):**
5. Add the pre-flight Hello field (`secure_wire: bool`) to the control-wire
   envelope schema in `tillandsias-control-wire`
6. Implement the agreement check in both initiator and responder
7. Wire `tillandsias_handshake_version_mismatch_total` counter

**Telemetry gaps (filed as sub-packets for order-185 completion):**
- Sub-packet A: Add `tillandsias_handshake_total` counter to `tillandsias-metrics`
- Sub-packet B: Add `info!` log on handshake success in server + client
- Sub-packet C: Add `tillandsias_secure_control_wire_off_total` counter
- Sub-packet D: Add pre-flight Hello field agreement check

---

## Summary for the maturity ladder

### Ladder updates (action items for secure-channel-maturity-ladder.md)

1. **M2→M3 gate text:** Change to:
   "flag-ON e2e green on ALL THREE platforms across ≥ 3 tagged releases
   and ≥ 14 days with qualifying linux-next commits, zero encrypted-path
   handshake-failure regressions; soak-so-far counter in loop_status.md"

2. **M3→M4 gate text:** Change to:
   "default-ON releases ship on all platforms for ≥ 4 consecutive releases
   and ≥ 30 days; escape-hatch counter (tillandsias_secure_control_wire_off_total)
   stays at zero; deprecation notice for the plaintext path shipped
   for ≥ 1 release"

3. **Add observability section:** Reference Q3 telemetry additions as
   prerequisites per gate

### Sub-packets filed

| ID | Title | Hours | Depends on |
|---|---|---|---|
| 185-A | Impl: add `tillandsias_handshake_total` Prometheus counter | 2 | none |
| 185-B | Impl: add `info!` log on handshake success (server + client) | 1 | none |
| 185-C | Impl: add `tillandsias_secure_control_wire_off_total` counter | 1 | none |
| 185-D | Impl: pre-flight Hello field `secure_wire` agreement check | 4 | none (schema change → WIRE_VERSION bump) |

### Verifiable closure

- [x] Q1: flag propagation path mapped per platform + gate; pre-flight
      agreement check specified for M3; fail-closed property confirmed
- [x] Q2: N=3/D=14/M=4/E=30 ratified with measurement methods; telemetry
      gaps filed as sub-packets 185-A/B/C/D
- [ ] Q3: master ladder updated with ratified numbers + observability plan
      (update in secure-channel-maturity-ladder.md)
