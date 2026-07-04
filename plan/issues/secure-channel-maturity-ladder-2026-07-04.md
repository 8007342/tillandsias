# Master plan: end-to-end encrypted control channel — staged maturity ladder — 2026-07-04

- class: master-plan (security) — LONG-TERM, MULTI-STEP, CROSS-HOST
- filed: 2026-07-04
- owner: linux (coordinator) + macos + windows
- status: active (coordinates orders 141/142/145 + new 185/186)
- trace: plan/issues/encrypted-control-channel-impl-2026-07-01.md (141),
  plan/issues/encrypted-channel-vsock-cutover-2026-07-02.md (145),
  plan/issues/encrypted-channel-perboot-key-hardening-2026-07-01.md (142)
- goal: operator directive — implement the e2e encrypted socket channel in ALL
  places, enable it at runtime with a flag, then advance through STABLE VERIFIABLE
  MATURITY GATES to secure-by-default and finally to removal of the insecure path.

## Where we are (2026-07-04)

- **Primitive EXISTS** (order 141, in_progress): `tillandsias-secure-channel` crate —
  `EncryptedStream<S>` (Noise NNpsk0 handshake + AEAD, `snow`), `channel_psk(build_version,
  wire_version, hop)` version-bound PSK, `client_handshake`/`server_handshake`.
- **NOT wired into any transport, NOT flagged, NOT flipped on.** The vsock/vz/wsl
  transports still do only the plaintext Hello/HelloAck handshake.
- Per operator: macOS host is actively wiring its initiator; Windows is only stubs;
  the e2e encrypted socket is not implemented because it must flip on **in all
  places at once**.
- Order 145 already shapes the coordinated cutover + exact integration points, but as
  a SINGLE aggressive atomic flip. This master plan generalises that into a gradual,
  gated maturity ladder (145 becomes rung M1 below).

## "All places" (the surface that must all support it before any gate advances)

Two hops × the initiators/responders on every platform:

| Hop | Responder | Initiators |
|---|---|---|
| **HostGuest** (`HopId::HostGuest`) | guest `vsock_server.rs` | linux `host-shell/vsock_client.rs`; macOS `macos-tray/diagnose.rs` (vz vsock); windows `windows-tray/hvsocket.rs` + `wsl_lifecycle.rs` |
| **GuestContainer** (`HopId::GuestContainer`) | innermost-container tillandsias binary | guest→container transport |

All call `channel_psk(VERSION, WIRE_VERSION, hop)` with identical inputs, so the PSK
matches iff build+wire versions match (a mismatched peer is rejected — the anti-
downgrade property).

## THE design decision that makes a gradual ladder safe (resolves the 145 dual-mode worry)

145 rightly noted that accepting BOTH plaintext and encrypted **on the same guest at
the same time** is a trivially exploitable downgrade path. The ladder avoids that by
making the mode a **boot-time, enclave-wide coordinated setting, NOT a per-connection
negotiation**:

- One flag `TILLANDSIAS_SECURE_CONTROL_WIRE` (∈ {off, on}) is read once at enclave
  bring-up and propagated to the guest responder AND every host initiator for that
  boot. A given enclave boot is EITHER all-plaintext OR all-encrypted.
- The guest requires exactly what the flag says; it NEVER simultaneously accepts both.
  There is no per-connection downgrade to attack.
- Advancing the ladder changes the flag's DEFAULT, never introduces per-connection
  negotiation. This is what lets us soak "on" without opening a downgrade hole.

(Research packet 185 nails the flag propagation mechanism + the exact metrics behind
each gate below.)

## The maturity ladder — verifiable gates (each rung is STABLE before the next)

Migrations happen as the channel matures; do NOT skip a gate. Each gate is an
objective, checkable condition, not a vibe.

### M0 — Primitive ready  *(order 141)*
- EncryptedStream + version-bound PSK land with unit tests (handshake success,
  wrong-PSK rejection, AEAD round-trip, mid-stream tamper detection).
