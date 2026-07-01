# Encrypted, Version-Bound Control Channel — Research/Design — 2026-07-01

- class: research (security)
- filed: 2026-07-01
- owner: linux
- status: ready
- depends_on: (informs) vsock-exec-chain-authn-authz (order 137), vsock-exec-authz-spec-and-proxy-exemption-audit (order 139)
- trace: spec:vsock-transport, spec:tray-host-control-socket, spec:host-shell-architecture, plan/issues/security-audit-zero-trust-2026-07-01.md (P0-1)

## Cold-start summary

Operator directive: establish an **encrypted channel** between the **tray on the
host** and the **tillandsias-headless binary in the guest**, over the existing
vsock control wire — and make the **same mechanism reusable** from
tillandsias-headless down to the **deepest podman container** (the forge exec
target). Two hard requirements:

1. **Version binding by construction.** The host binary must match the guest
   binary's version; mismatched versions MUST be cryptographically unable to
   communicate — "use different encryption keys, so only matching versions can
   talk." A plain version *comparison* is insufficient (self-reported fields are
   not trust; see the P0-1 audit finding). Binding is achieved by *deriving the
   channel key from the version*, so a mismatch yields a different key and the
   handshake MAC fails — the peers simply cannot complete the handshake.
2. **Gated exec.** Combined with the argv allowlist, only approved exec commands
   can run in the innermost containers: gate #1 is the channel (opens only for a
   matching-version, key-holding peer); gate #2 is the allowlist (argv validated
   before spawn). This directly closes P0-1 (today the vsock listener binds
   `VMADDR_CID_ANY`, accepts any peer, and execs `PtyOpen.argv` verbatim).

This packet is the **design of order-137's closure**. It supersedes the "minimum
auth token" sketch in 137 with a full encrypted, forward-secret, version-bound
channel and folds in the allowlist gate from 139.

## Current transport (what we are wrapping)

- Wire: `postcard`-framed `ControlEnvelope { wire_version, seq, body }` over an
  `AsyncRead + AsyncWrite` stream (`crates/tillandsias-control-wire/src/lib.rs`).
  `WIRE_VERSION = 2` (inner protocol version).
- Host↔guest transport: vsock (`tokio-vsock` on Linux; HvSocket on Windows; VZ
  virtio-vsock on macOS). Listener: `crates/tillandsias-headless/src/vsock_server.rs`
  binds `VMADDR_CID_ANY`, `serve_listener` → `handle_connection` reads a `Hello`
  and replies `HelloAck` with **no peer authentication**.
- Guest→container hop: `crates/tillandsias-host-shell/src/pty/mod.rs::launch_spec`
  builds `podman exec -it tillandsias-{p}-forge <argv>` and the guest PTY handler
  spawns it. `argv` is executed verbatim (no allowlist today).
- Crypto already vendored: `sha2`, `hkdf`, `hmac` (via hkdf), `rustls` (reqwest),
  `zeroize`, `keyring`, Vault. **Not yet present:** an AEAD cipher, an X25519 DH,
  or a Noise implementation.

## Design

### D1 — Reusable `EncryptedStream<S>` adapter (one primitive, both hops)

Introduce a transport-agnostic wrapper in a new module (proposed:
`tillandsias-control-wire::secure` or a new `tillandsias-secure-channel` crate)
that takes any `S: AsyncRead + AsyncWrite + Unpin + Send` and returns an
authenticated, encrypted `S'` implementing the same traits. Everything above it
(the postcard `ControlEnvelope` codec, `PtyOpen`/`PtyData`, VmStatus, etc.) is
unchanged — it just runs inside the AEAD tunnel.

Because it wraps *any* stream, the **same code serves both hops**:

- host tray ⇄ guest headless: wrap the **vsock** stream.
- guest headless ⇄ innermost container: wrap the guest→container stream
  (`podman exec` stdio pipe, a Unix socket, or vsock-in-vsock CID 1). The guest
  plays the *initiator* role toward the container, mirroring how the host is the
  initiator toward the guest. The container's matching-version tillandsias binary
  is the responder.

