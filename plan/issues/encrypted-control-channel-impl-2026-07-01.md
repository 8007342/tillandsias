# Encrypted, Version-Bound Control Channel — Implementation — 2026-07-01

- class: enhancement (security)
- filed: 2026-07-01
- owner: linux
- status: pending (blocked on research sign-off of Open Decisions O1–O4)
- depends_on: encrypted-control-channel-research-2026-07-01.md
- supersedes/closes: vsock-exec-chain-authn-authz (order 137); folds in the argv-allowlist half of vsock-exec-authz-spec-and-proxy-exemption-audit (order 139)
- trace: spec:vsock-transport, spec:tray-host-control-socket, plan/issues/security-audit-zero-trust-2026-07-01.md

## Goal

Land the encrypted, forward-secret, version-bound channel designed in the
research packet: one `EncryptedStream<S>` primitive wrapping the vsock host↔guest
hop and the guest↔innermost-container hop, keyed by a version-derived PSK so only
matching-version binaries interoperate, with a post-handshake argv allowlist so
only approved exec commands reach the deepest container. Failure-closed.

## Preconditions

- **O1 DECIDED 2026-07-01 (operator): build-embedded per-release secret** — the
  key-derivation input is a per-release secret compiled into every tillandsias
  binary of the release (host tray, guest headless, in-container agent). No
  per-boot provisioning in this impl; the per-boot additional derivation is a
  deferred hardening (order 142,
  `plan/issues/encrypted-channel-perboot-key-hardening-2026-07-01.md`). Slices
  may now start. O2–O4 stand at their recommended defaults (new
  `tillandsias-secure-channel` crate; WIRE_VERSION unchanged; dev seed for
  `--debug`) unless the operator revisits them.
- WIRE_VERSION unchanged (confirm in slice 1); the tunnel wraps the existing
  postcard codec without schema changes.

## Progress

- **Slices 1-2 DONE** (`0a7afb2c`): `tillandsias-secure-channel` crate;
  `derive_psk()` version binding; 7 proof tests.
- **Slice 3 DONE** (this cycle): `EncryptedStream<S>` in `secure_stream.rs` —
  `NNpsk0` `client_handshake`/`server_handshake` over any `AsyncRead+AsyncWrite`,
  then a full `AsyncRead+AsyncWrite` AEAD tunnel (2-byte-length ChaCha20-Poly1305
  frames, 16 KiB plaintext chunks, poll-based read reassembly + write staging).
  `snow` default-resolver (pure-Rust, musl-friendly). 11 tests: round-trip,
  multi-frame, mismatched-PSK-handshake-fails, tampered-ciphertext-rejected.
- **Slice 5 (argv allowlist) ALREADY LANDED via order 139** (`e0b30d18`,
  `pty_handler.rs`): argv allowlist + `tillandsias-{project}-forge` name
  validation + proxy exemption. Slice 4 will place the encrypted channel as gate
  #1 in front of that existing gate #2.
- **Remaining: slice 4** (wire the handshake into `vsock_server::handle_connection`
  before `Hello`, failure-closed `Unauthorized`; host initiator side) and **slice
  6** (guest↔container hop reuse + revisit order-104 port-publish removal).
- **Residual to confirm at release:** the `snow` dep uses the pure-Rust
  default-resolver, expected musl-static clean; verify under `--ci-full`/release.

## Slices (one coherent commit each; single-commit-per-cycle applies)

### Slice 1 — OpenSpec change + crate skeleton (no behavior change)
- Create OpenSpec change `encrypted-control-channel` (proposal + spec deltas +
  tasks) capturing handshake, version-binding derivation, failure-closed
  ordering, allowlist gate, threat-model assumptions.
- Add `tillandsias-secure-channel` crate (per O2) depending on `snow` (Noise),
  with `EncryptedStream<S>` type stubs + the PSK-derivation function signature.