- **GATE M0→M1:** 141 status `done`; `cargo test -p tillandsias-secure-channel` green;
  the primitive is a stable public API (no churn expected).

### M1 — Wired everywhere behind the flag, default OFF  *(orders 145 linux half, 186 windows, macos osx-owned)*
- Every initiator + both responders wrap their stream with the handshake **behind
  `TILLANDSIAS_SECURE_CONTROL_WIRE`, default OFF** — zero behaviour change when off.
- **GATE M1→M2 (per-platform evidence required):**
  - flag OFF: all three platforms build + connect exactly as today (no regression);
  - flag ON: each platform VM-smokes a real host↔guest handshake e2e (e.g.
    `--github-login` over the encrypted wire) with logged evidence;
  - failure-closed litmus green: with flag ON, a plaintext / wrong-version peer is
    rejected `Unauthorized` and served no `PtyOpen` (order 137 /
    `vsock-unauthenticated-peer-rejected`);
  - GuestContainer hop wired behind the same flag (145 slice 6).

### M2 — Opt-in SOAK (flag works ON, still OFF by default)
- Operators / CI run flag-ON across all platforms for a defined soak window.
- **GATE M2→M3 (maturity metrics — see 185):**
  - flag-ON e2e green on ALL THREE platforms across **≥ N consecutive releases** and
    **≥ D days** (target: N=3, D=14 — ratify in 185);
  - **zero** handshake failures / wire-oscillation regressions attributable to the
    encrypted path in that window;
  - a rollback rehearsal proves flipping the flag OFF cleanly restores plaintext.

### M3 — Secure by DEFAULT (insecure still reachable via flag=OFF)
- Flip the DEFAULT to ON on all platforms in one coordinated wave. Insecure remains a
  runtime ESCAPE HATCH (`TILLANDSIAS_SECURE_CONTROL_WIRE=off`) for emergency rollback.
- **GATE M3→M4 (deprecation soak):**
  - default-ON releases ship on all platforms and stay stable for **≥ M releases**
    and **≥ E days** (target: M=4, E=30 — ratify in 185);
  - the escape hatch is NOT invoked in production in that window (telemetry / operator
    attestation);
  - a deprecation notice for the plaintext path has shipped for ≥ one release.

### M4 — Remove insecure support (no dual-mode, downgrade impossible)
- Delete the plaintext Hello path + the flag; the handshake becomes unconditional.
- **GATE (closure):** no plaintext code remains; a litmus proves a plaintext peer
  cannot connect on ANY hop/platform; WIRE_VERSION bumped to mark the break; all three
  platforms build + e2e green with the plaintext path gone.

## Rollback discipline (every rung)
Advancing is coordinated + reversible until M4. Any gate failure on any platform
HALTS the wave and drops back to the previous rung's default. Never advance a gate
with a red platform. WIRE_VERSION coordination (control-wire crate) gates every flip
so mixed-version host/guest pairs fail closed, never downgrade.

## What this master plan spawns
- **185 (research):** flag propagation mechanism (boot-time enclave-wide) + the exact
  maturity-gate metrics (ratify N/D/M/E) + telemetry to measure them.
- **186 (windows impl):** Windows transport is stubs → real hvsocket/wsl initiator so
  it can wrap the handshake at M1 (windows-owned).
- **145:** reframed as the M1 linux+coordination rung (the atomic-flip language relaxes
  into "M1 wiring behind flag" + the M3 default-flip).
- macOS initiator wiring: osx-owned, in progress (operator directed the macOS host).

## Exit criteria (master)
- Every rung has objective gate metrics recorded here + a green litmus.
- The channel advances M0→M4 over multiple release cycles, one gate at a time, all
  platforms green at each gate, always rollback-able until M4.
- At M4 the insecure path is gone and downgrade is impossible by construction.
