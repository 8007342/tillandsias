# Secure-channel hardening: PSK parity, release-secret enforcement, readiness probes — 2026-07-05

- class: security+release hardening
- owner: any, with macOS evidence where VZ probes are involved
- status: ready
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