- Litmus: `secure-channel-crate-shape` (crate present, snow pinned, no bespoke
  cipher). `./build.sh --check` green.

### Slice 2 — PSK derivation (version binding) + unit proof
- Implement `derive_psk(root, build_version, wire_version, hop_id) -> [u8;32]`
  via HKDF-SHA256 (`hkdf`/`sha2` already vendored).
- Wire `build_version` from the embedded `VERSION`; `hop_id` enum
  {HostGuest, GuestContainer}.
- Litmus/unit: `psk-differs-across-version` — asserts `derive_psk` for two
  different build_versions (and for the two hop_ids) yields distinct keys; same
  inputs yield identical keys (determinism). This is the machine-checkable proof
  of "only matching versions can communicate."

### Slice 3 — `EncryptedStream<S>` handshake + AEAD framing
- Implement the `NNpsk0` (or operator-chosen pattern) initiator/responder
  handshake over any `AsyncRead+AsyncWrite` stream; on success expose a duplex
  stream that AEAD-seals/opens each frame. `zeroize` key material on drop.
- Handshake timeout (failure-closed; no unbounded reads — also fixes the
  no-timeout class from the vsock postmortem H3/H4).
- Round-trip unit tests over an in-memory duplex; tamper test (flipped ciphertext
  byte → open fails); wrong-PSK test (handshake fails, no plaintext leaks).

### Slice 4 — Host↔guest integration (vsock), failure-closed + Unauthorized
- Initiator: wrap the host→guest vsock stream in the tray/host-shell connect path
  before the `Hello`.
- Responder: `vsock_server.rs::handle_connection` runs the handshake FIRST; on
  failure emit `Error { code: Unauthorized }` and close before any `Hello`.
- Remove/append: the listener still binds `VMADDR_CID_ANY` (transport), but
  authorization is now cryptographic.
- Litmus: `vsock-unauthenticated-peer-rejected` (closes order 137) — a peer that
  omits/forges the handshake gets `Unauthorized`, never a `HelloAck`.
- Verify the proxy-exemption pattern holds on this path (order 139 (b)).

### Slice 5 — Argv allowlist gate (both spawn points)
- Encode the approved intent set as a validated allowlist (exact argv templates
  or a `PtyIntent`→argv mapping); reject non-matching `PtyOpen.argv` with
  `Unauthorized` at the guest and at the container endpoint.
- Allowlist-validate the project name interpolated into `tillandsias-{p}-forge`
  (audit P1-3).
- Litmus: `pty-open-argv-allowlisted` — a non-allowlisted argv is rejected;
  approved intents pass. (Closes order 139 (a).)

### Slice 6 — Guest↔innermost-container hop (reuse) + shutdown of the port publish
- Apply the same `EncryptedStream<S>` on the guest→container hop with
  `hop_id=GuestContainer` and the container's matching-version PSK.
- With an authenticated non-published host access path in place, revisit
  `hardcoded-ip/remove-port-publish` (order 104) — the encrypted vsock/exec
  channel is the "non-published native host access path" that blocker needed.
- E2E: on an SELinux-enforcing guest, `--github-login` still works end to end
  over the encrypted channel; a mismatched-version binary cannot attach.

## Verifiable closure (impl done-when)

- OpenSpec `encrypted-control-channel` change implemented + verified + archived.
- `psk-differs-across-version` proves cryptographic version binding.
- `vsock-unauthenticated-peer-rejected` proves failure-closed authZ (order 137).
- `pty-open-argv-allowlisted` proves the exec allowlist gate (order 139 (a)).
- Both hops run the same `EncryptedStream<S>`; terminal I/O + argv are encrypted.
- `./build.sh --check` and `--test` pass; targeted e2e on an enforcing guest green.
- Residual/hardening (typepermissive→enforcing SELinux, `XXpsk3` static keys,
  per-boot root mixing) filed as follow-ups, not blockers.
