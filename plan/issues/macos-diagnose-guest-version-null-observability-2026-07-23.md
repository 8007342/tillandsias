# macOS `--diagnose --json` always reports `guest_version: null` (observability gap)

- **classification**: optimization/ (observability) — **non-blocking**
- **discovered_by**: `/build-install-and-smoke-test-e2e (macos)` cold-reprovision smoke, osx-next @`dcafd59c`
- **severity**: low (cosmetic/observability; no functional impact on provisioning or boot)
- **relates_to**: guest-version handshake `ced9657e`; smoke report `plan/issues/macos-build-install-smoke-e2e-findings-2026-07-23.md`

## Symptom

`tillandsias-tray --diagnose --json` reports `"guest_version": null` **even after
the guest has booted to ready** on a freshly cold-provisioned VM. Empirically, in
the same session where `crashloop.state` recorded `ever_ready 1` / `last_phase
ready` (guest reached ready over the live vsock wire), a subsequent CLI
`--diagnose --json` still returned `guest_version: null`.

## Root cause

The value is never available to the static CLI diagnose path:

- `crates/tillandsias-macos-tray/src/diagnose.rs` builds the `DiagnoseReport`
  with `guest_version: None` hardcoded (`:280`, `:1447`). The diagnose path does a
  static disk-artifact probe and has no code that reads a persisted
  `guest_version`.
- `crates/tillandsias-macos-tray/src/action_host.rs` (~`:2227-2241`) performs the
  live handshake and stores the result **only into the running tray's in-memory
  `menu_state`** (`guard.guest_version = guest_version`). It is not persisted to
  disk.

So `guest_version` is observable only from the running tray's menu, never from the
separate, stateless `--diagnose` subprocess — yet the diagnose JSON schema
(`DiagnoseReport.guest_version: Option<String>`) advertises the field, which can
mislead an operator/agent into reading `null` as a failed guest handshake.

## Why it matters

`--diagnose --json` is the scriptable health surface used by the e2e smoke skill
and by agents that cannot click the tray menu. A perpetually-null advertised field
is a false-negative trap: it looks like the guest-version handshake failed when it
did not.

## Proposed reduction (smallest verifiable slice)

Persist the handshake `guest_version` to a small state file in the image root
(e.g. alongside `crashloop.state`) when the guest reports ready, and have
`diagnose.rs` read it (stale-tolerant, `Option`). Then a litmus can assert: after
a boot-to-ready, `--diagnose --json | jq .guest_version` is non-null OR the field
is removed from the CLI schema. Either closes the advertise-but-never-fill gap.

## Repro

1. Cold-provision a macOS VM (`--provision`).
2. Launch the installed tray; wait for the guest to reach ready
   (`crashloop.state` shows `ever_ready 1` / `last_phase ready`).
3. Run `tillandsias-tray --diagnose --json` → observe `"guest_version": null`.