### D2 — Handshake: PSK-gated Noise (recommendation: `snow` crate, `NNpsk0`)

Do **not** hand-roll crypto. Use the `snow` crate (pure-Rust, audited Noise
Protocol Framework impl). Baseline pattern **`Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s`**:

- Both endpoints hold the version-bound **PSK** (see D3). `NNpsk0` mixes the PSK
  in at the first handshake message, so a peer without the exact PSK cannot
  complete the handshake — this is the cryptographic version gate.
- Ephemeral X25519 DH gives **forward secrecy** (a leaked PSK does not
  retro-decrypt captured sessions), and a fresh session key per connection.
- ChaCha20-Poly1305 AEAD encrypts+authenticates every subsequent transport
  message (including terminal bytes and argv). BLAKE2s for the transcript hash.

Hardening upgrade (later, not baseline): **`XXpsk3`** adds mutual *static* keys
(per-endpoint identity) on top of the PSK. Deferred — pure-PSK already satisfies
"matching versions only"; static-key distribution is extra machinery.

### D3 — Version binding: derive the PSK from the version (the core requirement)

The PSK is **not stored**; it is derived on both sides:

```
PSK = HKDF-SHA256(
        ikm  = release_root_secret,
        salt = "tillandsias-control-channel",
        info = "v=" || build_version || ";wire=" || WIRE_VERSION || ";hop=" || hop_id
      )[0..32]
```

- `build_version` is the release string (the `VERSION` file already embedded via
  `include_str!`). A host at v0.3.260701.1 and a guest at v0.3.260630.1 derive
  **different PSKs** → handshake fails → **cannot communicate**. Exactly the
  requested behavior, enforced by construction rather than by a comparison an
  attacker could skip.
- `hop_id` ("host-guest" vs "guest-container") domain-separates the two hops so a
  captured host↔guest key can never be replayed on the guest↔container hop.
- `release_root_secret` is the one input that must be present in both binaries
  but not derivable by an unauthorized peer. **This is the primary open
  decision (see Open Decisions O1).** Recommended default: a per-release secret
  embedded at build time into every tillandsias binary of that release (host
  tray, guest headless, in-container agent are all built from the same release),
  so "same release talks to same release," and rotation = cut a new release.

### D4 — Failure-closed ordering + `Unauthorized`

The handshake runs **before** any `Hello` is read. On any failure (wrong
version/PSK, bad MAC, malformed handshake, timeout) the connection is closed
immediately, emitting the reserved `ControlMessage::Error { code: Unauthorized }`
(lib.rs:350, currently unused). No `PtyOpen` — indeed no plaintext frame at all —
is ever processed from an unauthenticated peer. This is the concrete closure of
P0-1's "accepts every connection."

### D5 — Exec allowlist gate (gate #2)

After the channel is authenticated, `PtyOpen.argv` is validated against an
allowlist **at the endpoint that will spawn it** (the guest for VM shells, and
the container endpoint for innermost exec). The allowlist is the approved intent
set already modeled by `PtyIntent`/`launch_spec` — encode it as a
machine-checkable allowlist (exact argv templates or a validated `PtyIntent` →
argv mapping) rather than free-form argv. Reject non-matching argv with
`Unauthorized`. Also allowlist-validate the interpolated project name in
`tillandsias-{p}-forge` (P1-3 from the audit). This makes "only approved exec
commands run innermost" a two-gate invariant.

### D6 — Nonces, rekey, hygiene

- Per-direction nonce counters from the Noise transport state; never reused.
- Connections are short-lived; rekey-on-counter-exhaustion is a guardrail, not a
  hot path. `zeroize` all key material on drop (dep already present).
- No key material or plaintext argv in logs (the audit flagged debug logging of
  peer/frames; downgrade to non-sensitive fields).

## Threat model (what this stops / does not stop)

