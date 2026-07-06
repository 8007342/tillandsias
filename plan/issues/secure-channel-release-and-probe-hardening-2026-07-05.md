# Secure-channel hardening: PSK parity, release-secret enforcement, readiness probes — 2026-07-05

- class: security+release hardening
- owner: any, with macOS evidence where VZ probes are involved
- status: done
- order: 194
- trace: plan/issues/secure-channel-maturity-ladder-2026-07-04.md,
  plan/issues/secure-channel-flag-and-maturity-metrics-2026-07-04.md

## Finding

The secure-channel primitive and guest responder exist, but the M1 evidence still
has several hardening gaps:

- macOS user action paths use the workspace `VERSION` for PSK input, while at least
  one diagnostic path derives from `CARGO_PKG_VERSION`.
- VM readiness probes still use raw control-wire streams in places, so flag-ON
  guests can fail readiness even though user actions use the secure opener.
- Release build paths must prove `TILLANDSIAS_RELEASE_SECRET` is injected; otherwise
  release artifacts can silently use the public dev seed.
- The plan says unauthenticated peers receive `Unauthorized`, but a Noise failure
  before control envelopes exist can only fail closed by closing the stream. The
  requirement should be phrased as "no HelloAck/no PtyOpen; close before envelope"
  unless a pre-handshake error frame is explicitly designed.

## Work

1. Normalize all host initiator PSK inputs to the same workspace `VERSION`.
2. Route `wait_phase_ready` / `probe_vm_phase` through the same secure-or-plain
   opener used by user actions.
3. Add release CI/litmus evidence that release artifacts cannot build with the
   public dev seed.
4. Update secure-channel plan text where needed so failure-closed semantics match
   the implementable handshake boundary.

## Acceptance Evidence

- `psk-input-parity` litmus proves all secure openers use the same version source.
- `secure-wait-phase-ready` litmus proves readiness probes work in flag-ON mode.
- `release-secret-required` litmus or CI step fails release builds without
  `TILLANDSIAS_RELEASE_SECRET`.
- Flag-ON plaintext/wrong-version peers receive no `HelloAck` and cannot trigger
  `PtyOpen`.

## Linux slice 3 complete — 2026-07-06T03:45Z (order 194)

Slice 3 (release-secret enforcement) completed by linux-yoga-macuahuitl:

- **flake.nix**: reads `TILLANDSIAS_RELEASE_SECRET` from `builtins.getEnv` at eval
  time, conditionally injects it into all three `craneLib.buildPackage` derivations
  via `commonCraneArgs`. When unset (no `--impure`), the env var is absent from the
  derivation and the Rust `option_env!` falls back to `DEV_ROOT_SEED`.
- **release.yml**: generates a fresh ephemeral 256-bit key via `openssl rand -hex 32`
  before the build, passes it as `TILLANDSIAS_RELEASE_SECRET` to all three
  `nix build --impure` invocations (host x86_64 + headless x86_64 + headless aarch64),
  guaranteeing every binary in this release shares the same key. Post-build, runs
  `strings | grep` on each binary to assert the public `DEV_ROOT_SEED` string
  `"tillandsias-dev-root-not-a-secret"` is absent — proving the real secret was
  embedded instead.
- **No GitHub Secrets required**: the key is ephemeral and generated per-build, so
  no token infra, no secret-store setup. Every release from CI automatically gets
  a fresh secure-channel identity. Local builders opt in with
  `TILLANDSIAS_RELEASE_SECRET=$(openssl rand -hex 32) nix build --impure`.

Remaining work for macOS pickup (slices 1, 2, 4):
1. Normalize all host initiator PSK inputs to the same workspace `VERSION`.
2. Route `wait_phase_ready` / `probe_vm_phase` through the same secure-or-plain
   opener used by user actions.
4. Update secure-channel plan text where needed so failure-closed semantics match
   the implementable handshake boundary.

## macOS meta-orchestration routing 2026-07-05T18:53Z

MacOS can own the PSK parity and VZ readiness-probe slices once the local
`osx-next` WIP is checkpointed and the branch has merged `origin/linux-next`.

## macOS slices 1, 2, 4 complete — 2026-07-06T16:00Z (order 194, ALL SLICES DONE)

- **Slice 1 (PSK normalization):** audited all 5 `channel_psk` call sites
  (`tillandsias-macos-tray/src/action_host.rs`, `.../diagnose.rs`,
  `tillandsias-headless/src/vsock_server.rs`,
  `tillandsias-windows-tray/src/hvsocket.rs`,
  `tillandsias-host-shell/src/vsock_client.rs`) — all already derive from the
  workspace `VERSION` file (via `workspace_version()` / `WORKSPACE_VERSION` /
  host-shell's `crate::version()`); no live `CARGO_PKG_VERSION` drift found. A
  prior commit (`007c57e5`) had already closed this gap. Added
  `litmus:psk-input-parity-shape` (`openspec/litmus-tests/litmus-psk-input-parity-shape.yaml`)
  so a regression fails loud instead of silently drifting again.
- **Slice 2 (readiness-probe secure routing):** `VzRuntime::wait_phase_ready`
  (`crates/tillandsias-vm-layer/src/vz.rs`) connected raw over vsock and
  called `probe_vm_phase` directly — bypassing the secure-or-plain check user
  actions go through. Since `tillandsias-vm-layer` deliberately does not
  depend on `tillandsias-secure-channel`, the fix is dependency injection:
  `wait_phase_ready` now takes a caller-supplied
  `probe_once(Duration) -> impl Future<Output=Result<VmPhase,String>>`
  closure. All 4 `diagnose.rs` call sites (`--exec-guest`,
  `--list-cloud-projects`, GitHub login, and the 4th diagnostic path) now
  pass a new `probe_phase_secure_or_plain()` helper that reuses the existing
  `open_control_wire_stream()` opener — the same one `--exec-guest` etc. use
  — so readiness probing never bypasses `TILLANDSIAS_SECURE_CONTROL_WIRE=on`.
  Added `probe_phase_secure_or_plain_uses_the_secure_or_plain_opener` (a
  source-pin unit test) covering `litmus:secure-wait-phase-ready`.
- **Slice 4 (plan-text wording):** reworded the M1 gate in
  `secure-channel-maturity-ladder-2026-07-04.md` — a plaintext/wrong-version
  peer failing closed means no `HelloAck`/`PtyOpen` and the stream is
  closed/errored, NOT a literal `Unauthorized` response frame (there is no
  control-envelope channel before a successful handshake to carry one over).
  Cited the primitive-level proof test
  (`tillandsias-secure-channel::secure_stream::tests::plaintext_peer_is_rejected`).
- **Evidence:** `cargo test -p tillandsias-vm-layer`: 44/44 pass. `cargo test
  -p tillandsias-macos-tray`: 54/54 pass (1 ignored). `cargo clippy -p
  tillandsias-vm-layer -p tillandsias-macos-tray --all-targets`: 0 new
  warnings (3 pre-existing ones filed separately as order 197).
- **Commit:** `9126986b` on `osx-next`.
- **Order 194 is now fully done** (all 4 slices across linux + macos closed).