- **Stops:** an unauthorized host-CID peer opening the vsock port and driving
  `podman exec` in the forge container (P0-1); passive capture of terminal I/O or
  argv on the vsock/hypervisor path; a stale/mismatched-version host or guest
  binary talking to the other (version confusion); replay of a host↔guest key on
  the guest↔container hop (domain separation).
- **Does not stop (out of scope, note explicitly):** a compromised *matching-
  version* binary that legitimately holds the PSK; host-kernel/hypervisor
  compromise; the operator running an untrusted release. These are the residual
  trust roots and belong in the spec's assumptions section.

## Alternatives considered (and why not)

- **TLS-PSK over vsock (rustls):** rustls's external-PSK support is limited/newer
  and TLS record framing over a stream vsock is heavier; Noise is the cleaner fit
  for a bespoke framed byte protocol and gives PSK + forward secrecy directly.
  Keep for consideration only if a rustls-PSK path is already wanted elsewhere.
- **Plain AEAD with a static version-derived key, no DH:** simplest, but no
  forward secrecy and nonce-management is entirely on us. Rejected — `snow` gives
  FS + transcript binding for little extra cost and avoids bespoke nonce logic.
- **Version *check* only (compare `Hello.build_version`):** rejected as the whole
  point — self-reported and skippable. Must be key-derivation-enforced.

## Open Decisions (need operator sign-off before impl)

- **O1 (primary) — source of `release_root_secret`.**
  - (a, recommended) **Build-embedded per-release secret**: injected at compile
    time (build.rs from a CI-provided env / signed release manifest) into every
    tillandsias binary of the release. Pro: "same release only," zero runtime
    provisioning, rotates per release. Con: the secret lives in the binary (but
    all three peers are equally trusted release artifacts, so this is acceptable
    for the stated threat model; a binary reverse-engineer already has the code).
  - (b) **Provisioning-injected secret**: host generates a random root per VM boot
    and injects it into the guest via cloud-init/kernel-cmdline (a channel the
    host already controls) and into containers via a podman secret. Pro: not in
    the binary; per-boot. Con: more moving parts; the guest↔container hop needs
    the host to seed the container secret. Combine with (a) by mixing both.
  - **Recommended default: (a) for the version-binding requirement, optionally
    mixed with (b) per-boot randomness for defense-in-depth.**
- **O2 — new crate vs module.** Recommend a small `tillandsias-secure-channel`
  crate so host tray, guest headless, and the in-container agent share one impl
  and `snow` is not pulled into crates that don't need it. WIRE_VERSION stays in
  control-wire; the secure crate wraps the stream beneath it.
- **O3 — WIRE_VERSION interplay.** The outer channel binds `build_version`; the
  inner postcard protocol keeps `WIRE_VERSION`. Confirm we do NOT need to bump
  WIRE_VERSION (the envelope schema is unchanged — it just runs inside the
  tunnel). Expected: no bump.
- **O4 — dev/debug builds.** Derive the dev root from a stable dev seed so local
  `--debug` host+guest built from the same tree interoperate, while release
  builds use the CI secret. Must not weaken release binding.

## Governing-spec obligation

Per methodology (specs define intent), the implementation must land an OpenSpec
change (proposed name `encrypted-control-channel`) covering: the handshake, the
version-binding key derivation, the failure-closed ordering, the allowlist gate,
and the threat-model assumptions — plus litmus bindings (see impl packet). File
the OpenSpec change as the first implementation slice.

## Verifiable closure (research done-when)

- Crypto primitive + Noise pattern chosen with rationale (DONE: `snow` `NNpsk0`).
- Version-binding derivation specified (DONE: HKDF over build_version + hop_id).
- Layering for both hops specified (DONE: `EncryptedStream<S>` adapter).
- Allowlist gate integration specified (DONE: post-handshake argv validation).
- Open decisions enumerated with recommended defaults (DONE: O1–O4).
- Handoff: impl packet `encrypted-control-channel-impl-2026-07-01.md` shaped with
  slices + litmus (DONE — see that file).
